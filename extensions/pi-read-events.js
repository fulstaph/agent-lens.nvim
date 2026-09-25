// Load explicitly with: pi --extension /path/to/agent-lens.nvim/extensions/pi-read-events.js
// Or: omp --extension /path/to/agent-lens.nvim/extensions/pi-read-events.js
// Records repository-relative location metadata only. File contents are never logged.
import { appendFileSync, lstatSync, mkdirSync, realpathSync, statSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { homedir } from "node:os";
import { dirname, isAbsolute, relative, resolve, sep } from "node:path";

const AGENT = "pi";
const RANGE_TOKEN = String.raw`(?:-\d+|\d+(?:-\d*|\+\d+|\.\.\d+)?)`;
const READ_SELECTOR = new RegExp(
  String.raw`:(?:(?:raw:)?${RANGE_TOKEN}(?:,${RANGE_TOKEN})*(?::raw)?|raw|img|conflicts)$`,
);

function positiveInteger(value) {
  return Number.isSafeInteger(value) && value > 0 ? value : undefined;
}

function validToolCallId(value) {
  return typeof value === "string" && value.length > 0 && value.length <= 256;
}

function expandPath(cwd, input) {
  if (input.startsWith("~/")) return resolve(homedir(), input.slice(2));
  try {
    return resolve(realpathSync(cwd), input);
  } catch {
    return resolve(cwd, input);
  }
}

function repositoryPath(root, file) {
  const path = relative(root, file);
  if (!path || path === ".." || path.startsWith(`..${sep}`) || isAbsolute(path)) {
    return undefined;
  }
  const normalized = path.split(sep).join("/");
  if (normalized === ".git" || normalized.startsWith(".git/")) return undefined;
  return normalized;
}
function hasSymlinkComponent(root, file) {
  const path = relative(root, file);
  if (!path || path === ".." || path.startsWith(`..${sep}`) || isAbsolute(path)) {
    return false;
  }
  let current = root;
  for (const part of path.split(sep)) {
    current = resolve(current, part);
    try {
      if (lstatSync(current).isSymbolicLink()) return true;
    } catch {
      return false;
    }
  }
  return false;
}

function resolveExistingFile(repo, cwd, input) {
  if (typeof input !== "string" || input === "" || input.includes("://")) return undefined;
  try {
    const file = realpathSync(expandPath(cwd, input));
    if (!statSync(file).isFile()) return undefined;
    const path = repositoryPath(repo.root, file);
    return path ? { file, path } : undefined;
  } catch {
    return undefined;
  }
}

function nearestExistingAncestor(path) {
  let candidate = path;
  while (true) {
    try {
      return realpathSync(candidate);
    } catch {
      const parent = dirname(candidate);
      if (parent === candidate) return undefined;
      candidate = parent;
    }
  }
}

function resolveWriteFile(repo, cwd, input) {
  const existing = resolveExistingFile(repo, cwd, input);
  if (existing) return existing;
  if (typeof input !== "string" || input === "" || input.includes("://")) return undefined;

  const file = expandPath(cwd, input);
  if (hasSymlinkComponent(repo.root, file)) return undefined;
  try {
    const stat = lstatSync(file);
    if (stat.isSymbolicLink() || !stat.isFile()) return undefined;
  } catch {
    // A genuinely missing target is allowed when its nearest ancestor is safe.
  }
  const path = repositoryPath(repo.root, file);
  if (!path) return undefined;
  const ancestor = nearestExistingAncestor(file);
  if (!ancestor || (ancestor !== repo.root && !repositoryPath(repo.root, ancestor))) return undefined;
  return { file, path };
}

// Prefer a literal selector-looking filename before stripping a read selector.
function resolveReadFile(repo, cwd, input) {
  if (typeof input !== "string") return undefined;
  const candidate = input.replace(READ_SELECTOR, "");
  for (const name of candidate === input ? [input] : [input, candidate]) {
    const resolved = resolveExistingFile(repo, cwd, name);
    if (resolved) {
      return {
        ...resolved,
        selector: name === input ? undefined : input.slice(candidate.length),
      };
    }
  }
  return undefined;
}

function readLocation(selector, input) {
  if (!selector) {
    const start = positiveInteger(input.offset);
    const count = positiveInteger(input.limit);
    return {
      ...(start && { line: start }),
      ...(start && count && { range: { start, end: start + count - 1 } }),
    };
  }

  let body = selector.slice(1);
  if (body.startsWith("raw:")) body = body.slice(4);
  if (body.endsWith(":raw")) body = body.slice(0, -4);
  if (body === "raw" || body === "img" || body === "conflicts" || body.startsWith("-")) {
    return {};
  }

  const token = body.split(",", 1)[0];
  const bare = token.match(/^(\d+)$/);
  const span = token.match(/^(\d+)(?:-|\.\.)(\d+)$/);
  const open = token.match(/^(\d+)-$/);
  const count = token.match(/^(\d+)\+(\d+)$/);
  const line = positiveInteger(
    Number(bare?.[1] ?? span?.[1] ?? open?.[1] ?? count?.[1]),
  );
  if (!line) return {};

  let range;
  if (!body.includes(",") && span) {
    const end = positiveInteger(Number(span[2]));
    if (end && end >= line) range = { start: line, end };
  } else if (!body.includes(",") && count) {
    const length = positiveInteger(Number(count[2]));
    if (length) range = { start: line, end: line + length - 1 };
  }
  return { line, ...(range && { range }) };
}

function resultStartLine(details) {
  return positiveInteger(details?.displayContent?.startLine) ??
    positiveInteger(details?.startLine);
}

function editInputPath(input) {
  if (typeof input?.path === "string") return input.path;
  if (Array.isArray(input?.paths)) {
    return input.paths.find((path) => typeof path === "string");
  }
  return undefined;
}

function editResult(details) {
  if (Array.isArray(details?.perFileResults)) {
    const result = details.perFileResults.find(
      (entry) =>
        entry &&
        entry.op !== "delete" &&
        entry.success !== false &&
        !entry.error &&
        typeof entry.path === "string",
    );
    if (result) {
      return { inputPath: result.path, line: positiveInteger(result.firstChangedLine) };
    }
  }
  if (typeof details?.path === "string") {
    return {
      inputPath: details.path,
      line: positiveInteger(details.firstChangedLine),
    };
  }
  return undefined;
}
function completeStreamEnd(value, isFinal) {
  if (isFinal || value.endsWith("\n")) return value.length;
  const end = value.lastIndexOf("\n");
  return end < 0 ? 0 : end + 1;
}

function emptyStreamParser(toolName) {
  return {
    toolName,
    inputLength: 0,
    pendingLength: 0,
    section: undefined,
    target: undefined,
    final: false,
  };
}

function advanceStreamParser(toolName, input, isFinal, previous, delta) {
  if (typeof input !== "string") return previous;
  const appendOnly =
    previous &&
    previous.toolName === toolName &&
    !previous.final &&
    typeof delta === "string" &&
    delta.length > 0 &&
    input.length === previous.inputLength + delta.length &&
    input.endsWith(delta);
  const base = appendOnly ? previous : emptyStreamParser(toolName);
  const start = appendOnly ? previous.inputLength - previous.pendingLength : 0;
  const suffix = input.slice(start);
  const completeEnd = completeStreamEnd(suffix, isFinal);
  const chunk = suffix.slice(0, completeEnd);
  let next = {
    ...base,
    inputLength: input.length,
    pendingLength: suffix.length - completeEnd,
    final: isFinal,
  };
  for (const rawLine of chunk.split("\n")) {
    const line = rawLine.replace(/\r$/, "");
    if (toolName === "apply_patch") {
      const header = line.match(/^\*\*\* (?:Add|Update|Delete) File:\s*(.+?)\s*$/);
      if (header) next = { ...next, target: { inputPath: header[1] } };
      continue;
    }

    const header = line.match(/^\[([^\]\r\n]+)#([0-9A-F]{4})\]\s*$/);
    if (header) {
      next = {
        ...next,
        section: header[1],
        target: { inputPath: header[1] },
      };
      continue;
    }
    if (!next.section) continue;
    if (/^(?:REM|MV(?:\s+.+)?|PUT\s+>\$)\s*$/.test(line)) {
      next = { ...next, target: { inputPath: next.section } };
      continue;
    }
    const operation = line.match(
      /^(?:PUT|CUT)\s+(?:(\d+)(?:\.\=\d+|\*)|>(\d+)(?::|$))/,
    );
    const lineNumber = positiveInteger(Number(operation?.[1] ?? operation?.[2]));
    if (lineNumber) {
      next = { ...next, target: { inputPath: next.section, line: lineNumber } };
    }
  }
  return next;
}

function hashlineProgress(input, isFinal, previous, delta) {
  const parser = advanceStreamParser("edit", input, isFinal, previous, delta);
  return parser ? { target: parser.target, parser } : undefined;
}

function applyPatchProgress(input, isFinal, previous, delta) {
  const parser = advanceStreamParser(
    "apply_patch",
    input,
    isFinal,
    previous,
    delta,
  );
  return parser ? { target: parser.target, parser } : undefined;
}

function streamedToolCall(event) {
  const assistantEvent = event?.assistantMessageEvent;
  if (!["toolcall_delta", "toolcall_end"].includes(assistantEvent?.type)) {
    return undefined;
  }
  const indexed = assistantEvent.partial?.content?.[assistantEvent.contentIndex];
  const toolCall =
    assistantEvent.type === "toolcall_end" ? assistantEvent.toolCall ?? indexed : indexed;
  if (
    !validToolCallId(toolCall?.id) ||
    !["edit", "apply_patch"].includes(toolCall?.name)
  ) {
    return undefined;
  }
  const input = toolCall.arguments;
  if (input != null && (typeof input !== "object" || Array.isArray(input))) {
    return undefined;
  }
  return {
    toolCallId: toolCall.id,
    toolName: toolCall.name,
    input: input ?? {},
    delta: typeof assistantEvent.delta === "string" ? assistantEvent.delta : "",
    isFinal: assistantEvent.type === "toolcall_end",
  };
}


function streamedEditTarget(repo, cwd, toolCall, isFinal, previousParser) {
  const inputPath = editInputPath(toolCall.input);
  if (inputPath) {
    const resolved = resolveWriteFile(repo, cwd, inputPath);
    if (resolved) return { target: { path: resolved.path }, parser: previousParser };
  }

  const parsed =
    toolCall.toolName === "apply_patch"
      ? applyPatchProgress(toolCall.input.input, isFinal, previousParser, toolCall.delta)
      : hashlineProgress(toolCall.input.input, isFinal, previousParser, toolCall.delta);
  const parser = parsed?.parser ?? previousParser;
  if (!parsed?.target) return { target: undefined, parser };
  const resolved = resolveWriteFile(repo, cwd, parsed.target.inputPath);
  if (!resolved) return { target: undefined, parser };
  return {
    target: {
      path: resolved.path,
      ...(parsed.target.line && { line: parsed.target.line }),
    },
    parser,
  };
}

function sameTarget(left, right) {
  return left?.path === right?.path && left?.line === right?.line;
}


function locationRecord(phase, tool, toolCallId, target, sequence) {
  return {
    v: 1,
    kind: "location",
    phase,
    tool,
    toolCallId,
    ...(target?.path && { path: target.path }),
    agent: AGENT,
    ...(target?.line && { line: target.line }),
    ...(phase === "progress" && positiveInteger(sequence) && { sequence }),
  };
}

export default function (pi) {
  let currentRepository;
  let pending = new Map();
  let streaming = new Map();
  let warnedLogs = new Set();
  function repository(cwd) {
    if (currentRepository?.cwd === cwd) return currentRepository;
    try {
      const root = realpathSync(
        execFileSync("git", ["-C", cwd, "rev-parse", "--show-toplevel"], {
          encoding: "utf8",
          stdio: ["ignore", "pipe", "ignore"],
        }).trim(),
      );
      const gitDir = execFileSync(
        "git",
        ["-C", cwd, "rev-parse", "--absolute-git-dir"],
        { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
      ).trim();
      currentRepository = {
        cwd,
        root,
        log: resolve(gitDir, "agent-lens", "reads.jsonl"),
      };
    } catch {
      currentRepository = { cwd };
    }
    return currentRepository;
  }

  function appendEvent(repo, event) {
    if (!repo?.log) return false;
    try {
      mkdirSync(dirname(repo.log), { recursive: true, mode: 0o700 });
      appendFileSync(repo.log, `${JSON.stringify(event)}\n`, { mode: 0o600 });
      return true;
    } catch (error) {
      if (!warnedLogs.has(repo.log)) {
        warnedLogs = new Set(warnedLogs).add(repo.log);
        console.error("[agent-lens] Cannot write agent-event log:", error);
      }
      return false;
    }
  }

  function remember(toolCallId, value) {
    pending = new Map(pending);
    pending.set(toolCallId, value);
  }

  function settle(toolCallId) {
    if (!pending.has(toolCallId)) return undefined;
    const value = pending.get(toolCallId);
    pending = new Map(pending);
    pending.delete(toolCallId);
    return value;
  }
  function updateStreaming(event, ctx) {
    const toolCall = streamedToolCall(event);
    if (!toolCall) return;
    const repo = repository(ctx.cwd);
    if (!repo.root || !repo.log) return;

    const current = streaming.get(toolCall.toolCallId);
    const parsed = streamedEditTarget(
      repo,
      ctx.cwd,
      toolCall,
      toolCall.isFinal,
      current?.parser,
    );
    const state = current ?? {
      repo,
      cwd: ctx.cwd,
      lastTarget: undefined,
      sequence: 0,
      parser: parsed.parser,
    };
    const nextState = { ...state, parser: parsed.parser };
    if (!parsed.target || sameTarget(state.lastTarget, parsed.target)) {
      if (!current || nextState.parser !== current.parser) {
        streaming = new Map(streaming);
        streaming.set(toolCall.toolCallId, nextState);
      }
      return;
    }

    const next = {
      ...nextState,
      lastTarget: parsed.target,
      sequence: state.sequence + 1,
    };
    appendEvent(
      repo,
      locationRecord("progress", "edit", toolCall.toolCallId, parsed.target, next.sequence),
    );
    streaming = new Map(streaming);
    streaming.set(toolCall.toolCallId, next);
  }

  function forgetStreaming(toolCallId) {
    if (!streaming.has(toolCallId)) return;
    streaming = new Map(streaming);
    streaming.delete(toolCallId);
  }

  function clearStreaming(emitErrors) {
    if (emitErrors) {
      for (const [toolCallId, call] of streaming) {
        appendEvent(call.repo, locationRecord("error", "edit", toolCallId));
      }
    }
    streaming = new Map();
  }


  pi.on("session_start", (_event, ctx) => {
    currentRepository = undefined;
    pending = new Map();
    streaming = new Map();
    warnedLogs = new Set();
    repository(ctx.cwd);
  });

  pi.on("message_update", updateStreaming);

  pi.on("message_end", (event) => {
    if (event?.message?.role === "assistant" && event.message.stopReason !== "toolUse") {
      clearStreaming(true);
    }
  });

  pi.on("turn_end", () => {
    clearStreaming(true);
  });

  pi.on("tool_call", (event, ctx) => {
    const tool = event.toolName === "apply_patch" ? "edit" : event.toolName;
    if (
      !["read", "write", "edit"].includes(tool) ||
      !validToolCallId(event.toolCallId)
    ) {
      return;
    }

    const repo = repository(ctx.cwd);
    if (!repo.root || !repo.log) return;
    let target;
    let range;
    let inputPath;

    if (event.toolName === "read" && typeof event.input?.path === "string") {
      const resolved = resolveReadFile(repo, ctx.cwd, event.input.path);
      if (!resolved) return;
      const location = readLocation(resolved.selector, event.input);
      target = { path: resolved.path, line: location.line };
      range = location.range;
      inputPath = event.input.path;
    } else if (event.toolName === "write" && typeof event.input?.path === "string") {
      const resolved = resolveWriteFile(repo, ctx.cwd, event.input.path);
      if (!resolved) return;
      target = { path: resolved.path, line: 1 };
      inputPath = event.input.path;
    } else if (tool === "edit") {
      const editTarget = streamedEditTarget(
        repo,
        ctx.cwd,
        { toolName: event.toolName, input: event.input },
        true,
      );
      if (!editTarget.target) return;
      inputPath = editTarget.target.path;
      target = editTarget.target;
    } else {
      return;
    }

    const call = {
      repo,
      cwd: ctx.cwd,
      tool,
      inputPath,
      target,
      range,
    };
    remember(event.toolCallId, call);
    appendEvent(
      repo,
      locationRecord("start", tool, event.toolCallId, target),
    );
    forgetStreaming(event.toolCallId);
  });

  pi.on("tool_result", (event) => {
    const call = pending.get(event.toolCallId);
    if (!call) return;

    if (event.isError) {
      appendEvent(
        call.repo,
        locationRecord("error", call.tool, event.toolCallId),
      );
      settle(event.toolCallId);
      return;
    }

    let target = call.target;
    let range = call.range;
    if (call.tool === "read") {
      const inputPath =
        typeof event.input?.path === "string" ? event.input.path : call.inputPath;
      const resolved = resolveReadFile(call.repo, call.cwd, inputPath);
      if (resolved) {
        const location = readLocation(resolved.selector, event.input ?? {});
        target = {
          path: resolved.path,
          line: resultStartLine(event.details) ?? location.line,
        };
        range = location.range;
      }
    } else if (call.tool === "write") {
      const inputPath =
        typeof event.input?.path === "string" ? event.input.path : call.inputPath;
      const resolved = resolveExistingFile(call.repo, call.cwd, inputPath);
      if (resolved) target = { path: resolved.path, line: 1 };
    } else {
      const result = editResult(event.details);
      const inputPath = result?.inputPath ?? editInputPath(event.input) ?? call.inputPath;
      const resolved = resolveExistingFile(call.repo, call.cwd, inputPath);
      if (resolved) target = { path: resolved.path, line: result?.line };
    }

    appendEvent(
      call.repo,
      locationRecord("success", call.tool, event.toolCallId, target),
    );
    if (call.tool === "read" && target?.path) {
      appendEvent(call.repo, {
        v: 1,
        kind: "read",
        path: target.path,
        agent: AGENT,
        ...(range && { range }),
      });
    }
    settle(event.toolCallId);
  });

  pi.on("tool_execution_end", (event) => {
    const call = settle(event.toolCallId);
    if (call && event.isError) {
      appendEvent(
        call.repo,
        locationRecord("error", call.tool, event.toolCallId),
      );
    }
  });

  pi.on("session_shutdown", () => {
    currentRepository = undefined;
    pending = new Map();
    streaming = new Map();
    warnedLogs = new Set();
  });
}
