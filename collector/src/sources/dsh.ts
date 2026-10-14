import { Tailer, type Reader } from "../tail.ts";
import type { Poll, Source } from "../stats.ts";

const MIN_DECODE_MS = 50;

// Offsets are indices into the deterministic decompressed text, reusable across rounds.
const zstdReader: Reader = async (path, offset) => {
  const proc = Bun.spawn(["zstd", "-dc", path], { stdout: "pipe", stderr: "ignore" });
  const text = await new Response(proc.stdout).text();
  await proc.exited;
  if (offset > text.length) offset = 0;
  const sub = text.slice(offset);
  const nl = sub.lastIndexOf("\n");
  if (nl < 0) return { text: "", next: offset };
  return { text: sub.slice(0, nl + 1), next: offset + nl + 1 };
};

export function createDshSource(poll: Poll): Source {
  const tailer = new Tailer("~/.dsh/sessions/*/*/session.v4.jsonl.zstd", zstdReader);
  // Latest request dispatch time per file, from step/start and request/header
  // records; stream[0] (block-start) is too late to anchor TTFT.
  const dispatch = new Map<string, number>();
  return {
    name: "dsh",
    async tick() {
      for (const chunk of await tailer.tick()) {
        for (const line of chunk.lines) {
          try {
            const d = JSON.parse(line);
            if (d?.type === "step/start" || d?.type === "request/header") {
              if (typeof d?.time === "number") dispatch.set(chunk.path, d.time);
              continue;
            }
            if (d?.type !== "assistant/message") continue;
            const data = d.data;
            const output = data?.usage?.outputTokens;
            const stream: any[] = data?.stream;
            if (output == null || !Array.isArray(stream) || stream.length === 0) continue;
            // firstToken = earliest chunk batch start across ALL block types
            // (reasoning AND text). Taking text-chunks.time0 alone skips the
            // reasoning phase and inflates tok/s roughly twofold.
            const chunkStarts = stream
              .map((e) => (typeof e?.time0 === "number" ? e.time0 : null))
              .filter((t): t is number => t != null);
            const timed = stream.filter((e) => typeof e?.time === "number");
            if (chunkStarts.length === 0 && timed.length === 0) continue;
            const firstToken =
              chunkStarts.length > 0 ? Math.min(...chunkStarts) : timed[0].time;
            const end = timed[timed.length - 1].time;
            const decodeMs = end - firstToken;
            if (decodeMs < MIN_DECODE_MS) continue;
            const sent = dispatch.get(chunk.path);
            const ttftMs = sent != null && firstToken >= sent ? firstToken - sent : null;
            poll("dsh", {
              ttftMs,
              tokPerSec: output / (decodeMs / 1000),
              outputTokens: output,
              approx: false,
              at: d.time ?? end,
              model: data.model ?? null,
            });
          } catch {
            // Bad line: skip.
          }
        }
      }
    },
  };
}
