import { Glob } from "bun";
import { open, stat } from "node:fs/promises";
import { homedir } from "node:os";

/** Files older than this are never opened; TOKS_ACTIVE_MS overrides for parser verification. */
export const ACTIVE_MS = Number(process.env.TOKS_ACTIVE_MS) || 30 * 60 * 1000;
const PRUNE_MS = 60 * 60 * 1000;

export interface Chunk {
  path: string;
  lines: string[];
}

/** Returns the new complete lines of path after offset, and the offset to resume from. */
export type Reader = (path: string, offset: number) => Promise<{ text: string; next: number }>;

export const fileReader: Reader = async (path, offset) => {
  const fh = await open(path, "r");
  try {
    const { size } = await fh.stat();
    if (size < offset) offset = 0; // truncated/rotated
    if (size === offset) return { text: "", next: offset };
    const buf = Buffer.alloc(size - offset);
    await fh.read(buf, 0, buf.length, offset);
    const nl = buf.lastIndexOf(0x0a);
    if (nl < 0) return { text: "", next: offset }; // hold back a partial trailing line
    return { text: buf.subarray(0, nl + 1).toString("utf8"), next: offset + nl + 1 };
  } finally {
    await fh.close();
  }
};

/** Globs candidates, filters by mtime, and tails each file incrementally from a remembered offset. */
export class Tailer {
  private entries = new Map<string, { offset: number; mtimeMs: number; changedAt: number }>();

  constructor(
    private pattern: string, // ~-prefixed glob
    private read: Reader = fileReader,
  ) {}

  async tick(): Promise<Chunk[]> {
    const now = Date.now();
    const out: Chunk[] = [];
    let paths: string[] = [];
    try {
      paths = await Array.fromAsync(
        new Glob(this.pattern.slice(2)).scan({ cwd: homedir(), absolute: true }),
      );
    } catch {
      return out;
    }
    for (const path of paths) {
      try {
        const st = await stat(path);
        if (now - st.mtimeMs > ACTIVE_MS) continue;
        let e = this.entries.get(path);
        if (!e) {
          e = { offset: 0, mtimeMs: 0, changedAt: now };
          this.entries.set(path, e);
        }
        if (st.mtimeMs === e.mtimeMs) continue;
        const { text, next } = await this.read(path, e.offset);
        e.offset = next;
        e.mtimeMs = st.mtimeMs;
        e.changedAt = now;
        if (text) out.push({ path, lines: text.split("\n").filter(Boolean) });
      } catch {
        // Unreadable file: skip it this round.
      }
    }
    for (const [p, e] of this.entries) {
      if (now - e.changedAt > PRUNE_MS) this.entries.delete(p);
    }
    return out;
  }
}
