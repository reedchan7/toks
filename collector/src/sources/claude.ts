import { Tailer } from "../tail.ts";
import type { Poll, Sample, Source } from "../stats.ts";

interface Pending {
  requestId: string;
  anchorTs: number | null; // timestamp of the last "user" record before this request
  firstTs: number; // timestamp of apiBlockIndex 0 (= when block 0 finished)
  lastTs: number; // timestamp of the last block record
  output: number;
  thinkMs: number; // thinkingDurationMs of block 0 (0 when absent)
  blocks: number;
  model: string | null;
}

interface FileState {
  pending: Pending | null;
  prevTs: number | null;
  lastDataAt: number;
}

const IDLE_FINALIZE_MS = 60_000;
const MIN_DECODE_MS = 200;
// Anthropic decode throughput never approaches this; higher values mean the
// reconstructed decode window is bogus.
const MAX_PLAUSIBLE_TOK_PER_SEC = 250;
// Anchors older than this are queue/idle time, not request latency.
const MAX_PLAUSIBLE_TTFT_MS = 30_000;

// Block timestamps mark block *completion*, and thinkingDurationMs says how
// long the thinking block generated. So for thinking requests:
//   first token  ≈ firstTs − thinkMs
//   TTFT         = first token − dispatch (anchor)
//   decode       = lastTs − first token   (thinking + text generation)
// Without thinking, block 0's generation time is unknown, so the whole
// anchor→block-0 gap is the only window (TTFT and decode stay mixed, hence
// approx on every Claude sample).
function finalize(p: Pending): Sample | null {
  if (p.anchorTs == null) return null;
  const firstTokenTs = p.firstTs - p.thinkMs;
  const ttftMs = firstTokenTs - p.anchorTs;
  if (ttftMs < 0 || ttftMs > MAX_PLAUSIBLE_TTFT_MS) return null;
  const decodeMs =
    p.lastTs > firstTokenTs ? p.lastTs - firstTokenTs : p.firstTs - p.anchorTs;
  let tokPerSec: number | null =
    decodeMs >= MIN_DECODE_MS ? p.output / (decodeMs / 1000) : null;
  if (tokPerSec != null && tokPerSec > MAX_PLAUSIBLE_TOK_PER_SEC) tokPerSec = null;
  // Single-block, no-thinking requests have no decode window at all: the gap
  // mixes queue, TTFT and generation, so the rate is meaningless.
  if (p.thinkMs === 0 && p.blocks === 1) tokPerSec = null;
  return { ttftMs, tokPerSec, outputTokens: p.output, approx: true, at: p.lastTs, model: p.model };
}

export function createClaudeSource(poll: Poll): Source {
  const tailer = new Tailer("~/.claude/projects/*/**/*.jsonl");
  const files = new Map<string, FileState>();
  return {
    name: "claude",
    async tick() {
      const now = Date.now();
      for (const chunk of await tailer.tick()) {
        let st = files.get(chunk.path);
        if (!st) files.set(chunk.path, (st = { pending: null, prevTs: null, lastDataAt: now }));
        st.lastDataAt = now;
        for (const line of chunk.lines) {
          let d: any;
          try {
            d = JSON.parse(line);
          } catch {
            continue;
          }
          const ts = typeof d?.timestamp === "string" ? Date.parse(d.timestamp) : NaN;
          // Sidechain (subagent) records interleave with main-thread work and
          // poison both block gaps and anchors; skip them entirely.
          if (d?.isSidechain === true) continue;
          const output = d?.message?.usage?.output_tokens;
          if (d?.type === "assistant" && d.requestId && output != null && Number.isFinite(ts)) {
            if (st.pending && st.pending.requestId !== d.requestId) {
              const s = finalize(st.pending);
              if (s) poll("claude", s);
              st.pending = null;
            }
            if (!st.pending) {
              st.pending = {
                requestId: d.requestId,
                anchorTs: st.prevTs,
                firstTs: ts,
                lastTs: ts,
                output,
                thinkMs: typeof d.thinkingDurationMs === "number" ? d.thinkingDurationMs : 0,
                blocks: 1,
                model: d.message?.model ?? null,
              };
            } else {
              st.pending.lastTs = ts;
              st.pending.blocks++;
            }
          }
          // Only "user" records (prompts, tool results) precede a request
          // dispatch; attachment/progress records can land mid-stream and
          // would make the anchor too late.
          if (Number.isFinite(ts) && d?.type === "user") st.prevTs = ts;
        }
      }
      // Finalize requests whose file has gone quiet.
      for (const [path, st] of files) {
        if (st.pending && now - st.lastDataAt > IDLE_FINALIZE_MS) {
          const s = finalize(st.pending);
          if (s) poll("claude", s);
          st.pending = null;
        }
        if (!st.pending && now - st.lastDataAt > IDLE_FINALIZE_MS * 60) files.delete(path);
      }
    },
  };
}
