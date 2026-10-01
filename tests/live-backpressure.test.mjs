// A slow editor skips intermediate snapshots instead of losing its connection,
// because Neovim treats an unexpected close as cancellation of the tool call,
// and still receives the final snapshot after the call has finished.
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, realpathSync, rmSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createLivePreview, previewDirectory } from "../extensions/live-preview.js";

const root = realpathSync(mkdtempSync(join(tmpdir(), "agent-lens-backpressure-")));
const directory = previewDirectory(root);
mkdirSync(directory, { recursive: true, mode: 0o700 });
const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

let peer;
let closed = false;
let received = "";
const server = createServer((socket) => {
  peer = socket;
  socket.pause(); // Simulate an editor whose main loop is busy.
  socket.on("data", (chunk) => { received += chunk; });
  socket.on("close", () => { closed = true; });
});
await new Promise((resolve) => server.listen(join(directory, `${process.pid}.sock`), resolve));

const live = createLivePreview((_repo, _cwd, path) => ({ file: join(root, path), path }));
const repo = { root };
const snapshot = (marker) => Array.from({ length: 1000 }, (_, i) => `${marker} ${i} ${"x".repeat(700)}`).join("\n");
try {
  for (let frame = 1; frame <= 8; frame++) {
    live.update(repo, root, {
      toolCallId: "call",
      toolName: "write",
      input: { path: "big.txt", content: snapshot(`frame-${frame}`) },
      isFinal: false,
    });
    await pause(40);
  }
  assert.ok(peer, "receiver connected");
  // The final snapshot is produced while the receiver still lags.
  live.update(repo, root, {
    toolCallId: "call",
    toolName: "write",
    input: { path: "big.txt", content: snapshot("final") },
    isFinal: true,
  });
  live.finish("call");

  // A paused socket only observes the sender closing once it reads again.
  peer.resume();
  let last;
  for (let attempt = 0; attempt < 200 && !closed; attempt++) {
    const complete = received.slice(0, received.lastIndexOf("\n") + 1);
    const records = complete.split("\n").filter(Boolean);
    last = records.length ? JSON.parse(records.at(-1)) : undefined;
    if (last?.lines?.[0]?.startsWith("final ")) break;
    await pause(20);
  }
  assert.equal(closed, false, "a lagging receiver keeps its connection");
  assert.ok(last?.lines?.[0]?.startsWith("final "), "final snapshot arrives after catching up");
  console.log("Live preview backpressure OK");
} finally {
  live.stop();
  server.close();
  rmSync(directory, { recursive: true, force: true });
  rmSync(root, { recursive: true, force: true });
}
