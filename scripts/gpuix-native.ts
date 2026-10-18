import { copyFileSync, existsSync, readFileSync, renameSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// bun scripts/gpuix-native.ts stock|patched switches gpuix's binary. With no argument it names the one in use.
const folder = join(homedir(), "Library", "Caches", "onlymuse", "gpuix");
const installedPath = join(
  "node_modules",
  "@gpuix",
  "native-darwin-arm64",
  "gpuix-native.darwin-arm64.node"
);
const choice = process.argv[2];
const hashOf = (path: string): string => Bun.hash(readFileSync(path)).toString(16);
const installedHash = hashOf(installedPath);
const names = ["stock", "patched"].filter((name) => existsSync(join(folder, `${name}.node`)));
const inUse =
  names.find((name) => hashOf(join(folder, `${name}.node`)) === installedHash) ?? "unknown";

if (!choice) {
  console.log(`In use: ${inUse}`);
  process.exit(0);
}

if (!names.includes(choice)) {
  console.error(`No ${choice}.node in ${folder}`);
  process.exit(1);
}

// A rename gives the file a new inode, so an app that has the old binary loaded keeps running.
copyFileSync(join(folder, `${choice}.node`), `${installedPath}.next`);
renameSync(`${installedPath}.next`, installedPath);
console.log(`In use: ${choice}. Restart the app to load it.`);
