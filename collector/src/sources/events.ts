import { Tailer } from "../tail.ts";
import type { Poll, Source } from "../stats.ts";

// Push channel: the pi extension (adapters/pi/toks-reporter.ts) appends one JSON line per response.
export function createEventsSource(poll: Poll): Source {
  const tailer = new Tailer("~/.local/share/toks/events/*.jsonl");
  return {
    name: "events",
    async tick() {
      for (const chunk of await tailer.tick()) {
        for (const line of chunk.lines) {
          try {
            const d = JSON.parse(line);
            if (typeof d?.ts !== "number") continue;
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
