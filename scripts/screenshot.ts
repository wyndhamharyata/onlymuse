import { launch } from "@gpuix/react/automation";

// Opens the app behind the other windows and saves a picture of it.
const outputPath = process.argv[2] ?? "screenshot.png";
const settleMs = Number(process.argv[3] ?? 6000);

const app = await launch({
  command: "bun",
  args: ["src/main.tsx"],
  env: { GPUIX_BACKGROUND: "1" },
});

await new Promise((resolve) => setTimeout(resolve, settleMs));
await app.screenshot({ path: outputPath });
await app.close();
console.log(`Saved ${outputPath}`);
