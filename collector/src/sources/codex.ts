import { Tailer } from "../tail.ts";
import type { Poll, Source } from "../stats.ts";

interface FileState {
  turnOutput: number | null; // latest turn_token_usage.output_tokens (cumulative per turn)
  acc: number; // fallback accumulator from payload.usage.output_tokens
}

export function createCodexSource(poll: Poll): Source {
  const tailer = new Tailer("~/.codex/sessions/*/*/*/rollout-*.jsonl");
  const files = new Map<string, FileState>();
  return {
    name: "codex",
    async tick() {
      for (const chunk of await tailer.tick()) {
        let st = files.get(chunk.path);
        if (!st) files.set(chunk.path, (st = { turnOutput: null, acc: 0 }));
        for (const line of chunk.lines) {
          let d: any;
          try {
            d = JSON.parse(line);
          } catch {
            continue;
          }
          const p = d?.payload;
          if (d?.type === "token_usage_record") {
            const turn = p?.turn_token_usage?.output_tokens;
            if (turn != null) st.turnOutput = turn;
            else if (p?.usage?.output_tokens != null) st.acc += p.usage.output_tokens;
          } else if (d?.type === "event_msg" && p?.type === "task_complete") {
            const ttft = p.time_to_first_token_ms;
            if (ttft == null) continue;
            const decodeMs = p.duration_ms - ttft;
            if (decodeMs <= 0) continue;
            const output = st.turnOutput ?? st.acc;
            st.turnOutput = null;
            st.acc = 0;
            poll("codex", {
              ttftMs: ttft,
              tokPerSec: output / (decodeMs / 1000),
              outputTokens: output,
              approx: true, // includes tool time, reads low
              at: typeof d.timestamp === "string" ? Date.parse(d.timestamp) : Date.now(),
              model: p.model ?? null,
            });
          }
        }
      }
    },
  };
}
