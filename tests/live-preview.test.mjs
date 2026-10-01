import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createConnection } from "node:net";
import extension from "../extensions/pi-read-events.js";
import { previewDirectory } from "../extensions/live-preview.js";

const root = mkdtempSync(join(tmpdir(), "agent-lens-live-"));
const socketDirectory = previewDirectory(root);
execFileSync("git", ["init", "-q", root]);
writeFileSync(join(root, "edit.lua"), "one\ntwo\nthree\nfour\n");
writeFileSync(join(root, "user.lua"), "original user text\n");
const outside = mkdtempSync(join(tmpdir(), "agent-lens-live-outside-"));
writeFileSync(join(outside, "secret.lua"), "OUTSIDE SECRET\n");
symlinkSync(join(outside, "secret.lua"), join(root, "escaped.lua"));
const handlers = new Map();
extension({ on: (name, handler) => handlers.set(name, handler) });
const emit = (name, event) => handlers.get(name)(event, { cwd: root });
emit("session_start", {});
const editor = spawn("nvim", ["--headless", "-u", "NONE", "-l", "tests/live_preview.lua", root], {
  stdio: ["pipe", "pipe", "pipe"],
});
let stderr = "";
editor.stderr.on("data", (chunk) => { stderr += chunk; });
let output = "";
let counter = 0;
const responses = new Map();
let resolveReady;
const ready = new Promise((resolve) => { resolveReady = resolve; });
editor.stdout.on("data", (chunk) => {
  output += chunk;
  while (output.includes("\n")) {
    const boundary = output.indexOf("\n");
    const line = output.slice(0, boundary);
    output = output.slice(boundary + 1);
    const response = JSON.parse(line);
    if (response.ready) resolveReady();
    else {
      responses.get(response.id)?.(response);
      responses.delete(response.id);
    }
  }
});
const exited = new Promise((resolve) => editor.on("exit", (code) => resolve(code)));
const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function query(kind = "inspect") {
  const id = ++counter;
  const answer = new Promise((resolve) => responses.set(id, resolve));
  editor.stdin.write(`${JSON.stringify({ kind, id })}\n`);
  return Promise.race([answer, pause(2000).then(() => { throw new Error(`No UI response: ${stderr}`); })]);
}
async function waitFor(check) {
  let state;
  for (let attempt = 0; attempt < 100; attempt++) {
    state = await query();
    if (check(state)) return state;
    await pause(20);
  }
  assert.fail(`UI condition not reached: ${JSON.stringify(state)} ${stderr}`);
}
function stream(id, name, args, final = false) {
  const call = { type: "toolCall", id, name, arguments: args };
  emit("message_update", {
    assistantMessageEvent: {
      type: final ? "toolcall_end" : "toolcall_delta",
      partial: { content: [call] }, contentIndex: 0,
      ...(final && { toolCall: call }),
    },
  });
}
const draftLines = (state) => state.drafts[0]?.lines;
const matches = (state, lines) => JSON.stringify(draftLines(state)) === JSON.stringify(lines);
function toolCall(id, toolName, input) {
  emit("tool_call", { toolCallId: id, toolName, input });
}
function result(id, toolName, input, details = {}, isError = false) {
  emit("tool_result", { toolCallId: id, toolName, input, details, isError });
}

try {
  await Promise.race([ready, pause(2000).then(() => { throw new Error(`Editor did not start: ${stderr}`); })]);
  assert(existsSync(join(previewDirectory(root), `${editor.pid}.sock`)), "receiver socket exists");
  stream("write", "write", { path: "new.lua", content: "local first = 1\n" });
  let state = await waitFor((current) => matches(current, ["local first = 1"]));
  assert.equal(state.drafts[0].modified, false);
  assert.equal(state.drafts[0].modifiable, false, "draft is read-only");
  assert(!existsSync(join(root, "new.lua")), "preview does not write a file");
  stream("write", "write", { path: "new.lua", content: "local first = 1\nlocal second = " });
  state = await waitFor((current) => matches(current, ["local first = 1", "local second = "]));
  assert.equal(state.marks[0].line, 2, "marker follows incomplete generated line");
  stream("write", "write", { path: "new.lua", content: "local first = 1\nlocal second = 2\n" }, true);
  toolCall("write", "write", { path: "new.lua", content: "local first = 1\nlocal second = 2\n" });
  await waitFor((current) => matches(current, ["local first = 1", "local second = 2"])
    && current.marks[0]?.label.includes("applying"));
  writeFileSync(join(root, "new.lua"), "local first = 1\nlocal second = 2\n");
  result("write", "write", { path: "new.lua" });
  state = await waitFor((current) => !current.drafts.length && current.name.endsWith("/new.lua"));
  assert.deepEqual(state.lines, ["local first = 1", "local second = 2"], "completion shows disk contents");

  stream("hash", "edit", { input: "[edit.lua#A1B2]\nPUT 2.=2:\n+TWO" });
  await waitFor((current) => matches(current, ["one", "TWO", "three", "four"]));
  stream("hash", "edit", { input: "[edit.lua#A1B2]\nPUT 2.=2:\n+TWO\n+INSERTED\n" });
  state = await waitFor((current) => matches(current, ["one", "TWO", "INSERTED", "three", "four"]));
  assert.equal(state.marks[0].line, 3, "hashline body advances the marker");
  assert.equal(readFileSync(join(root, "edit.lua"), "utf8"), "one\ntwo\nthree\nfour\n");
  toolCall("hash", "edit", { input: "[edit.lua#A1B2]\nPUT 2.=2:\n+TWO\n+INSERTED\n" });
  result("hash", "edit", {}, {}, true);
  await waitFor((current) => !current.drafts.length && !current.marks.length);
  assert.equal((await query()).name.endsWith("/edit.lua"), true, "error restores source buffer");

  stream("replace", "edit", { path: "edit.lua", oldText: "two", newText: "REPLACEMENT" });
  await waitFor((current) => matches(current, ["one", "REPLACEMENT", "three", "four"]));
  emit("message_end", { message: { role: "assistant", stopReason: "aborted" } });
  await waitFor((current) => !current.drafts.length);

  stream("patch-add", "apply_patch", { input: "*** Begin Patch\n*** Add File: patch.lua\n+first\n+sec" });
  await waitFor((current) => matches(current, ["first", "sec"]));
  stream("patch-add", "apply_patch", { input: "*** Begin Patch\n*** Add File: patch.lua\n+first\n+second\n*** End Patch\n" }, true);
  toolCall("patch-add", "apply_patch", { input: "*** Begin Patch\n*** Add File: patch.lua\n+first\n+second\n*** End Patch\n" });
  writeFileSync(join(root, "patch.lua"), "first\nsecond\n");
  result("patch-add", "apply_patch", {}, { path: "patch.lua", firstChangedLine: 1 });
  await waitFor((current) => !current.drafts.length && current.name.endsWith("/patch.lua"));

  stream("patch-update", "apply_patch", {
    input: "*** Begin Patch\n*** Update File: edit.lua\n@@\n one\n-two\n+PATCHED\n three\n*** End Patch\n",
  });
  await waitFor((current) => matches(current, ["one", "PATCHED", "three", "four"]));
  emit("turn_end", {});
  await waitFor((current) => !current.drafts.length);

  await query("edit");
  stream("protected", "write", { path: "protected.lua", content: "AGENT DRAFT\n" });
  state = await waitFor((current) => matches(current, ["AGENT DRAFT"]));
  assert.deepEqual(state.lines, ["unsaved user text"], "unsaved buffer keeps focus and contents");
  assert.equal(state.modified, true);
  assert.equal(state.windows, 2, "draft uses a safe split");
  await query("toggle");
  state = await waitFor((current) => !current.drafts.length);
  assert.deepEqual(state.lines, ["unsaved user text"]);
  await query("toggle");
  emit("turn_end", {});
  stream("unsafe", "write", { path: "escaped.lua", content: "REJECT THIS" });
  stream("outside", "write", { path: join(outside, "secret.lua"), content: "REJECT THIS" });
  stream("git", "write", { path: ".git/config", content: "REJECT THIS" });
  await pause(100);
  assert.equal((await query()).drafts.length, 0, "unsafe preview targets are rejected");

  // Independently exercise the receiver boundary, including partial framing and replay.
  const socket = createConnection(join(previewDirectory(root), `${editor.pid}.sock`));
  await new Promise((resolve) => socket.on("connect", resolve));
  const event = { v: 1, kind: "preview", tool: "write", toolCallId: "wire", path: "wire.lua",
    line: 1, sequence: 1, agent: "pi", lines: ["WIRE DRAFT"] };
  const encoded = JSON.stringify(event);
  socket.write(encoded.slice(0, 20));
  await pause(30);
  assert.equal((await query()).drafts.length, 0, "partial socket records wait");
  socket.write(`${encoded.slice(20)}\n`);
  await waitFor((current) => matches(current, ["WIRE DRAFT"]));
  socket.write(`${JSON.stringify({ ...event, lines: ["STALE DRAFT"] })}\n`);
  socket.write(`${JSON.stringify({ ...event, sequence: 2, path: "../outside.lua" })}\n`);
  socket.write(`${JSON.stringify({ ...event, sequence: 2, path: "escaped.lua" })}\n`);
  socket.write(`${JSON.stringify({ ...event, sequence: 2, lines: ["bad\nframing"] })}\n`);
  socket.write(`${JSON.stringify({ ...event, toolCallId: "write", sequence: 100, lines: ["LATE DRAFT"] })}\n`);
  await pause(50);
  assert(matches(await query(), ["WIRE DRAFT"]), "receiver rejects stale and invalid snapshots");
  socket.end();
  await waitFor((current) => !current.drafts.length);

  stream("paused-success", "write", { path: "paused.lua", content: "FROZEN SNAPSHOT\n" });
  await waitFor((current) => matches(current, ["FROZEN SNAPSHOT"]));
  await query("pause");
  stream("paused-success", "write", { path: "paused.lua", content: "LATEST SAVED\n" }, true);
  toolCall("paused-success", "write", { path: "paused.lua", content: "LATEST SAVED\n" });
  writeFileSync(join(root,"paused.lua"),"LATEST SAVED\n");
  result("paused-success", "write", { path: "paused.lua" });
  emit("turn_end", {});
  await pause(200);
  state=await query();
  assert.equal(state.control,"paused");
  assert(matches(state,["FROZEN SNAPSHOT"]),"successful completion/closure while paused keeps visible snapshot frozen");
  await query("resume");
  await waitFor((current) => !current.drafts.length && current.control==="following");
  assert.equal((await query()).status.activity.phase,"settled");

  stream("oversized", "write", { path: "oversized.lua", content: "x".repeat(1024 * 1024 + 1) });
  stream("too-many-lines", "edit", { input: "[edit.lua#A1B2]\nPUT 2.=2:\n" + "+x\n".repeat(20001) });
  await pause(100);
  assert.equal((await query()).drafts.length, 0, "oversized drafts fall back without crashing the host");

  const metadata = readFileSync(join(root, ".git/agent-lens/reads.jsonl"), "utf8");
  for (const body of ["local first", "INSERTED", "REPLACEMENT", "PATCHED", "AGENT DRAFT", "WIRE DRAFT"]) {
    assert(!metadata.includes(body), `draft contents stay out of metadata log: ${body}`);
  }
  emit("session_shutdown", {});
  await query("stop");
  assert.equal(await exited, 0, stderr);
  assert(!existsSync(join(previewDirectory(root), `${editor.pid}.sock`)), "shutdown removes socket");
  console.log("Live preview bridge and Neovim lifecycle OK");
} finally {
  emit("session_shutdown", {});
  editor.kill();
  await exited;
  rmSync(socketDirectory, { recursive: true, force: true });
  rmSync(root, { recursive: true, force: true });
  rmSync(outside, { recursive: true, force: true });
}
