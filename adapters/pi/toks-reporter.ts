/**
 * toks reporter — appends one JSON line per assistant response to
 * ~/.local/share/toks/events/pi.jsonl for the toks collector's events source.
 *
 * TTFT anchors on before_provider_request (the last thing pi does before the wire);
 * decode spans first delta to message_end. Below MIN_DECODE_MS or without a first
 * token, ttftMs/decodeMs are written as null — a burst arrival has no decode phase.
 */

import { appendFile, mkdir } from 'node:fs/promises'
import { homedir } from 'node:os'
import { join } from 'node:path'

import type { ExtensionAPI } from '@earendil-works/pi-coding-agent'

const EVENTS_DIR = join(homedir(), '.local', 'share', 'toks', 'events')
const EVENTS_FILE = join(EVENTS_DIR, 'pi.jsonl')
const MIN_DECODE_MS = 200

export default function (pi: ExtensionAPI) {
  let requestAt: number | null = null
  let firstTokenAt: number | null = null

  const clear = () => {
    requestAt = null
    firstTokenAt = null
  }

  pi.on('turn_start', clear)
  pi.on('turn_end', clear)
  pi.on('agent_end', clear)
  pi.on('agent_settled', clear)

  pi.on('before_provider_request', () => {
    requestAt = Date.now()
    firstTokenAt = null
  })

  pi.on('message_update', async (event) => {
    const delta = event.assistantMessageEvent
    if (
      delta.type !== 'text_delta' &&
      delta.type !== 'thinking_delta' &&
      delta.type !== 'toolcall_delta'
    ) {
      return
    }
    if (firstTokenAt === null) firstTokenAt = Date.now()
  })

  pi.on('message_end', async (event) => {
    if (event.message.role !== 'assistant') return
    const message = event.message as {
      model?: unknown
      usage?: { input?: number; output?: number; cacheRead?: number; cacheWrite?: number }
    }
    const now = Date.now()
    const decodeMs = firstTokenAt !== null ? now - firstTokenAt : null
    const timed = decodeMs !== null && decodeMs >= MIN_DECODE_MS
    const line =
      JSON.stringify({
        agent: 'pi',
        ts: now,
        model: typeof message.model === 'string' ? message.model : null,
        ttftMs: timed && requestAt !== null ? firstTokenAt! - requestAt : null,
        decodeMs: timed ? decodeMs : null,
        outputTokens: message.usage?.output ?? 0,
        usage: message.usage ?? null,
      }) + '\n'
    clear()
    await mkdir(EVENTS_DIR, { recursive: true }).catch(() => {})
    await appendFile(EVENTS_FILE, line).catch(() => {})
  })
}
