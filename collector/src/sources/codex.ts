import { Tailer } from "../tail.ts";
import { startOfLocalDay, type Poll, type Source, type UsagePoll } from "../stats.ts";

interface FileState {
  turnOutput: number | null; // latest turn_token_usage.output_tokens (cumulative per turn)
  acc: number; // fallback accumulator from payload.usage.output_tokens
}

export function createCodexSource(poll: Poll, usage: UsagePoll): Source {
  const tailer = new Tailer(
    "~/.codex/sessions/*/*/*/rollout-*.jsonl",
    undefined,
    startOfLocalDay(Date.now()),
  );
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
            // payload.usage is the per-request delta; input_tokens includes
            // the cached part. Subtracting both cache fields keeps the total
            // equal to the provider's total_tokens regardless of whether
            // cache_write is folded into input.
            const u = p?.usage;
            const ts = typeof d.timestamp === "string" ? Date.parse(d.timestamp) : NaN;
            if (u && Number.isFinite(ts)) {
              const cacheRead = u.cached_input_tokens ?? 0;
              const cc = u.cache_write_input_tokens ?? 0;
              const input = Math.max(0, (u.input_tokens ?? 0) - cacheRead - cc);
              const output = u.output_tokens ?? 0;
              if (input > 0 || output > 0 || cacheRead > 0 || cc > 0) {
                usage("codex", {
                  at: ts,
                  id: p.response_id ?? null,
                  input,
                  output,
                  cacheRead,
                  cacheCreation: cc,
                });
              }
            }
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
