// 会话产物修复/验证工具（DSH session format v2→v3 兼容性）
// ============================================================================
// 背景: 第三方插件（dsh-at-file / dsh-agent-teams 等）会把自定义 source.kind 写进会话日志，
//       而新版 DSH 的 v2→v3 迁移器对 source.kind 是严格白名单，遇到未知 kind 就整条会话拒绝加载
//       （报错 "cannot safely transform unclassified message source"，且保留原产物）。
// 本工具: 把“被校验位置”上的未知 source.kind 映射成白名单内的合法 kind，
//        其余内容与帧结构保持不变；修复后用 DSH 自身的迁移链验证能否通过。
//
// 用法:
//   node session-doctor.mjs verify <artifact>  <installNodeModules>
//   node session-doctor.mjs repair <artifact>  <installNodeModules> [--apply] [--keep-fields]
//     --apply        就地替换（先备份 <artifact>.pre-repair-<时间戳>.bak）；默认只写 <artifact>.repaired 副本
//     --keep-fields  只改 kind，保留 source 上的其他字段（默认保留；--drop-fields 才裁剪）
import { readFileSync, writeFileSync, copyFileSync, statSync } from 'node:fs'
import { zstdDecompressSync, zstdCompressSync, constants } from 'node:zlib'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'

const KNOWN = new Set([
  'user', 'plugin', 'model', 'tool', 'agent-instructions', 'session-reference',
  'team-message', 'goal', 'skill-invocation', 'skill-catalog', 'coordinator',
  'subagent-report', 'subagent-settled', 'webhook', 'agent-message',
])
// 插件自定义 kind → 合法 kind 的映射（可自行扩充）
// v0→v1 迁移器按 kind 校验成员（见 dsh-session-format-v0-to-v1 的 messageSourceValue）:
//   user   : { kind }  (+ 可选 rpcId / clientTimeZone)
//   plugin : { kind, plugin: <非空字符串> }  (+ 可选 form / sections / summary)
//   model  : { kind, provider, model }      tool: { kind, callId }
const MAP = {
  'at-file-mention': 'user',        // 用户 @文件 产生的 user 消息（内容即 <workspace-reference …/>）
  'agent-teams-command': 'plugin',  // 插件注入的命令消息（用户原话在 source.goal）
}
const PLUGIN_NAME = {
  'agent-teams-command': '@nanmicoder/dsh-agent-teams',
}
const MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd])
const ZSTD_OPTS = { params: { [constants.ZSTD_c_checksumFlag]: 1 } }

function decodeFrames(buf) {
  const offsets = []
  let i = 0
  while ((i = buf.indexOf(MAGIC, i)) !== -1) { offsets.push(i); i += 4 }
  const parts = []
  let bad = 0
  for (let k = 0; k < offsets.length; k++) {
    const s = offsets[k]
    const e = k + 1 < offsets.length ? offsets[k + 1] : buf.length
    try { parts.push(zstdDecompressSync(buf.subarray(s, e))) } catch { bad++ }
  }
  if (!parts.length) return { text: zstdDecompressSync(buf).toString('utf8'), frames: 1, bad: 0 }
  return { text: Buffer.concat(parts).toString('utf8'), frames: offsets.length, bad }
}

/** 事件中被 v2→v3 迁移器 assertSource 校验的 source 位置 */
function checkedSources(ev) {
  const d = ev.data ?? {}
  const out = []
  if (ev.type === 'user/message') { if (d.source) out.push(d.source) }
  else if (ev.type === 'assistant/message' || ev.type === 'tool/result') { if (d.message && d.message.source) out.push(d.message.source) }
  else if (ev.type === 'agent/inbox/spliced') { for (const m of d.inserted ?? []) if (m && m.source) out.push(m.source) }
  else if (ev.type === 'session/title-llm-request') { for (const m of d.messages ?? []) if (m && m.source) out.push(m.source) }
  return out
}

const tryJson = (t) => { try { return JSON.parse(t) } catch { return undefined } }

async function loadCatalog(installNodeModules) {
  const mod = await import(pathToFileURL(join(installNodeModules, '@deepseek-ai', 'dsh-session-format-catalog', 'lib', 'index.js')).href)
  return mod.sessionFormatCatalog
}

/** 用 DSH 自己的迁移链验证一段 JSONL 文本 */
async function verifyText(text, catalog) {
  const rows = text.split('\n').filter((l) => l.trim() !== '')
  if (rows.length === 0) return { ok: false, error: 'empty artifact' }
  const headerRaw = tryJson(rows[0]) ?? rows[0]
  const out = { rows: rows.length, headerStatus: null, ok: false }
  try {
    out.headerStatus = catalog.readHeader(headerRaw)
  } catch (e) { out.headerError = e.name + ': ' + e.message }
  let restore
  try {
    restore = catalog.createRestore(headerRaw, { validation: 'transformed' })
  } catch (e) {
    out.error = 'createRestore -> ' + e.name + ': ' + e.message
    return out
  }
  try {
    // rows[0] 是表头行（已交给 createRestore），事件行从 rows[1] 开始
    for (const row of rows.slice(1)) restore.decodeRow(tryJson(row) ?? row)
    const artifact = restore.finish()
    out.ok = true
    out.events = Array.isArray(artifact?.events) ? artifact.events.length : null
    out.headerVersion = artifact?.header?.version ?? null
  } catch (e) {
    out.error = e.name + ': ' + e.message
  }
  return out
}

function repairText(text) {
  const lines = text.split('\n')
  const changes = []
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    if (!line.trim()) continue
    let ev
    try { ev = JSON.parse(line) } catch { continue }
    let mutated = false
    for (const src of checkedSources(ev)) {
      if (typeof src.kind === 'string' && !KNOWN.has(src.kind)) {
        const from = src.kind
        const to = MAP[from] ?? 'plugin'
        // ① 保数据：agent-teams 把用户原话放在 source.goal，裁剪前先搬回消息正文
        let preserved = false
        if (typeof src.goal === 'string' && src.goal !== '' && ev.data && Array.isArray(ev.data.content)) {
          ev.data.content.push({ type: 'text', text: '\n[原始指令 · 迁移保留] ' + src.goal })
          preserved = true
        }
        const droppedFields = Object.keys(src).filter((k) => k !== 'kind')
        // ② 只保留 kind（+ plugin 必需的 plugin 成员）—— 迁移器会拒绝多余的 source 成员
        for (const k of droppedFields) delete src[k]
        src.kind = to
        if (to === 'plugin') src.plugin = PLUGIN_NAME[from] ?? from
        changes.push({ line: i, evType: ev.type, from, to, id: (ev.data && ev.data.id) ?? null, droppedFields, goalPreserved: preserved })
        mutated = true
      }
    }
    if (mutated) lines[i] = JSON.stringify(ev)
  }
  return { text: lines.join('\n'), changes }
}

// ───────────────────────── CLI ─────────────────────────
const [mode, artifact, installNodeModules] = process.argv.slice(2)
if (!mode || !artifact || !installNodeModules) {
  process.stdout.write('usage: node session-doctor.mjs verify|repair <artifact> <installNodeModules> [--apply]\n')
  process.exit(2)
}
const catalog = await loadCatalog(installNodeModules)

if (mode === 'verify') {
  const { text, frames, bad } = decodeFrames(readFileSync(artifact))
  const res = await verifyText(text, catalog)
  process.stdout.write(JSON.stringify({ mode, artifact, frames, badFrames: bad, ...res }, null, 1) + '\n')
  process.exit(res.ok ? 0 : 1)
}

if (mode === 'repair') {
  const apply = process.argv.includes('--apply')
  const buf = readFileSync(artifact)
  const { text, frames, bad } = decodeFrames(buf)
  const repaired = repairText(text)
  const before = await verifyText(text, catalog)
  const packed = zstdCompressSync(Buffer.from(repaired.text, 'utf8'), ZSTD_OPTS)
  const target = apply ? artifact : artifact + '.repaired'
  if (apply) {
    const stamp = new Date().toISOString().replace(/[:.]/g, '-')
    copyFileSync(artifact, artifact + '.pre-repair-' + stamp + '.bak')
  }
  writeFileSync(target, packed)
  const after = await verifyText(repaired.text, catalog)
  process.stdout.write(JSON.stringify({
    mode, artifact, applied: apply, target,
    sourceBytes: statSync(artifact).size, repairedBytes: packed.length, frames, badFrames: bad,
    changes: repaired.changes,
    verifyBefore: before,
    verifyAfter: after,
  }, null, 1) + '\n')
  process.exit(after.ok ? 0 : 1)
}

process.stdout.write('unknown mode: ' + mode + '\n')
process.exit(2)
