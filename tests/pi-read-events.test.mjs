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
  writeFileSync(join(root, "structured.lua"), "structured\n");
  writeFileSync(join(root, "patch.lua"), "patch\n");
  writeFileSync(join(root, "patch-delete.lua"), "delete\n");
  writeFileSync(join(root, "google.lua"), "google\n");
  writeFileSync(join(outsideRoot, "secret.lua"), "SECRET OUTSIDE\n");
  symlinkSync(join(outsideRoot, "secret.lua"), join(root, "escaped.lua"));
  symlinkSync(join(outsideRoot, "missing-dir"), join(root, "dangling"));
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
    "message_update",
    "message_end",
    "turn_end",
    "tool_call",
    "tool_result",
    "tool_execution_end",
    "session_shutdown",
  ]) {
    assert(handlers.has(name), `registers ${name}`);
  }

  const streamInputs = new Map();

  const ctx = { cwd: root };
  const emit = async (name, event, eventCtx = ctx) => {
    await handlers.get(name)(event, eventCtx);
  };
  const streamUpdate = async (
    toolCallId,
    toolName,
    argumentsValue,
    options = {},
  ) => {
    const currentInput =
      typeof argumentsValue?.input === "string" ? argumentsValue.input : undefined;
    const previousInput = streamInputs.get(toolCallId);
    const inferredDelta =
      typeof currentInput === "string" && typeof previousInput === "string"
        && currentInput.startsWith(previousInput)
        ? currentInput.slice(previousInput.length)
        : typeof currentInput === "string" && previousInput === undefined
          ? currentInput
          : "";
    const content = {
      type: "toolCall",
      id: toolCallId,
      name: toolName,
      arguments: argumentsValue,
    };
    streamInputs.set(toolCallId, currentInput);
    await emit("message_update", {
      type: "message_update",
      message: { role: "assistant" },
      assistantMessageEvent: {
        type: options.final ? "toolcall_end" : "toolcall_delta",
        contentIndex: options.contentIndex ?? 0,
        delta: options.delta ?? inferredDelta,
        partial: { role: "assistant", content: [content] },
        ...(options.final && { toolCall: content }),
      },
    });
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

  const progressEvents = () =>
    readEvents(root).filter(
      (event) => event.kind === "location" && event.phase === "progress",
    );
  const progressFor = (toolCallId) =>
    progressEvents().filter((event) => event.toolCallId === toolCallId);

  await streamUpdate("stream-hash", "edit", {
    input: "[edit.lua#",
  });
  assert.equal(progressFor("stream-hash").length, 0, "incomplete header waits");
  await streamUpdate("stream-hash", "edit", {
    input: "[edit.lua#A1B2]\n",
  });
  await streamUpdate("stream-hash", "edit", {
    input: "[edit.lua#A1B2]\nPUT 7.=7:",
  });
  assert.deepEqual(progressFor("stream-hash").map((event) => event.line), [
    undefined,
  ]);
  await streamUpdate("stream-hash", "edit", {
    input: "[edit.lua#A1B2]\nPUT 7.=7:\n",
  });
  await streamUpdate("stream-hash", "edit", {
    input: "[edit.lua#A1B2]\nPUT 7.=7:\n+SECRET PATCH BODY\n",
  });
  await streamUpdate("stream-hash", "edit", {
    input: "[edit.lua#A1B2]\nPUT 7.=7:\n+SECRET PATCH BODY\n",
  });
  await streamUpdate("stream-hash", "edit", {
    input: "[edit.lua#A1B2]\nPUT 7.=7:\n+SECRET PATCH BODY\n[second.lua#C3D4]\n",
  });
  await streamUpdate("stream-hash", "edit", {
    input:
      "[edit.lua#A1B2]\nPUT 7.=7:\n+SECRET PATCH BODY\n[second.lua#C3D4]\nCUT 3* @block\n",
  });
  await streamUpdate(
    "stream-hash",
    "edit",
    {
      input:
        "[edit.lua#A1B2]\nPUT 7.=7:\n+SECRET PATCH BODY\n[second.lua#C3D4]\nCUT 3* @block\n",
    },
    { final: true },
  );
  await emit("tool_call", {
    toolName: "edit",
    toolCallId: "stream-hash",
    input: {
      path: "second.lua",
      input: "SECRET PATCH BODY",
    },
  });
  await emit("tool_result", {
    toolName: "edit",
    toolCallId: "stream-hash",
    isError: false,
    input: { path: "second.lua" },
    details: { path: "second.lua", firstChangedLine: 3 },
  });
  await streamUpdate("stream-no-anchor", "edit", {
    input: "[edit.lua#A1B2]\n",
  });
  await streamUpdate("stream-no-anchor", "edit", {
    input: "[edit.lua#A1B2]\nPUT 7.=7:\n",
  });
  await streamUpdate("stream-no-anchor", "edit", {
    input: "[edit.lua#A1B2]\nPUT 7.=7:\nPUT >$\n",
  });
  await emit("tool_call", {
    toolName: "edit",
    toolCallId: "stream-no-anchor",
    input: { path: "edit.lua" },
  });
  await emit("tool_result", {
    toolName: "edit",
    toolCallId: "stream-no-anchor",
    isError: false,
    input: { path: "edit.lua" },
    details: { path: "edit.lua", firstChangedLine: 7 },
  });
  await streamUpdate("stream-rem", "edit", {
    input: "[edit.lua#A1B2]\nPUT 7.=7:\n",
  });
  await streamUpdate("stream-rem", "edit", {
    input: "[edit.lua#A1B2]\nPUT 7.=7:\nREM\n",
  });
  await emit("tool_call", {
    toolName: "edit",
    toolCallId: "stream-rem",
    input: { path: "edit.lua" },
  });
  await emit("tool_result", {
    toolName: "edit",
    toolCallId: "stream-rem",
    isError: false,
    input: { path: "edit.lua" },
    details: { path: "edit.lua", firstChangedLine: 7 },
  });

  await streamUpdate("stream-mv", "edit", {
    input: "[edit.lua#A1B2]\nPUT 7.=7:\n",
  });
  await streamUpdate("stream-mv", "edit", {
    input: "[edit.lua#A1B2]\nPUT 7.=7:\nMV renamed.lua\n",
  });
  await emit("tool_call", {
    toolName: "edit",
    toolCallId: "stream-mv",
    input: { path: "edit.lua" },
  });
  await emit("tool_result", {
    toolName: "edit",
    toolCallId: "stream-mv",
    isError: false,
    input: { path: "edit.lua" },
    details: { path: "edit.lua", firstChangedLine: 7 },
  });
  await streamUpdate("stream-replaced", "edit", {
    input: "[edit.lua#A1B2]\nPUT 7.=7:\n",
  });
  await streamUpdate("stream-replaced", "edit", {
    input: "[second.lua#C3D4]\nCUT 3* @block\n",
  });
  await emit("tool_call", {
    toolName: "edit",
    toolCallId: "stream-replaced",
    input: { path: "second.lua" },
  });
  await emit("tool_result", {
    toolName: "edit",
    toolCallId: "stream-replaced",
    isError: false,
    input: { path: "second.lua" },
    details: { path: "second.lua", firstChangedLine: 3 },
  });


  await streamUpdate("stream-patch-wire", "apply_patch", {
    input: "*** Update File: patch.lua\n",
  });
  await emit("tool_call", {
    toolName: "apply_patch",
    toolCallId: "stream-patch-wire",
    input: { input: "*** Update File: patch.lua\n" },
  });
  await emit("tool_result", {
    toolName: "apply_patch",
    toolCallId: "stream-patch-wire",
    isError: false,
    input: { input: "*** Update File: patch.lua\n" },
    details: { path: "patch.lua", firstChangedLine: 2 },
  });
  await streamUpdate("stream-patch-delete", "apply_patch", {
    input: "*** Delete File: patch-delete.lua\n",
  });
  await emit("tool_call", {
    toolName: "apply_patch",
    toolCallId: "stream-patch-delete",
    input: { input: "*** Delete File: patch-delete.lua\n" },
  });
  rmSync(join(root, "patch-delete.lua"));
  await emit("tool_result", {
    toolName: "apply_patch",
    toolCallId: "stream-patch-delete",
    isError: false,
    input: { input: "*** Delete File: patch-delete.lua\n" },
    details: {
      perFileResults: [{ path: "patch-delete.lua", op: "delete", success: true }],
    },
  });

  await streamUpdate("stream-structured", "edit", {
    path: "structured.lua",
    old_string: "SECRET OLD",
    new_string: "SECRET NEW",
  });
  await emit("tool_call", {
    toolName: "edit",
    toolCallId: "stream-structured",
    input: { path: "structured.lua" },
  });
  await emit("tool_result", {
    toolName: "edit",
    toolCallId: "stream-structured",
    isError: false,
    input: { path: "structured.lua" },
    details: { path: "structured.lua", firstChangedLine: 2 },
  });

  await streamUpdate("stream-patch", "apply_patch", {
    input: "*** Update File: patch.lua\n*** End Patch\n",
  });
  await emit("tool_call", {
    toolName: "edit",
    toolCallId: "stream-patch",
    input: { path: "patch.lua" },
  });
  await emit("tool_result", {
    toolName: "edit",
    toolCallId: "stream-patch",
    isError: false,
    input: { path: "patch.lua" },
    details: { path: "patch.lua", firstChangedLine: 1 },
  });

  await streamUpdate(
    "stream-google",
    "edit",
    {
      input: "[google.lua#A1B2]\nPUT 4.=4:\n",
    },
    { delta: "SECRET RAW DELTA" },
  );
  await emit("tool_call", {
    toolName: "edit",
    toolCallId: "stream-google",
    input: { path: "google.lua" },
  });
  await emit("tool_result", {
    toolName: "edit",
    toolCallId: "stream-google",
    isError: false,
    input: { path: "google.lua" },
    details: { path: "google.lua", firstChangedLine: 4 },
  });
  await streamUpdate("stream-final-line", "edit", {
    input: "[google.lua#A1B2]\nPUT 5.=5:",
  });
  assert.deepEqual(
    progressFor("stream-final-line").map((event) => event.line),
    [undefined],
    "unterminated operation waits for toolcall_end",
  );
  await streamUpdate(
    "stream-final-line",
    "edit",
    { input: "[google.lua#A1B2]\nPUT 5.=5:" },
    { final: true },
  );
  await emit("tool_call", {
    toolName: "edit",
    toolCallId: "stream-final-line",
    input: { path: "google.lua" },
  });
  await emit("tool_result", {
    toolName: "edit",
    toolCallId: "stream-final-line",
    isError: false,
    input: { path: "google.lua" },
    details: { path: "google.lua", firstChangedLine: 5 },
  });

  for (const [toolCallId, input] of [
    ["stream-incomplete", { input: "[edit.lua#A1B2]" }],
    ["stream-empty-json", {}],
    ["stream-outside", { path: join(outsideRoot, "secret.lua") }],
    ["stream-git", { path: ".git/config" }],
    ["stream-symlink", { path: "escaped.lua" }],
    ["stream-dangling", { path: "dangling/new.lua" }],
  ]) {
    await streamUpdate(toolCallId, "edit", input);
  }
  assert.equal(progressFor("stream-incomplete").length, 0, "incomplete final line waits");
  assert.equal(progressFor("stream-empty-json").length, 0, "empty partial waits");
  assert.equal(progressFor("stream-outside").length, 0, "outside progress is rejected");
  assert.equal(progressFor("stream-git").length, 0, "git progress is rejected");
  assert.equal(progressFor("stream-symlink").length, 0, "symlink progress is rejected");
  assert.equal(progressFor("stream-dangling").length, 0, "dangling parent symlink is rejected");

  await streamUpdate("stream-message-end", "edit", { path: "edit.lua" });
  await emit("message_end", {
    type: "message_end",
    message: { role: "assistant", stopReason: "stop" },
  });
  await streamUpdate("stream-turn-end", "edit", { path: "edit.lua" });
  await emit("turn_end", {
    type: "turn_end",
    turnIndex: 1,
    message: { role: "assistant", stopReason: "toolUse" },
    toolResults: [],
  });
  const errorsAfterTurnEnd = readEvents(root).filter(
    (event) =>
      event.kind === "location" &&
      event.phase === "error" &&
      ["stream-message-end", "stream-turn-end"].includes(event.toolCallId),
  );
  assert.deepEqual(
    errorsAfterTurnEnd.map((event) => event.toolCallId),
    ["stream-message-end", "stream-turn-end"],
    "stream cleanup reports each abandoned call once",
  );
  await emit("turn_end", {
    type: "turn_end",
    turnIndex: 2,
    message: { role: "assistant", stopReason: "toolUse" },
    toolResults: [],
  });

  const countBeforeRejected = readEvents(root).length;
  for (const [toolName, toolCallId, input] of [
    ["read", "reject-outside", { path: join(outsideRoot, "secret.lua") }],
    ["read", "reject-git", { path: ".git/config" }],
    ["read", "reject-symlink", { path: "escaped.lua" }],
    ["read", "reject-url", { path: "https://example.com/a.lua" }],
    ["write", "reject-parent", { path: "../outside.lua", content: "SECRET" }],
    ["edit", "reject-dangling", { path: "dangling/new.lua" }],
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
  assert.deepEqual(
    byId("stream-hash").map((event) => [
      event.phase,
      event.path,
      event.line,
      event.sequence,
    ]),
    [
      ["progress", "edit.lua", undefined, 1],
      ["progress", "edit.lua", 7, 2],
      ["progress", "second.lua", undefined, 3],
      ["progress", "second.lua", 3, 4],
      ["start", "second.lua", undefined, undefined],
      ["success", "second.lua", 3, undefined],
    ],
    "hashline progress follows complete sections and hunks",
  );
  assert.deepEqual(
    byId("stream-no-anchor").map((event) => [
      event.phase,
      event.path,
      event.line,
      event.sequence,
    ]),
    [
      ["progress", "edit.lua", undefined, 1],
      ["progress", "edit.lua", 7, 2],
      ["progress", "edit.lua", undefined, 3],
      ["start", "edit.lua", undefined, undefined],
      ["success", "edit.lua", 7, undefined],
    ],
    "no-anchor operations clear the previous hunk line",
  );
  for (const [toolCallId, operation] of [
    ["stream-rem", "REM"],
    ["stream-mv", "MV"],
  ]) {
    assert.deepEqual(
      byId(toolCallId).map((event) => [
        event.phase,
        event.path,
        event.line,
        event.sequence,
      ]),
      [
        ["progress", "edit.lua", 7, 1],
        ["progress", "edit.lua", undefined, 2],
        ["start", "edit.lua", undefined, undefined],
        ["success", "edit.lua", 7, undefined],
      ],
      `${operation} clears the previous hunk line`,
    );
  }
  assert.deepEqual(
    byId("stream-replaced").map((event) => [
      event.phase,
      event.path,
      event.line,
      event.sequence,
    ]),
    [
      ["progress", "edit.lua", 7, 1],
      ["progress", "second.lua", 3, 2],
      ["start", "second.lua", undefined, undefined],
      ["success", "second.lua", 3, undefined],
    ],
    "replaced partial snapshots reset parser state safely",
  );
  assert.deepEqual(
    byId("stream-patch-wire").map((event) => [
      event.phase,
      event.tool,
      event.path,
      event.line,
    ]),
    [
      ["progress", "edit", "patch.lua", undefined],
      ["start", "edit", "patch.lua", undefined],
      ["success", "edit", "patch.lua", 2],
    ],
    "apply-patch lifecycle normalizes to edit",
  );
  assert.deepEqual(
    byId("stream-patch-delete").map((event) => [
      event.phase,
      event.tool,
      event.path,
      event.line,
    ]),
    [
      ["progress", "edit", "patch-delete.lua", undefined],
      ["start", "edit", "patch-delete.lua", undefined],
      ["success", "edit", "patch-delete.lua", undefined],
    ],
    "deleted apply-patch targets settle without a stale line",
  );
  assert.deepEqual(
    byId("stream-structured").map((event) => [event.phase, event.path, event.line]),
    [
      ["progress", "structured.lua", undefined],
      ["start", "structured.lua", undefined],
      ["success", "structured.lua", 2],
    ],
    "structured edits expose a safe path before execution",
  );
  assert.deepEqual(
    byId("stream-patch").map((event) => [event.phase, event.path, event.line]),
    [
      ["progress", "patch.lua", undefined],
      ["start", "patch.lua", undefined],
      ["success", "patch.lua", 1],
    ],
    "apply-patch headers expose only their safe path",
  );
  assert.deepEqual(
    byId("stream-google").map((event) => [event.phase, event.path, event.line]),
    [
      ["progress", "google.lua", 4],
      ["start", "google.lua", undefined],
      ["success", "google.lua", 4],
    ],
    "single complete provider delta produces one progress jump",
  );
  assert.deepEqual(
    byId("stream-final-line").map((event) => [
      event.phase,
      event.path,
      event.line,
      event.sequence,
    ]),
    [
      ["progress", "google.lua", undefined, 1],
      ["progress", "google.lua", 5, 2],
      ["start", "google.lua", undefined, undefined],
      ["success", "google.lua", 5, undefined],
    ],
    "toolcall_end completes an unterminated final operation line",
  );
  assert.deepEqual(byId("stream-message-end").map((event) => event.phase), [
    "progress",
    "error",
  ]);
  assert.deepEqual(byId("stream-turn-end").map((event) => event.phase), [
    "progress",
    "error",
  ]);


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
      "sequence",
    ]),
  };
  for (const event of events) {
    assert(allowed[event.kind], `known event kind: ${event.kind}`);
    for (const key of Object.keys(event)) {
      assert(allowed[event.kind].has(key), `metadata allowlist rejects ${key}`);
    }
    if (event.kind === "location" && event.phase === "progress") {
      assert.equal(event.tool, "edit", "progress is edit-only");
      assert(Number.isSafeInteger(event.sequence) && event.sequence > 0);
    } else if (event.kind === "location") {
      assert(!("sequence" in event), "sequence is progress-only");
    }
  }
  const serialized = JSON.stringify(events);
  for (const secret of [
    "SECRET READ CONTENT",
    "SECRET WRITE CONTENT",
    "SECRET OLD",
    "SECRET NEW",
    "SECRET RAW DELTA",
    "SECRET PATCH BODY",
    "SECRET ERROR",
    "*** Update File: patch.lua",
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
