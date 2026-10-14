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

/** One request's token usage, normalized per source so the four fields never overlap. */
export interface Usage {
  at: number; // ms epoch, from the log record (no Date.now() fallback)
  id?: string | null; // dedup key; records without one dedup by content signature
  input: number;
  output: number;
  cacheRead: number;
  cacheCreation: number;
}

export type UsagePoll = (agent: string, u: Usage) => void;

export interface Source {
  name: string;
  tick(): Promise<void>;
}

export function localDayString(ms: number): string {
  const d = new Date(ms);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

export function startOfLocalDay(ms: number): number {
  const d = new Date(ms);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
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
  // Today's usage per agent, deduped by record id (or content signature).
  // Sources emit raw records before any speed filtering; replays re-emit
  // identical or growing records, so entries keep the per-field maximum.
  private usageById = new Map<string, Map<string, Usage>>();
  private usageDay = localDayString(Date.now());
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

  addUsage(agent: string, u: Usage): void {
    const today = localDayString(Date.now());
    if (today !== this.usageDay) {
      this.usageById.clear();
      this.usageDay = today;
    }
    if (localDayString(u.at) !== today) return;
    const key =
      u.id ?? `${u.at}:${u.input}:${u.output}:${u.cacheRead}:${u.cacheCreation}`;
    let m = this.usageById.get(agent);
    if (!m) this.usageById.set(agent, (m = new Map()));
    const prev = m.get(key);
    if (!prev) {
      m.set(key, { ...u });
    } else {
      // Growing snapshots (streaming blocks of one message) re-report with
      // larger numbers; keep the maximum per field.
      prev.input = Math.max(prev.input, u.input);
      prev.output = Math.max(prev.output, u.output);
      prev.cacheRead = Math.max(prev.cacheRead, u.cacheRead);
      prev.cacheCreation = Math.max(prev.cacheCreation, u.cacheCreation);
    }
  }

  private todayTotals(agent: string, today: string) {
    const m = this.usageById.get(agent);
    if (!m || m.size === 0) return null;
    let input = 0,
      output = 0,
      cacheRead = 0,
      cacheCreation = 0;
    for (const u of m.values()) {
      input += u.input;
      output += u.output;
      cacheRead += u.cacheRead;
      cacheCreation += u.cacheCreation;
    }
    return {
      date: today,
      input,
      output,
      cacheRead,
      cacheCreation,
      total: input + output + cacheRead + cacheCreation,
    };
  }

  build(): unknown {
    const now = Date.now();
    // An idle collector crossing midnight must not keep showing yesterday.
    const today = localDayString(now);
    if (today !== this.usageDay) {
      this.usageById.clear();
      this.usageDay = today;
    }
    const agents: Record<string, unknown> = {};
    for (const [key, label] of Object.entries(AGENTS)) {
      const w = this.windows.get(key) ?? [];
      const last = w.length > 0 ? w[w.length - 1] : null;
      const age = last ? now - last.at : Infinity;
      agents[key] = {
        label,
        state: age <= 90_000 ? "active" : age <= 15 * 60_000 ? "recent" : "stale",
        model: last?.model ?? null,
        today: this.todayTotals(key, today),
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
