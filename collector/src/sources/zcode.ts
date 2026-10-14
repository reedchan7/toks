import { homedir } from "node:os";
import { join } from "node:path";
import { startOfLocalDay, type Poll, type Source, type UsagePoll } from "../stats.ts";

export function createZcodeSource(poll: Poll, usage: UsagePoll): Source {
  const db = join(homedir(), ".zcode/cli/db/db.sqlite");
  // Start at now to avoid replaying history; TOKS_ZCODE_SINCE_MS overrides for verification.
  let lastSeen = Number(process.env.TOKS_ZCODE_SINCE_MS) || Date.now();
  return {
    name: "zcode",
    async tick() {
      // Re-query all of today's completed rows every round: usage dedups by
      // row id, speed samples stay incremental via lastSeen.
      const sql =
        "SELECT id, started_at, time_to_first_token_ms, input_tokens, output_tokens, " +
        "cache_read_input_tokens, cache_creation_input_tokens, first_token_at, completed_at, " +
        "model_id AS model " +
        `FROM model_usage WHERE status='completed' AND started_at >= ${startOfLocalDay(Date.now())} ` +
        "ORDER BY started_at ASC";
      const proc = Bun.spawn(["sqlite3", "-json", `file:${db}?mode=ro`, sql], {
        stdout: "pipe",
        stderr: "pipe",
      });
      const [out, err, code] = await Promise.all([
        new Response(proc.stdout).text(),
        new Response(proc.stderr).text(),
        proc.exited,
      ]);
      if (code !== 0) {
        console.log(`${new Date().toISOString()} zcode: sqlite3 failed: ${err.trim()}`);
        return;
      }
      let rows: any[];
      try {
        rows = JSON.parse(out);
      } catch {
        return;
      }
      for (const r of rows) {
        // input_tokens includes the cached part (OpenAI-style semantics);
        // subtracting both cache fields keeps the total provider-consistent.
        const input = Math.max(
          0,
          (r.input_tokens ?? 0) -
            (r.cache_read_input_tokens ?? 0) -
            (r.cache_creation_input_tokens ?? 0),
        );
        const at = r.completed_at ?? r.started_at;
        if (typeof at === "number") {
          usage("zcode", {
            at,
            id: r.id ?? null,
            input,
            output: r.output_tokens ?? 0,
            cacheRead: r.cache_read_input_tokens ?? 0,
            cacheCreation: r.cache_creation_input_tokens ?? 0,
          });
        }
        if (r.started_at <= lastSeen) continue;
        lastSeen = r.started_at;
        const decodeMs = r.completed_at - r.first_token_at;
        if (!(decodeMs > 0) || !(r.output_tokens > 0)) continue;
        poll("zcode", {
          ttftMs: r.time_to_first_token_ms ?? null,
          tokPerSec: r.output_tokens / (decodeMs / 1000),
          outputTokens: r.output_tokens,
          approx: false,
          at,
          model: r.model ?? null,
        });
      }
    },
  };
}
