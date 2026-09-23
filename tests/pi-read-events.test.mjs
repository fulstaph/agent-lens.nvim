import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

function initRepo(prefix) {
  const root = mkdtempSync(join(tmpdir(), prefix));
  execFileSync("git", ["init", "-q", root]);
  return root;
}

function readEvents(root) {
  const log = join(root, ".git", "agent-lens", "reads.jsonl");
  if (!existsSync(log)) return [];
  return readFileSync(log, "utf8")
    .trim()
    .split("\n")
    .filter(Boolean)
    .map(JSON.parse);
}

const root = initRepo("agent-lens-pi-");
const otherRoot = initRepo("agent-lens-pi-other-");
const outsideRoot = mkdtempSync(join(tmpdir(), "agent-lens-outside-"));

try {
  writeFileSync(
    join(root, "sample.lua"),
    Array.from({ length: 160 }, (_, index) => `line ${index + 1}`).join("\n") + "\n",
  );
  writeFileSync(join(root, "sample.lua:2-3"), "literal filename\n");
  writeFileSync(join(root, "edit.lua"), "before\n");
  writeFileSync(join(root, "second.lua"), "second\n");
  writeFileSync(join(root, "renamed.lua"), "renamed\n");
  writeFileSync(join(outsideRoot, "secret.lua"), "SECRET OUTSIDE\n");
  symlinkSync(join(outsideRoot, "secret.lua"), join(root, "escaped.lua"));
  writeFileSync(join(otherRoot, "other.lua"), "other\n");

  const source = readFileSync(
    new URL("../extensions/pi-read-events.js", import.meta.url),
    "utf8",
  );
  const { default: extension } = await import(
    `data:text/javascript,${encodeURIComponent(source)}`
  );
  const handlers = new Map();
  extension({ on: (name, handler) => handlers.set(name, handler) });

  for (const name of [
    "session_start",
    "tool_call",
    "tool_result",
    "tool_execution_end",
    "session_shutdown",
  ]) {
    assert(handlers.has(name), `registers ${name}`);
  }

  const ctx = { cwd: root };
  const emit = async (name, event, eventCtx = ctx) => {
    await handlers.get(name)(event, eventCtx);
  };
  await emit("session_start", {}, ctx);

  await emit("tool_call", {
    toolName: "read",
    toolCallId: "read-range",
    input: { path: "sample.lua:10-12" },
  });
  await emit("tool_result", {
    toolName: "read",
    toolCallId: "read-range",
    isError: false,
    input: { path: "sample.lua:10-12" },
    details: { displayContent: { startLine: 10 } },
    content: [{ type: "text", text: "SECRET READ CONTENT" }],
  });

  await emit("tool_call", {
    toolName: "read",
    toolCallId: "read-open",
    input: { path: "sample.lua:20-" },
  });
  await emit("tool_result", {
    toolName: "read",
    toolCallId: "read-open",
    isError: false,
    input: { path: "sample.lua:20-" },
    details: { displayContent: { startLine: 20 } },
  });

  await emit("tool_call", {
    toolName: "read",
    toolCallId: "read-multi",
    input: { path: "sample.lua:30-31,40-41" },
  });
  await emit("tool_result", {
    toolName: "read",
    toolCallId: "read-multi",
    isError: false,
    input: { path: "sample.lua:30-31,40-41" },
    details: { displayContent: { startLine: 30 } },
  });

  await emit("tool_call", {
    toolName: "read",
    toolCallId: "read-tail",
    input: { path: "sample.lua:-5" },
  });
  await emit("tool_result", {
    toolName: "read",
    toolCallId: "read-tail",
    isError: false,
    input: { path: "sample.lua:-5" },
    details: { displayContent: { startLine: 156 } },
  });

  await emit("tool_call", {
    toolName: "read",
    toolCallId: "read-literal",
    input: { path: "sample.lua:2-3" },
  });
  await emit("tool_result", {
    toolName: "read",
    toolCallId: "read-literal",
    isError: false,
    input: { path: "sample.lua:2-3" },
  });

  await emit("tool_call", {
    toolName: "write",
    toolCallId: "write-new",
    input: { path: "created.lua", content: "SECRET WRITE CONTENT" },
  });
  writeFileSync(join(root, "created.lua"), "created\n");
  await emit("tool_result", {
    toolName: "write",
    toolCallId: "write-new",
    isError: false,
    input: { path: "created.lua", content: "SECRET WRITE CONTENT" },
  });

  await emit("tool_call", {
    toolName: "edit",
    toolCallId: "edit-direct",
    input: { path: "edit.lua", old_string: "SECRET OLD", new_string: "SECRET NEW" },
  });
  await emit("tool_result", {
    toolName: "edit",
    toolCallId: "edit-direct",
    isError: false,
    input: { path: "edit.lua" },
    details: { path: "edit.lua", firstChangedLine: 7 },
  });

  await emit("tool_call", {
    toolName: "edit",
    toolCallId: "edit-multi",
    input: {
      paths: ["edit.lua", "second.lua"],
      input: "SECRET PATCH BODY",
    },
  });
  await emit("tool_result", {
    toolName: "edit",
    toolCallId: "edit-multi",
    isError: false,
    input: { paths: ["edit.lua", "second.lua"] },
    details: {
      perFileResults: [
        { path: "deleted.lua", op: "delete", firstChangedLine: 1 },
        {
          path: "renamed.lua",
          sourcePath: "second.lua",
          op: "update",
          firstChangedLine: 4,
        },
      ],
    },
  });

  await emit("tool_call", {
    toolName: "read",
    toolCallId: "read-error",
    input: { path: "sample.lua:4-5" },
  });
  await emit("tool_result", {
    toolName: "read",
    toolCallId: "read-error",
    isError: true,
    input: { path: "sample.lua:4-5" },
    content: [{ type: "text", text: "SECRET ERROR" }],
  });

  await emit("tool_call", {
    toolName: "write",
    toolCallId: "write-fallback-error",
    input: { path: "never-created.lua", content: "SECRET" },
  });
  await emit("tool_execution_end", {
    toolName: "write",
    toolCallId: "write-fallback-error",
    isError: true,
  });

  await emit("tool_call", {
    toolName: "edit",
    toolCallId: "parallel-old",
    input: { path: "edit.lua" },
  });
  await emit("tool_call", {
    toolName: "edit",
    toolCallId: "parallel-new",
    input: { path: "second.lua" },
  });
  await emit("tool_result", {
    toolName: "edit",
    toolCallId: "parallel-old",
    isError: false,
    input: { path: "edit.lua" },
    details: { path: "edit.lua", firstChangedLine: 2 },
  });
  await emit("tool_result", {
    toolName: "edit",
    toolCallId: "parallel-new",
    isError: false,
    input: { path: "second.lua" },
    details: { path: "second.lua", firstChangedLine: 3 },
  });

  const countBeforeRejected = readEvents(root).length;
  for (const [toolName, toolCallId, input] of [
    ["read", "reject-outside", { path: join(outsideRoot, "secret.lua") }],
    ["read", "reject-git", { path: ".git/config" }],
    ["read", "reject-symlink", { path: "escaped.lua" }],
    ["read", "reject-url", { path: "https://example.com/a.lua" }],
    ["write", "reject-parent", { path: "../outside.lua", content: "SECRET" }],
  ]) {
    await emit("tool_call", { toolName, toolCallId, input });
  }
  assert.equal(
    readEvents(root).length,
    countBeforeRejected,
    "unsafe and non-file targets do not emit",
  );

  const events = readEvents(root);
  assert.deepEqual(events.slice(0, 3), [
    {
      v: 1,
      kind: "location",
      phase: "start",
      tool: "read",
      toolCallId: "read-range",
      path: "sample.lua",
      agent: "pi",
      line: 10,
    },
    {
      v: 1,
      kind: "location",
      phase: "success",
      tool: "read",
      toolCallId: "read-range",
      path: "sample.lua",
      agent: "pi",
      line: 10,
    },
    {
      v: 1,
      kind: "read",
      path: "sample.lua",
      agent: "pi",
      range: { start: 10, end: 12 },
    },
  ]);

  const byId = (id) => events.filter((event) => event.toolCallId === id);
  assert.deepEqual(byId("read-open").map((event) => event.line), [20, 20]);
  assert.deepEqual(events[5], {
    v: 1,
    kind: "read",
    path: "sample.lua",
    agent: "pi",
  });
  assert.deepEqual(byId("read-multi").map((event) => event.line), [30, 30]);
  assert.deepEqual(byId("read-tail").map((event) => event.line), [undefined, 156]);
  assert.deepEqual(byId("read-literal").map((event) => event.path), [
    "sample.lua:2-3",
    "sample.lua:2-3",
  ]);
  assert.deepEqual(byId("write-new").map((event) => [event.phase, event.line]), [
    ["start", 1],
    ["success", 1],
  ]);
  assert.deepEqual(byId("edit-direct").map((event) => [event.phase, event.path, event.line]), [
    ["start", "edit.lua", undefined],
    ["success", "edit.lua", 7],
  ]);
  assert.deepEqual(byId("edit-multi").map((event) => [event.phase, event.path, event.line]), [
    ["start", "edit.lua", undefined],
    ["success", "renamed.lua", 4],
  ]);
  assert.deepEqual(byId("read-error").map((event) => event.phase), ["start", "error"]);
  assert.deepEqual(byId("write-fallback-error").map((event) => event.phase), [
    "start",
    "error",
  ]);
  assert.deepEqual(byId("parallel-old").map((event) => event.phase), [
    "start",
    "success",
  ]);
  assert.deepEqual(byId("parallel-new").map((event) => event.phase), [
    "start",
    "success",
  ]);
  assert(
    !events.some(
      (event) =>
        event.kind === "read" &&
        event.path === "sample.lua" &&
        event.range?.start === 4,
    ),
    "failed reads do not create legacy activity",
  );

  const allowed = {
    read: new Set(["v", "kind", "path", "agent", "range"]),
    location: new Set([
      "v",
      "kind",
      "phase",
      "tool",
      "toolCallId",
      "path",
      "agent",
      "line",
    ]),
  };
  for (const event of events) {
    assert(allowed[event.kind], `known event kind: ${event.kind}`);
    for (const key of Object.keys(event)) {
      assert(allowed[event.kind].has(key), `metadata allowlist rejects ${key}`);
    }
  }
  const serialized = JSON.stringify(events);
  for (const secret of [
    "SECRET READ CONTENT",
    "SECRET WRITE CONTENT",
    "SECRET OLD",
    "SECRET NEW",
    "SECRET PATCH BODY",
    "SECRET ERROR",
    outsideRoot,
    root,
  ]) {
    assert(!serialized.includes(secret), `does not serialize ${secret}`);
  }

  const otherCtx = { cwd: otherRoot };
  await emit(
    "tool_call",
    {
      toolName: "read",
      toolCallId: "other-root",
      input: { path: "other.lua:1-1" },
    },
    otherCtx,
  );
  await emit(
    "tool_result",
    {
      toolName: "read",
      toolCallId: "other-root",
      isError: false,
      input: { path: "other.lua:1-1" },
    },
    otherCtx,
  );
  assert.deepEqual(readEvents(otherRoot).map((event) => event.kind), [
    "location",
    "location",
    "read",
  ]);

  await emit("session_shutdown", {}, otherCtx);
  console.log("Pi agent event hook OK");
} finally {
  rmSync(root, { recursive: true, force: true });
  rmSync(otherRoot, { recursive: true, force: true });
  rmSync(outsideRoot, { recursive: true, force: true });
}
