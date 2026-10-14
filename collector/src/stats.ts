import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";

export interface Sample {
  ttftMs: number | null;
  tokPerSec: number | null;
  outputTokens: number | null;
  approx: boolean;
  at: number; // ms epoch
  model?: string | null;
}

export type Poll = (agent: string, s: Sample) => void;

export interface Source {
  name: string;
  tick(): Promise<void>;
}

export const AGENTS: Record<string, string> = {
  kimi: "Kimi Code",
  claude: "Claude Code",
  codex: "Codex",
  dsh: "DSH",
  zcode: "Z Code",
  pi: "Pi",
};

const WINDOW = 200;
const STATE_DEBOUNCE_MS = 5000;

async function writeAtomic(path: string, data: string): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  const tmp = `${path}.tmp`;
  await writeFile(tmp, data);
  await rename(tmp, path);
}

function mean(nums: number[]): number | null {
  if (nums.length === 0) return null;
  return Math.round((nums.reduce((a, b) => a + b, 0) / nums.length) * 10) / 10;
}

export class Stats {
  private windows = new Map<string, Sample[]>();
  private statsPath: string;
  private statePath: string;
  private dirty = false;
  private lastStateWrite = 0;

  constructor(dir: string) {
    this.statsPath = join(dir, "stats.json");
    this.statePath = join(dir, "state.json");
  }

  async load(): Promise<void> {
    try {
      const state = JSON.parse(await readFile(this.statePath, "utf8"));
      for (const [agent, samples] of Object.entries(state.agents ?? {})) {
        if (Array.isArray(samples)) {
          const w = samples.slice(-WINDOW) as Sample[];
          w.sort((a, b) => a.at - b.at); // state written before sorted-insert may be unsorted
          this.windows.set(agent, w);
        }
      }
    } catch {
      // No or corrupt state file: start empty.
    }
  }

  add(agent: string, sample: Sample): void {
    let w = this.windows.get(agent);
    if (!w) this.windows.set(agent, (w = []));
    // Samples can arrive out of order: sources tail several session files
    // concurrently and finalize idle requests late. Keep the window sorted by
    // time so last/avg/recent reflect chronology.
    let i = w.length;
    while (i > 0 && w[i - 1].at > sample.at) i--;
    w.splice(i, 0, sample);
    if (w.length > WINDOW) w.splice(0, w.length - WINDOW);
    this.dirty = true;
  }

  build(): unknown {
    const now = Date.now();
    const agents: Record<string, unknown> = {};
    for (const [key, label] of Object.entries(AGENTS)) {
      const w = this.windows.get(key) ?? [];
      const last = w.length > 0 ? w[w.length - 1] : null;
      const age = last ? now - last.at : Infinity;
      agents[key] = {
        label,
        state: age <= 90_000 ? "active" : age <= 15 * 60_000 ? "recent" : "stale",
        model: last?.model ?? null,
        last: last
          ? {
              ttftMs: last.ttftMs,
              tokPerSec: last.tokPerSec,
              outputTokens: last.outputTokens,
              at: last.at,
              approx: last.approx,
            }
          : null,
        avg:
          w.length > 0
            ? {
                ttftMs: mean(w.flatMap((s) => (s.ttftMs != null ? [s.ttftMs] : []))),
                tokPerSec: mean(w.flatMap((s) => (s.tokPerSec != null ? [s.tokPerSec] : []))),
                samples: w.length,
              }
            : null,
        recent: w
          .slice(-30)
          .map((s) => ({ at: s.at, ttftMs: s.ttftMs, tokPerSec: s.tokPerSec })),
      };
    }
    return { version: 1, updatedAt: now, agents };
  }

  /** Writes stats.json every round; state.json at most every 5s when changed. */
  async flush(): Promise<void> {
    await writeAtomic(this.statsPath, JSON.stringify(this.build()) + "\n");
    const now = Date.now();
    if (this.dirty && now - this.lastStateWrite >= STATE_DEBOUNCE_MS) {
      await this.writeState();
    }
  }

  async writeState(): Promise<void> {
    const agents: Record<string, Sample[]> = {};
    for (const [k, v] of this.windows) agents[k] = v;
    await writeAtomic(this.statePath, JSON.stringify({ version: 1, agents }) + "\n");
    this.dirty = false;
    this.lastStateWrite = Date.now();
  }
}
