import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const packageRoot = resolve(fileURLToPath(new URL("..", import.meta.url)));
const manifest = JSON.parse(readFileSync(resolve(packageRoot, "package.json"), "utf8"));

assert.equal(manifest.name, "agent-lens.nvim");
assert.equal(manifest.version, "0.1.0");
assert.equal(manifest.type, "module");
assert.equal(manifest.license, "MIT");
assert.equal(manifest.repository?.type, "git");
assert.equal(
  manifest.repository?.url,
  "git+https://github.com/fulstaph/agent-lens.nvim.git",
);
assert.equal(manifest.homepage, "https://github.com/fulstaph/agent-lens.nvim#readme");
assert.ok(Array.isArray(manifest.keywords), "keywords are an array");
for (const keyword of ["pi-package", "omp-extension", "neovim", "agent-lens"]) {
  assert(manifest.keywords.includes(keyword), `keyword included: ${keyword}`);
}

for (const host of ["omp", "pi"]) {
  assert.deepEqual(manifest[host]?.extensions, ["./extensions/pi-read-events.js"]);
}
assert.deepEqual(manifest.omp.extensions, manifest.pi.extensions);

for (const entry of manifest.omp.extensions) {
  const extensionPath = resolve(packageRoot, entry);
  assert(extensionPath.startsWith(`${packageRoot}/`), `extension stays in package: ${entry}`);
  assert(existsSync(extensionPath), `extension exists: ${entry}`);
  const loaded = await import(pathToFileURL(extensionPath).href);
  assert.equal(typeof loaded.default, "function", `callable extension: ${entry}`);
}

for (const file of ["extensions/pi-read-events.js", "README.md", "LICENSE"]) {
  assert(manifest.files?.includes(file), `publish allowlist includes ${file}`);
}
assert.deepEqual(manifest.dependencies ?? {}, {});
assert.deepEqual(manifest.optionalDependencies ?? {}, {});
assert.deepEqual(manifest.peerDependencies ?? {}, {});
assert.deepEqual(manifest.bundledDependencies ?? [], []);
assert.deepEqual(manifest.bundleDependencies ?? [], []);
const packReport = JSON.parse(
  execFileSync("npm", ["pack", "--dry-run", "--json"], {
    cwd: packageRoot,
    encoding: "utf8",
  }),
);
const packedFiles = packReport
  .flatMap((entry) => entry.files ?? [])
  .map((file) => file.path)
  .sort();
assert.deepEqual(
  packedFiles,
  ["LICENSE", "README.md", "extensions/pi-read-events.js", "package.json"],
  "package tarball contains only the distributable allowlist",
);


console.log("Package manifest OK");
