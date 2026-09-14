// 会话产物诊断（只读）：解压 session.jsonl.zstd（多帧安全）→ 统计事件类型与 message.source.kind
// 用途：定位 "cannot safely transform unclassified message source" 到底由哪种 source 引起
// 用法: node inspect-session.mjs <session.jsonl.zstd> [--dump-line N]
import { readFileSync } from 'node:fs'
import { zstdDecompressSync } from 'node:zlib'

// 与 @deepseek-ai/dsh-session-format-v2-to-v3 的 SOURCE_KINDS 保持一致
const KNOWN = new Set([
  'user', 'plugin', 'model', 'tool', 'agent-instructions', 'session-reference',
  'team-message', 'goal', 'skill-invocation', 'skill-catalog', 'coordinator',
  'subagent-report', 'subagent-settled', 'webhook', 'agent-message',
])

const MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd])
function decodeArtifact(buf) {
  const offsets = []
  let i = 0
  while ((i = buf.indexOf(MAGIC, i)) !== -1) { offsets.push(i); i += 4 }
  const parts = []
  let badFrames = 0
  for (let k = 0; k < offsets.length; k++) {
    const start = offsets[k]
    const end = k + 1 < offsets.length ? offsets[k + 1] : buf.length
    try { parts.push(zstdDecompressSync(buf.subarray(start, end))) } catch { badFrames++ }
  }
  if (parts.length === 0) {
    // 单帧兜底
    try { return { text: zstdDecompressSync(buf).toString('utf8'), frames: 1, badFrames: 0 } } catch (e) { throw e }
  }
  return { text: Buffer.concat(parts).toString('utf8'), frames: offsets.length, badFrames }
}

const file = process.argv[2]
const buf = readFileSync(file)
const { text, frames, badFrames } = decodeArtifact(buf)
const lines = text.split('\n').filter((l) => l.trim() !== '')

const eventTypes = new Map()
const kinds = new Map()
const unknown = []
const dumpLine = process.argv.includes('--dump-line') ? Number(process.argv[process.argv.indexOf('--dump-line') + 1]) : -1

function walk(node, path, evType, lineNo) {
  if (!node || typeof node !== 'object') return
  if (Array.isArray(node)) { node.forEach((v, idx) => walk(v, `${path}[${idx}]`, evType, lineNo)); return }
  if (node.source && typeof node.source === 'object' && typeof node.source.kind === 'string') {
    const k = node.source.kind
    kinds.set(k, (kinds.get(k) ?? 0) + 1)
    if (!KNOWN.has(k) && unknown.length < 8) {
      unknown.push({ line: lineNo, evType, path, source: node.source, id: node.id ?? null })
    }
  }
  for (const [key, v] of Object.entries(node)) { if (key !== 'source') walk(v, `${path}.${key}`, evType, lineNo) }
}

let parsed = 0
let unparsable = 0
lines.forEach((line, idx) => {
  let ev
  try { ev = JSON.parse(line) } catch { unparsable++; return }
  parsed++
  const t = ev.type ?? '(no type)'
  eventTypes.set(t, (eventTypes.get(t) ?? 0) + 1)
  walk(ev.data ?? ev, `L${idx}.data`, t, idx)
  if (idx === dumpLine) process.stderr.write('LINE ' + idx + ': ' + line.slice(0, 2000) + '\n')
})

const sortDesc = (m) => [...m.entries()].sort((a, b) => b[1] - a[1])
process.stdout.write(JSON.stringify({
  file,
  bytes: buf.length,
  zstdFrames: frames,
  badFrames,
  decodedEvents: parsed,
  unparsableLines: unparsable,
  firstEvent: JSON.parse(lines[0]).type ?? '(header)',
  sourceKinds: sortDesc(kinds),
  unknownSourceKinds: unknown,
  topEventTypes: sortDesc(eventTypes).slice(0, 15),
}, null, 1) + '\n')
