// 精确会话体检（只读）：只按 DSH v2→v3 迁移器实际校验的位置检查 source.kind
//   校验位置（见 dsh-session-format-v2-to-v3/lib/index.js 的 assertSource 调用点）:
//     user/message              -> data.source
//     assistant/message         -> data.message.source
//     tool/result               -> data.message.source
//     agent/inbox/spliced       -> data.inserted[].source
//     session/title-llm-request -> data.messages[].source
//   session/title 等仅日志事件上的 source 不参与校验（因此 fallback/provider 无害）。
// 用法: node scan-sessions.mjs <dshHome> [--detail]
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { zstdDecompressSync } from 'node:zlib'

const KNOWN = new Set([
  'user', 'plugin', 'model', 'tool', 'agent-instructions', 'session-reference',
  'team-message', 'goal', 'skill-invocation', 'skill-catalog', 'coordinator',
  'subagent-report', 'subagent-settled', 'webhook', 'agent-message',
])
const MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd])

function decodeAll(buf) {
  const offsets = []
  let i = 0
  while ((i = buf.indexOf(MAGIC, i)) !== -1) { offsets.push(i); i += 4 }
  const parts = []
  for (let k = 0; k < offsets.length; k++) {
    const s = offsets[k]
    const e = k + 1 < offsets.length ? offsets[k + 1] : buf.length
    try { parts.push(zstdDecompressSync(buf.subarray(s, e))) } catch { /* torn tail */ }
  }
  return parts.length ? Buffer.concat(parts).toString('utf8') : ''
}

function checkedSources(ev) {
  const d = ev.data ?? {}
  const out = []
  if (ev.type === 'user/message') { if (d.source) out.push(d.source) }
  else if (ev.type === 'assistant/message' || ev.type === 'tool/result') { if (d.message && d.message.source) out.push(d.message.source) }
  else if (ev.type === 'agent/inbox/spliced') { for (const m of d.inserted ?? []) if (m && m.source) out.push(m.source) }
  else if (ev.type === 'session/title-llm-request') { for (const m of d.messages ?? []) if (m && m.source) out.push(m.source) }
  return out
}

const home = process.argv[2]
const detail = process.argv.includes('--detail')
const sessionsRoot = join(home, 'sessions')
const dirs = []
try {
  for (const ws of readdirSync(sessionsRoot)) {
    const wsPath = join(sessionsRoot, ws)
    if (!statSync(wsPath).isDirectory()) continue
    for (const s of readdirSync(wsPath)) {
      const p = join(wsPath, s)
      if (statSync(p).isDirectory()) dirs.push({ ws, id: s, dir: p })
    }
  }
} catch { process.stdout.write('no sessions dir: ' + sessionsRoot + '\n'); process.exit(0) }

const rows = []
for (const d of dirs) {
  let artifact = join(d.dir, 'session.jsonl.zstd')
  try { if (!statSync(artifact).isFile()) artifact = join(d.dir, 'session.jsonl') } catch { continue }
  let text = ''
  try {
    const buf = readFileSync(artifact)
    text = artifact.endsWith('.zstd') ? decodeAll(buf) : buf.toString('utf8')
  } catch { continue }
  const problems = []
  let events = 0
  for (const line of text.split('\n')) {
    if (!line.trim()) continue
    let ev
    try { ev = JSON.parse(line) } catch { continue }
    events++
    for (const src of checkedSources(ev)) {
      if (typeof src.kind !== 'string' || !KNOWN.has(src.kind)) {
        problems.push({
          evType: ev.type,
          kind: src.kind,
          source: src,
          id: (ev.data && (ev.data.id ?? (ev.data.message && ev.data.message.id))) ?? null,
          preview: JSON.stringify(ev.data).slice(0, 300),
        })
      }
    }
  }
  rows.push({ ws: d.ws, id: d.id, artifact, events, problems })
}

const bad = rows.filter((r) => r.problems.length > 0)
process.stdout.write(JSON.stringify({
  home,
  sessions: rows.length,
  unloadable: bad.length,
  bad: bad.map((r) => ({ id: r.id, ws: r.ws, events: r.events, problems: r.problems.length, kinds: [...new Set(r.problems.map((p) => p.kind))] })),
  detail: detail ? bad.map((r) => ({ id: r.id, artifact: r.artifact, problems: r.problems })) : undefined,
}, null, 1) + '\n')
