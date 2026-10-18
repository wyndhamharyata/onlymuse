import { copyFileSync, existsSync, readFileSync, renameSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// bun scripts/gpuix-native.ts [stock|patched] installs gpuix's binary, patched by default. NOTES.md, Frame times, says why.
const sources: Record<string, string> = {
  patched: join("vendor", "gpuix-native.darwin-arm64.node"),
  stock: join(homedir(), "Library", "Caches", "onlymuse", "gpuix", "stock.node"),
};
const installedPath = join(
  "node_modules",
  "@gpuix",
  "native-darwin-arm64",
  "gpuix-native.darwin-arm64.node"
);
const choice = process.argv[2] ?? "patched";
const sourcePath = sources[choice];
const hashOf = (path: string): string => Bun.hash(readFileSync(path)).toString(16);

if (!sourcePath || !existsSync(sourcePath)) {
  console.error(`No ${choice} binary at ${sourcePath}`);
  process.exit(1);
}

// The published binary is saved before it is replaced, so stock can come back without a reinstall.
if (
  existsSync(installedPath) &&
  hashOf(installedPath) !== hashOf(sources.patched) &&
  !existsSync(sources.stock)
) {
  copyFileSync(installedPath, sources.stock);
}

if (existsSync(installedPath) && hashOf(installedPath) === hashOf(sourcePath)) {
  console.log(`gpuix: ${choice} already in use`);
  process.exit(0);
}

// A rename gives the file a new inode, so an app that has the old binary loaded keeps running.
copyFileSync(sourcePath, `${installedPath}.next`);
renameSync(`${installedPath}.next`, installedPath);
console.log(`gpuix: ${choice} in use. Restart the app to load it.`);
