// 离线校验安全模式覆盖层：复用 DSH 自身 app-boot 的 loadProfile/composeEntries（与 `dsh --dump-config` 同一套合成函数）
// 做法: 合成两次（不带覆盖层 / 带覆盖层），差集 = 覆盖层真正禁用的行。只读，不写任何文件。
// 用法: node verify-overlay.mjs <installRoot> <home> <patchFile>
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'

const installRoot = process.argv[2]   // <npx cache>/node_modules/@deepseek-ai
const home = process.argv[3]          // DSH home
const patchFile = process.argv[4]

const boot = await import(pathToFileURL(join(installRoot, 'dsh-app-boot', 'lib', 'index.js')).href)
const { loadProfile, composeEntries, loadOverlayPatches, loadOptionalPatches, PROFILE_PATCH_FILENAME } = boot
const warn = (m) => process.stderr.write('[warn] ' + m + '\n')

const profile = loadProfile('dsh', 'web', join(installRoot, 'dsh', 'package.json'), home, { userLayer: true })
const bundlePatches = profile.layers.flatMap((l) => l.patches)
const homePatches = loadOptionalPatches('dsh', join(home, PROFILE_PATCH_FILENAME)) ?? []
const overlays = loadOverlayPatches('dsh', patchFile)

const base = composeEntries([bundlePatches, profile.patches, homePatches], warn)
const withOverlay = composeEntries([bundlePatches, profile.patches, homePatches, overlays], warn)

const baseDisabled = new Set(base.filter((r) => r.disabled === true).map((r) => r.id))
const overDisabled = withOverlay.filter((r) => r.disabled === true).map((r) => r.id)
const newlyDisabled = overDisabled.filter((id) => !baseDisabled.has(id))
const unDisabled = [...baseDisabled].filter((id) => !overDisabled.includes(id))
const ids = withOverlay.map((r) => r.id)

process.stdout.write(JSON.stringify({
  home,
  layers: profile.layers.map((l) => `${l.packageName}(${l.patches.length})`),
  composedRows: withOverlay.length,
  overlayRows: overlays.length,
  marketRowPresent: ids.includes('dsh-market'),
  marketDisabledByOverlay: newlyDisabled.includes('dsh-market'),
  newlyDisabledByOverlay: newlyDisabled,
  accidentallyUnDisabled: unDisabled,
  preexistingDisabledCount: baseDisabled.size,
}, null, 1) + '\n')
