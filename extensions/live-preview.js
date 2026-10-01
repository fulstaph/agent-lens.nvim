// Draft contents travel only over local sockets, never through reads.jsonl.
import { createHash } from "node:crypto";
import { lstatSync, readFileSync, readdirSync, realpathSync, statSync } from "node:fs";
import { createConnection } from "node:net";
import { resolve } from "node:path";

const MAX_BYTES = 1024 * 1024;
const MAX_LINES = 20000;

export function previewDirectory(root) {
  const hash = createHash("sha256").update(realpathSync(root)).digest("hex").slice(0, 16);
  return resolve(realpathSync("/tmp"), `agent-lens-${process.getuid()}-${hash}`);
}

function textLines(text) {
  const lines = text.replace(/\r\n/g, "\n").split("\n");
  if (lines.length > 1 && lines.at(-1) === "") lines.pop();
  return lines;
}

function sourceLines(file) {
  try {
    if (statSync(file).size > MAX_BYTES) return undefined;
    const text = readFileSync(file, "utf8");
    if (text.includes("\0")) return undefined;
    const lines = text === "" ? [] : textLines(text);
    if (lines.length > MAX_LINES) return undefined;
    lines.endofline = text.endsWith("\n");
    return lines;
  } catch (error) {
    return error.code === "ENOENT" ? [] : undefined;
  }
}

function uniqueStart(source, old, after = 0) {
  if (!old.length) return undefined;
  let found;
  for (let index = after; index <= source.length - old.length; index++) {
    if (!old.every((line, offset) => source[index + offset] === line)) continue;
    if (found !== undefined) return undefined;
    found = index;
  }
  return found;
}

// Parse only the currently addressed file. Unsupported operations retain navigation.
function hashlineDraft(input, base, isFinal) {
  const rows = input.replace(/\r\n/g, "\n").split("\n");
  if (rows.length > MAX_LINES) return undefined;
  let path;
  let edits = [];
  let operation;
  for (let index = 0; index < rows.length; index++) {
    const row = rows[index];
    const complete = index < rows.length - 1 || isFinal;
    const header = complete && row.match(/^\[([^\]\r\n]+)#([0-9A-F]{4})\]\s*$/);
    if (header) {
      path = header[1];
      edits = [];
      operation = undefined;
    } else if (path && complete && /^(?:PUT|CUT|REM|MV)\b/.test(row)) {
      operation = undefined;
      const replace = row.match(/^(PUT|CUT) (\d+)\.=(\d+):?\s*$/);
      const insert = row.match(/^PUT ([<>])(\d+|\$):?\s*$/);
      if (replace) {
        operation = { start: Number(replace[2]) - 1, end: Number(replace[3]), lines: [] };
      } else if (insert) {
        const anchor = insert[2] === "$" ? base(path)?.length : Number(insert[2]);
        if (anchor !== undefined) {
          const start = insert[1] === "<" ? anchor - 1 : anchor;
          operation = { start, end: start, lines: [] };
        }
      }
      if (operation) edits.push(operation);
    } else if (operation && row.startsWith("+")) {
      operation.lines.push(row.slice(1));
    }
  }
  const source = path && base(path);
  if (!source || !edits.length) return undefined;
  const result = [...source];
  let line = 1;
  let previousEnd = -1;
  // Hashline coordinates refer to the pre-edit snapshot.
  for (const edit of [...edits].sort((a, b) => b.start - a.start)) {
    if (edit.start < 0 || edit.end < edit.start || edit.end > source.length) return undefined;
    if (previousEnd >= 0 && edit.end > previousEnd) return undefined;
    previousEnd = edit.start;
    result.splice(edit.start, edit.end - edit.start, ...edit.lines);
  }
  const active = edits.at(-1);
  const shift = edits
    .filter((edit) => edit !== active && edit.end <= active.start)
    .reduce((total, edit) => total + edit.lines.length - (edit.end - edit.start), 0);
  line = active.start + shift + Math.max(1, active.lines.length);
  return { inputPath: path, lines: result, line };
}

function patchDraft(input, base, isFinal) {
  const rows = input.replace(/\r\n/g, "\n").split("\n");
  if (rows.length > MAX_LINES) return undefined;
  let path;
  let add = false;
  let hunks = [];
  let hunk;
  let added = [];
  for (let index = 0; index < rows.length; index++) {
    const row = rows[index];
    const complete = index < rows.length - 1 || isFinal;
    const header = complete && row.match(/^\*\*\* (Add|Update|Delete) File:\s*(.+?)\s*$/);
    if (header) {
      path = header[1] === "Delete" ? undefined : header[2];
      add = header[1] === "Add";
      hunks = [];
      hunk = undefined;
      added = [];
    } else if (path && complete && row.startsWith("@@")) {
      hunk = { old: [], next: [] };
      hunks.push(hunk);
    } else if (path && row.startsWith("+")) {
      if (add) added.push(row.slice(1));
      else if (hunk) hunk.next.push(row.slice(1));
    } else if (hunk && complete && (row.startsWith(" ") || row.startsWith("-"))) {
      hunk.old.push(row.slice(1));
      if (row.startsWith(" ")) hunk.next.push(row.slice(1));
    } else if (complete && row.startsWith("***")) {
      hunk = undefined;
    }
  }
  if (!path) return undefined;
  if (add && added.length) return { inputPath: path, lines: added, line: added.length };
  const source = base(path);
  if (!source || !hunks.length) return undefined;
  const result = [...source];
  let after = 0;
  let line = 1;
  for (const current of hunks) {
    const start = uniqueStart(result, current.old, after);
    if (start === undefined) return undefined;
    result.splice(start, current.old.length, ...current.next);
    after = start + current.next.length;
    line = Math.max(1, after);
  }
  return { inputPath: path, lines: result, line };
}

function structuredDraft(input, base) {
  if (typeof input.path !== "string" || typeof input.newText !== "string"
    || typeof input.oldText !== "string" || input.oldText === "") return undefined;
  const source = base(input.path);
  if (!source) return undefined;
  const text = source.join("\n") + (source.endofline ? "\n" : "");
  const old = input.oldText.replace(/\r\n/g, "\n");
  const start = text.indexOf(old);
  if (start < 0 || text.indexOf(old, start + 1) >= 0) return undefined;
  const replacement = input.newText.replace(/\r\n/g, "\n");
  return {
    inputPath: input.path,
    lines: textLines(text.slice(0, start) + replacement + text.slice(start + old.length)),
    line: text.slice(0, start).split("\n").length + textLines(replacement).length - 1,
  };
}

export function createLivePreview(resolveFile) {
  let calls = new Map();
  let peers = new Map();
  let timer;
  let lastScan = 0;
  let scannedRoot;

  function receivers(root) {
    let directory;
    try {
      directory = previewDirectory(root);
    } catch {
      return;
    }
    if (scannedRoot !== root) {
      for (const socket of peers.values()) socket.destroy();
      peers = new Map();
      lastScan = 0;
      scannedRoot = root;
    }
    if (Date.now() - lastScan < 500) return;
    lastScan = Date.now();
    try {
      const stat = lstatSync(directory);
      if (!stat.isDirectory() || stat.uid !== process.getuid() || (stat.mode & 0o077)) return;
      for (const name of readdirSync(directory)) {
        if (!/^\d+\.sock$/.test(name) || peers.size >= 8) continue;
        const path = resolve(directory, name);
        if (peers.has(path)) continue;
        try {
          // A crashed editor can leave a socket behind; do not let it fill the peer limit.
          process.kill(Number(name.slice(0, -5)), 0);
        } catch {
          continue;
        }
        const entry = lstatSync(path);
        if (!entry.isSocket() || entry.uid !== process.getuid()) continue;
        const socket = createConnection(path);
        socket.on("error", () => socket.destroy());
        socket.on("close", () => { if (peers.get(path) === socket) peers.delete(path); });
        socket.unref();
        peers.set(path, socket);
      }
    } catch {
      // No opted-in Neovim receiver, or a stale socket. Metadata still works.
    }
  }

  function flush(call) {
    if (!call.dirty) return;
    call.dirty = false;
    receivers(call.repo.root);
    if (!peers.size) return;
    const { toolName, input, isFinal, toolCallId } = call.toolCall;
    if ([input.content, input.input, input.oldText, input.newText]
      .some((value) => typeof value === "string" && value.length > MAX_BYTES)) return;
    const base = (inputPath) => {
      const target = resolveFile(call.repo, call.cwd, inputPath);
      if (!target) return undefined;
      if (!call.sources.has(target.path)) call.sources.set(target.path, sourceLines(target.file));
      return call.sources.get(target.path);
    };
    let draft;
    if (toolName === "write" && typeof input.content === "string") {
      const lines = textLines(input.content);
      draft = { inputPath: input.path, lines, line: lines.length };
    } else if (typeof input.input === "string" && input.input.length <= MAX_BYTES) {
      draft = toolName === "apply_patch"
        ? patchDraft(input.input, base, isFinal)
        : hashlineDraft(input.input, base, isFinal);
    } else if (toolName === "edit") {
      draft = structuredDraft(input, base);
    }
    if (!draft || draft.lines.length > MAX_LINES || draft.lines.some((line) => line.includes("\0"))) return;
    const target = resolveFile(call.repo, call.cwd, draft.inputPath);
    if (!target) return;
    const event = {
      v: 1, kind: "preview", toolCallId, tool: toolName === "write" ? "write" : "edit",
      path: target.path, line: Math.max(1, draft.line), sequence: ++call.sequence,
      agent: "pi", lines: draft.lines.length ? draft.lines : [""],
    };
    const record = `${JSON.stringify(event)}\n`;
    if (Buffer.byteLength(record) > MAX_BYTES) return;
    let lagging = false;
    for (const socket of peers.values()) {
      if (socket.destroyed) continue;
      // A slow editor skips intermediate snapshots; closing would read as cancellation.
      if (socket.writableLength >= MAX_BYTES) lagging = true;
      else socket.write(record);
    }
    if (lagging) {
      call.dirty = true;
      schedule();
    }
  }

  function schedule() {
    if (timer) return;
    timer = setTimeout(() => {
      timer = undefined;
      for (const pending of calls.values()) flush(pending);
    }, 25);
    timer.unref();
  }

  return {
    update(repo, cwd, toolCall) {
      if (!calls.has(toolCall.toolCallId) && calls.size >= 128) return;
      const call = calls.get(toolCall.toolCallId) ?? { repo, cwd, sources: new Map(), sequence: 0 };
      call.toolCall = toolCall;
      call.dirty = true;
      calls.set(toolCall.toolCallId, call);
      schedule();
    },
    finish(toolCallId) {
      const call = calls.get(toolCallId);
      if (call) flush(call);
      calls.delete(toolCallId);
    },
    stop() {
      if (timer) clearTimeout(timer);
      timer = undefined;
      calls = new Map();
      for (const socket of peers.values()) socket.destroy();
      peers = new Map();
      scannedRoot = undefined;
      lastScan = 0;
    },
  };
}
