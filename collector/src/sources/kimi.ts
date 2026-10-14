import { Tailer } from "../tail.ts";
import type { Poll, Source } from "../stats.ts";

export function createKimiSource(poll: Poll): Source {
  const tailer = new Tailer("~/.kimi-code/sessions/*/*/agents/*/wire.jsonl");
  return {
    name: "kimi",
    async tick() {
      for (const chunk of await tailer.tick()) {
        for (const line of chunk.lines) {
          try {
            const d = JSON.parse(line);
            const ev = d?.event;
            if (ev?.type !== "step.end") continue;
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
