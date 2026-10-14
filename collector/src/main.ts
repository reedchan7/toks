import { homedir } from "node:os";
import { join } from "node:path";
import { Stats, type Sample, type Usage } from "./stats.ts";
import { createKimiSource } from "./sources/kimi.ts";
import { createClaudeSource } from "./sources/claude.ts";
import { createCodexSource } from "./sources/codex.ts";
import { createDshSource } from "./sources/dsh.ts";
import { createZcodeSource } from "./sources/zcode.ts";
import { createEventsSource } from "./sources/events.ts";

const TICK_MS = 1500;
const DIR = process.env.TOKS_DIR || join(homedir(), ".local/share/toks");

const log = (msg: string) => console.log(`${new Date().toISOString()} ${msg}`);

const stats = new Stats(DIR);
await stats.load();

const poll = (agent: string, s: Sample) => {
  stats.add(agent, s);
  log(`sample ${agent} ttft=${s.ttftMs ?? "-"} tps=${s.tokPerSec?.toFixed(1) ?? "-"} out=${s.outputTokens ?? "-"}${s.approx ? " approx" : ""}`);
};

const usagePoll = (agent: string, u: Usage) => stats.addUsage(agent, u);

const sources = [
  createKimiSource(poll, usagePoll),
  createClaudeSource(poll, usagePoll),
  createCodexSource(poll, usagePoll),
  createDshSource(poll, usagePoll),
  createZcodeSource(poll, usagePoll),
  createEventsSource(poll, usagePoll),
];

const shutdown = async () => {
  await stats.writeState().catch(() => {});
  process.exit(0);
};
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);

log(`toks collector started, dir=${DIR}`);
while (true) {
  const results = await Promise.allSettled(sources.map((s) => s.tick()));
  for (const r of results) {
    if (r.status === "rejected") log(`tick error: ${r.reason}`);
  }
  await stats.flush().catch((e) => log(`flush error: ${e}`));
  await Bun.sleep(TICK_MS);
}
