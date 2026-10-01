// The metadata log stays bounded across long-lived repositories.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import extension from "../extensions/pi-read-events.js";

const root = mkdtempSync(join(tmpdir(), "agent-lens-rotation-"));
execFileSync("git", ["init", "-q", root]);
writeFileSync(join(root, "file.lua"), "one\n");
const log = join(root, ".git", "agent-lens", "reads.jsonl");
mkdirSync(join(root, ".git", "agent-lens"), { recursive: true });
const handlers = new Map();
extension({ on: (name, handler) => handlers.set(name, handler) });
const emit = (name, event) => handlers.get(name)(event, { cwd: root });
const read = (id) => {
  emit("tool_call", { toolCallId: id, toolName: "read", input: { path: "file.lua" } });
  emit("tool_result", { toolCallId: id, toolName: "read", input: { path: "file.lua" }, details: {} });
};

try {
  const old = `${JSON.stringify({ v: 1, kind: "read", path: "old.lua", agent: "pi" })}\n`;
  writeFileSync(log, old.repeat(Math.ceil((4 * 1024 * 1024 + 1) / old.length)));
  emit("session_start", {});
  read("first");
  const records = readFileSync(log, "utf8").trim().split("\n").map((line) => JSON.parse(line));
  assert.ok(statSync(log).size < 4096, "oversized log is truncated");
  assert.ok(records.every((record) => record.path === "file.lua"), "only new records remain");
  assert.deepEqual(records.map((record) => record.kind), ["location", "location", "read"]);

  const small = statSync(log).size;
  emit("session_start", {});
  read("second");
  assert.ok(statSync(log).size > small, "a small log is appended to, not truncated");
  console.log("Metadata log rotation OK");
} finally {
  rmSync(root, { recursive: true, force: true });
}
