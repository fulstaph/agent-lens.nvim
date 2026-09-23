import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const root = mkdtempSync(join(tmpdir(), "agent-lens-pi-"));
try {
  execFileSync("git", ["init", "-q", root]);
  writeFileSync(join(root, "sample.lua"), "hello\n");
  const source = readFileSync(new URL("../extensions/pi-read-events.js", import.meta.url), "utf8");
  const { default: extension } = await import(`data:text/javascript,${encodeURIComponent(source)}`);
  const handlers = new Map();
  extension({ on: (name, handler) => handlers.set(name, handler) });
  assert(handlers.has("session_start") && handlers.has("tool_result"));

  const ctx = { cwd: root };
  handlers.get("session_start")({}, ctx);
  handlers.get("tool_result")({ toolName: "read", isError: false, input: { path: "sample.lua" }, content: [{ type: "text", text: "SECRET" }] }, ctx);
  handlers.get("tool_result")({ toolName: "read", isError: false, input: { path: "sample.lua:raw:1-1" } }, ctx);
  handlers.get("tool_result")({ toolName: "read", isError: true, input: { path: "sample.lua" } }, ctx);
  handlers.get("tool_result")({ toolName: "bash", isError: false, input: { path: "sample.lua" } }, ctx);
  handlers.get("tool_result")({ toolName: "read", isError: false, input: { path: ".git/config" } }, ctx);

  const log = join(root, ".git", "agent-lens", "reads.jsonl");
  assert(existsSync(log));
  const contents = readFileSync(log, "utf8");
  assert(!contents.includes("SECRET"), "never log read contents");
  const events = contents.trim().split("\n").map(JSON.parse);
  assert.deepEqual(events, [
    { v: 1, kind: "read", path: "sample.lua", agent: "pi" },
    { v: 1, kind: "read", path: "sample.lua", agent: "pi" },
  ]);
  console.log("Pi read hook OK");
} finally {
  rmSync(root, { recursive: true, force: true });
}
