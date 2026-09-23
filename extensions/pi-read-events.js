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

function locationRecord(phase, tool, toolCallId, target) {
  return {
    v: 1,
    kind: "location",
    phase,
    tool,
    toolCallId,
    ...(target?.path && { path: target.path }),
    agent: AGENT,
    ...(target?.line && { line: target.line }),
  };
}

export default function (pi) {
  let currentRepository;
  let pending = new Map();
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

  pi.on("session_start", (_event, ctx) => {
    currentRepository = undefined;
    pending = new Map();
    warnedLogs = new Set();
    repository(ctx.cwd);
  });

  pi.on("tool_call", (event, ctx) => {
    if (
      !["read", "write", "edit"].includes(event.toolName) ||
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
    } else if (event.toolName === "edit") {
      inputPath = editInputPath(event.input);
      const resolved = inputPath && resolveWriteFile(repo, ctx.cwd, inputPath);
      if (!resolved) return;
      target = { path: resolved.path };
    } else {
      return;
    }

    const call = {
      repo,
      cwd: ctx.cwd,
      tool: event.toolName,
      inputPath,
      target,
      range,
    };
    remember(event.toolCallId, call);
    appendEvent(
      repo,
      locationRecord("start", event.toolName, event.toolCallId, target),
    );
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
    warnedLogs = new Set();
  });
}
