import { Tailer } from "../tail.ts";
import { startOfLocalDay, type Poll, type Source, type UsagePoll } from "../stats.ts";

export function createKimiSource(poll: Poll, usage: UsagePoll): Source {
  const tailer = new Tailer(
    "~/.kimi-code/sessions/*/*/agents/*/wire.jsonl",
    undefined,
    startOfLocalDay(Date.now()),
  );
  return {
    name: "kimi",
    async tick() {
      for (const chunk of await tailer.tick()) {
        for (const line of chunk.lines) {
          try {
            const d = JSON.parse(line);
            const ev = d?.event;
            if (ev?.type !== "step.end") continue;
            // Usage before speed filters; records without a timestamp are
            // unusable for day bucketing, so skip them there too.
            const u = ev.usage;
            if (u && typeof d.time === "number") {
              const input = u.inputOther ?? 0;
              const output = u.output ?? 0;
              const cacheRead = u.inputCacheRead ?? 0;
              const cc = u.inputCacheCreation ?? 0;
              if (input > 0 || output > 0 || cacheRead > 0 || cc > 0) {
                usage("kimi", {
                  at: d.time,
                  id: ev.uuid ?? null,
                  input,
                  output,
                  cacheRead,
                  cacheCreation: cc,
                });
              }
            }
            const dur = ev.llmStreamDurationMs;
            const output = ev.usage?.output;
            if (!(dur >= 50) || !(output > 0)) continue;
            poll("kimi", {
              ttftMs: ev.llmFirstTokenLatencyMs ?? null,
              tokPerSec: output / (dur / 1000),
              outputTokens: output,
              approx: false,
              at: d.time ?? Date.now(),
              model: ev.model ?? null,
            });
          } catch {
            // Bad line: skip.
          }
        }
      }
    },
  };
}
