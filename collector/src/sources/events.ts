import { Tailer } from "../tail.ts";
import { startOfLocalDay, type Poll, type Source, type UsagePoll } from "../stats.ts";

// Push channel: the pi extension (adapters/pi/toks-reporter.ts) appends one JSON line per response.
export function createEventsSource(poll: Poll, usage: UsagePoll): Source {
  const tailer = new Tailer(
    "~/.local/share/toks/events/*.jsonl",
    undefined,
    startOfLocalDay(Date.now()),
  );
  return {
    name: "events",
    async tick() {
      for (const chunk of await tailer.tick()) {
        for (const line of chunk.lines) {
          try {
            const d = JSON.parse(line);
            if (typeof d?.ts !== "number") continue;
            // New lines carry a full usage object; old ones only outputTokens.
            const u = d.usage;
            const output = u?.output ?? d.outputTokens ?? 0;
            const input = u?.input ?? 0;
            const cacheRead = u?.cacheRead ?? 0;
            const cc = u?.cacheWrite ?? 0;
            if (input > 0 || output > 0 || cacheRead > 0 || cc > 0) {
              usage(d.agent ?? "pi", {
                at: d.ts,
                id: null,
                input,
                output,
                cacheRead,
                cacheCreation: cc,
              });
            }
            const decodeMs = d.decodeMs;
            poll(d.agent ?? "pi", {
              ttftMs: d.ttftMs ?? null,
              tokPerSec:
                decodeMs > 0 && d.outputTokens > 0 ? d.outputTokens / (decodeMs / 1000) : null,
              outputTokens: d.outputTokens ?? null,
              approx: false,
              at: d.ts,
              model: d.model ?? null,
            });
          } catch {
            // Bad line: skip.
          }
        }
      }
    },
  };
}
