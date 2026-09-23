// Load explicitly with: pi --extension /path/to/agent-lens.nvim/extensions/pi-read-events.js
// Or: omp --extension /path/to/agent-lens.nvim/extensions/pi-read-events.js
// Only successful built-in `read` calls are recorded. File contents are never logged.
import { appendFileSync, mkdirSync, realpathSync, statSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { homedir } from "node:os";
import { dirname, isAbsolute, relative, resolve, sep } from "node:path";

// OMP accepts path:50-100 and path:raw:50-100; prefer a literal colon filename.
function resolveReadFile(cwd, input) {
  const selector = /:(?:(?:raw:)?-?\d+(?:-\d*|\+\d+)?(?:,-?\d+(?:-\d*|\+\d+)?)?(?::raw)?|raw|img|conflicts)$/;
  const candidate = input.replace(selector, "");
  for (const name of candidate === input ? [input] : [input, candidate]) {
    const expanded = name.startsWith("~/") ? resolve(homedir(), name.slice(2)) : resolve(cwd, name);
    try {
      const file = realpathSync(expanded);
      if (statSync(file).isFile()) return { file, selector: name === input ? undefined : input.slice(candidate.length) };
    } catch {
      // Try the selector-stripped candidate.
    }
  }
  return undefined;
}

function readRange(selector, input) {
  const span = selector?.match(/^:(?:raw:)?(\d+)-(\d+)(?::raw)?$/);
  const count = selector?.match(/^:(?:raw:)?(\d+)\+(\d+)(?::raw)?$/);
  const start = span ? Number(span[1]) : count ? Number(count[1]) : input.offset;
  const end = span ? Number(span[2]) : count ? start + Number(count[2]) - 1 : start + input.limit - 1;
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 1 || end < start) return undefined;
  return { start, end };
}

export default function (pi) {
  let root;
  let log;
  let warned = false;

  pi.on("session_start", (_event, ctx) => {
    root = undefined;
    log = undefined;
    warned = false;
    try {
      root = realpathSync(execFileSync("git", ["-C", ctx.cwd, "rev-parse", "--show-toplevel"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim());
      const gitDir = execFileSync("git", ["-C", ctx.cwd, "rev-parse", "--absolute-git-dir"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
      log = resolve(gitDir, "agent-lens", "reads.jsonl");
    } catch {
      // A session outside Git cannot publish events to an agent-lens project.
    }
  });

  pi.on("tool_result", (event, ctx) => {
    if (event.toolName !== "read" || event.isError || !root || !log || typeof event.input?.path !== "string") return;
    let range;
    let path;
    try {
      const resolved = resolveReadFile(ctx.cwd, event.input.path);
      if (!resolved) return;
      path = relative(root, resolved.file);
      range = readRange(resolved.selector, event.input);
      if (!path || path === ".." || path.startsWith(".." + sep) || isAbsolute(path) || path === ".git" || path.startsWith(".git" + sep)) return;
    } catch {
      // Removed/unreadable files do not affect the agent's read result.
      return;
    }
    try {
      mkdirSync(dirname(log), { recursive: true, mode: 0o700 });
      appendFileSync(log, JSON.stringify({ v: 1, kind: "read", path, agent: "pi", ...(range && { range }) }) + "\n", { mode: 0o600 });
    } catch (error) {
      if (!warned) {
        warned = true;
        console.error("[agent-lens] Cannot write read-event log:", error);
      }
    }
  });
}
