<#
  lib\common.ps1 — DeepSeek-Harness 启动器共享库
  =================================================
  被 DeepSeek-Harness.ps1 / run-server.ps1 / tail-log.ps1 点源加载。
  约定:
    - 只兼容 Windows PowerShell 5.1（不使用 ?? / 三元 / && / utf8NoBOM）
    - 本文件以 UTF-8 with BOM 保存（PS 5.1 无 BOM 会把中文按 GBK 误读）
    - 生成的运行时文件（state.json / safe-mode.patch.yml）不带 BOM
#>

$script:DshUtf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:DshLibDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($script:DshLibDir)) { $script:DshLibDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:DshAppDir = Split-Path -Path $script:DshLibDir -Parent

# 插件树加载失败的日志签名（仅用于诊断分类，不用于判定成败——成败看进程是否退出/是否就绪）
$script:DshFailureSignatures = @(
  'plugin tree failed to load',
  'failed to import loader entry',
  'failed to apply loader entry',
  'does not provide an export named',
  'Cannot find module',
  'ERR_MODULE_NOT_FOUND',
  'is not a function'
)

# 安全模式基线禁用 id：即便 profile 扫描失败也能覆盖已知的外部插件行
$script:DshSafeModeBaselineIds = @(
  'cost-meter', 'browser', 'browser-electron', 'tool-browser', 'config-manager',
  'mcp-connector', 'find-dsh-plugin', 'dsh-stt-input', 'ui-skin-maid-atelier',
  'agent-teams', 'better-sidebar', 'dsh-at-file'
)

# ───────────────────────── 路径 ─────────────────────────

function Get-DshAppDir { return $script:DshAppDir }
function Get-DshLibDir { return $script:DshLibDir }

function Get-DshRuntimeDir {
  $d = Join-Path $script:DshAppDir 'runtime'
  if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  return $d
}

function Get-DshLogPath {
  $d = Join-Path $script:DshAppDir 'logs'
  if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  return (Join-Path $d 'web.log')
}

function Get-DshStatePath { return (Join-Path (Get-DshRuntimeDir) 'state.json') }
function Get-DshSafeModePatchPath { return (Join-Path (Get-DshRuntimeDir) 'safe-mode.patch.yml') }
function Get-DshSafeModeKeyPath { return (Join-Path (Get-DshRuntimeDir) 'safe-mode.key') }
function Get-DshOutTmpPath { return (Join-Path (Get-DshRuntimeDir) 'stdout.tmp') }
function Get-DshErrTmpPath { return (Join-Path (Get-DshRuntimeDir) 'stderr.tmp') }

# ───────────────────────── 编码 ─────────────────────────

function Initialize-DshEncoding {
  # 关键：PS 5.1 解码原生程序输出用的是 [Console]::OutputEncoding；本机默认 GBK，
  # 而 node/dsh 输出 UTF-8 —— 不设置就会出现“已加载”变“宸插姞杞”的乱码。
  [Console]::OutputEncoding = $script:DshUtf8NoBom
  $OutputEncoding = $script:DshUtf8NoBom
}

# ───────────────────────── 配置 ─────────────────────────

function Read-DshConfig {
  $cfg = @{}
  $path = Join-Path $script:DshAppDir 'config.json'
  if (Test-Path -LiteralPath $path) {
    try {
      $j = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
      if ($j) { foreach ($p in $j.PSObject.Properties) { $cfg[$p.Name] = $p.Value } }
    }
    catch { Write-Warning "config.json 读取失败，改用自动探测: $($_.Exception.Message)" }
  }
  return $cfg
}

function Get-CfgVal {
  param($cfg, [string]$Key, $Default)
  if ($null -eq $cfg) { return $Default }
  $v = $cfg[$Key]
  if ($null -eq $v -or $v -eq '') { return $Default }
  return $v
}

function Get-DshConfigPort { param($cfg) try { return [int](Get-CfgVal $cfg 'port' 3080) } catch { return 3080 } }
function Get-DshConfigProfile { param($cfg) return [string](Get-CfgVal $cfg 'profile' 'web') }
function Get-DshConfigWindowName { param($cfg) return [string](Get-CfgVal $cfg 'terminalWindowName' 'DeepSeek-Harness') }
function Get-DshConfigWindowMode { param($cfg) return [string](Get-CfgVal $cfg 'windowMode' 'terminal') }
function Get-DshConfigTimeout { param($cfg) try { return [int](Get-CfgVal $cfg 'startTimeoutSec' 90) } catch { return 90 } }
function Get-DshConfigAutoSafeMode { param($cfg) return [bool](Get-CfgVal $cfg 'autoSafeMode' $true) }
function Get-DshConfigLogMaxMB { param($cfg) try { return [int](Get-CfgVal $cfg 'logMaxMB' 5) } catch { return 5 } }

function Get-DshKeepPlugins {
  param($cfg)
  $keep = New-Object System.Collections.Generic.List[string]
  $keep.Add('dsh-market')
  $extra = Get-CfgVal $cfg 'keepPlugins' $null
  if ($extra) { foreach ($k in @($extra)) { if (-not $keep.Contains([string]$k)) { $keep.Add([string]$k) } } }
  return $keep
}

# ───────────────────────── DSH 环境 ─────────────────────────

function Get-DshHome {
  $envHome = $env:DSH_HOME
  if ($envHome -and $envHome.Trim() -ne '') { return $envHome }
  return (Join-Path $env:USERPROFILE '.dsh')
}

function Get-DshProfileDir { param([string]$Profile) return (Join-Path (Get-DshHome) "profiles\$Profile") }

function Get-NpxDshVersion {
  # npx 缓存目录哈希每台机器不同，必须通配发现；取最新写入的那个
  $cands = Get-ChildItem "$env:LOCALAPPDATA\npm-cache\_npx\*\node_modules\@deepseek-ai\dsh\package.json" -ErrorAction SilentlyContinue
  $newest = $cands | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $newest) { return $null }
  try {
    $j = [IO.File]::ReadAllText($newest.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
    return $j.version
  }
  catch { return $null }
}

function Get-DshServerCommandLine {
  # 返回可直接交给 cmd /c 的完整命令行。
  # 注意: --profile / --patch 属于启动器参数，必须写在 web 应用参数之前。
  param([int]$Port, [string]$Profile, [string]$PatchPath, $cfg)
  $mode = [string](Get-CfgVal $cfg 'dshMode' 'auto')
  $hasGlobal = [bool](Get-Command dsh -ErrorAction SilentlyContinue)
  $base = 'npx -y @deepseek-ai/dsh'
  if ($mode -eq 'global' -and -not $hasGlobal) { Write-Warning 'config 指定 dshMode=global，但 PATH 中没有 dsh，回退 npx' }
  elseif ($hasGlobal -and ($mode -eq 'global' -or $mode -eq 'auto')) { $base = 'dsh' }
  $parts = @($base, '--profile', $Profile)
  if ($PatchPath) { $parts += @('--patch', ('"' + $PatchPath + '"')) }
  $parts += @('--no-open', '--port', "$Port")
  return ($parts -join ' ')
}

# ───────────────────────── 探测 ─────────────────────────

function Test-TcpPort {
  param([string]$TargetHost = '127.0.0.1', [int]$Port)
  try {
    $client = New-Object System.Net.Sockets.TcpClient
    $iar = $client.BeginConnect($TargetHost, $Port, $null, $null)
    $ok = $iar.AsyncWaitHandle.WaitOne(500, $false)
    if ($ok) { $client.EndConnect($iar) }
    $client.Close()
    return [bool]$ok
  }
  catch { return $false }
}

function Test-DshHttpCode {
  # 返回 HTTP 状态码；0 = 连不上/超时。不跟随后端 303 跳转（那正是鉴权成功的标志）。
  param([string]$Url, [int]$TimeoutMs = 2000)
  try {
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Timeout = $TimeoutMs
    $req.AllowAutoRedirect = $false
    $req.Proxy = $null
    $req.Method = 'GET'
    $resp = $req.GetResponse()
    $code = [int]$resp.StatusCode
    $resp.Close()
    return $code
  }
  catch [System.Net.WebException] {
    $r = $_.Exception.Response
    if ($r) { $code = [int]$r.StatusCode; $r.Close(); return $code }
    return 0
  }
  catch { return 0 }
}

function Get-DshTokenFromLog {
  # 从日志里取最近一次 “dsh web: http://127.0.0.1:PORT/?token=...” 的完整 URL
  param([string]$LogPath, [int]$Port)
  if (-not (Test-Path -LiteralPath $LogPath)) { return $null }
  try {
    $text = [IO.File]::ReadAllText($LogPath, [Text.Encoding]::UTF8)
  }
  catch { return $null }
  $pattern = 'dsh web:\s*(http://127\.0\.0\.1:' + $Port + '/\?token=[A-Za-z0-9_\-]+)'
  $ms = [regex]::Matches($text, $pattern)
  if ($ms.Count -eq 0) { return $null }
  return $ms[$ms.Count - 1].Groups[1].Value
}

function Get-DshServiceProcess {
  # 端口上监听且确实是 dsh（node + 命令行含 @deepseek-ai/dsh）的进程
  param([int]$Port)
  $list = @()
  $listeners = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
  foreach ($l in $listeners) {
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$($l.OwningProcess)" -ErrorAction SilentlyContinue
    if ($proc -and $proc.Name -match '^node' -and $proc.CommandLine -match '@deepseek-ai[\\/]dsh') { $list += $proc }
  }
  return $list
}

# 注意（血泪教训，勿加回）：不要实现“按命令行匹配所有 dsh node 进程”的通用清理函数。
# DSH Desktop（Electron 版）也有自己的 node 宿主，其命令行同样含 @deepseek-ai/dsh；
# 一次按命令行批量结束进程，直接把用户的桌面版宿主杀掉了（桌面版随即崩溃重进恢复模式）。
# 结束服务只允许两种精确口径：
#   1) 监听目标端口的 node 进程且命令行含 @deepseek-ai/dsh；
#   2) 状态文件里记录的本次启动包装进程 PID（精确到这一棵进程树）。
# 并且必须显式排除命令行含 DSH Desktop / dsh-desktop 的进程。

function Stop-DshProcessTree {
  param([int]$ProcessId)
  if (-not $ProcessId) { return }
  try { & taskkill.exe /T /F /PID $ProcessId 2>&1 | Out-Null } catch { }
}

# ───────────────────────── 状态文件 ─────────────────────────

function New-DshRunId { return ((Get-Date -Format 'yyyyMMddTHHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 6))) }

function Read-DshState {
  param([string]$Path)
  if (-not $Path) { $Path = Get-DshStatePath }
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try { return ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { return $null }
}

function Write-DshState {
  param([string]$Path, $State)
  if (-not $Path) { $Path = Get-DshStatePath }
  $dir = Split-Path -Path $Path -Parent
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $json = $State | ConvertTo-Json -Depth 5
  $tmp = "$Path.tmp"
  [IO.File]::WriteAllText($tmp, $json, $script:DshUtf8NoBom)
  Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function New-DshStateObject {
  param([string]$RunId, [string]$Status, [string]$Mode, [int]$Port)
  $now = (Get-Date).ToString('o')
  return [ordered]@{
    schema    = 1
    runId     = $RunId
    status    = $Status
    mode      = $Mode
    port      = $Port
    pid       = $null
    url       = $null
    token     = $null
    attempt   = 0
    startedAt = $now
    updatedAt = $now
    lastError = $null
  }
}

# ───────────────────────── 日志写入 ─────────────────────────

function Add-DshLogRaw {
  # 追加一行到日志：首次创建时写 UTF-8 BOM（方便 Windows 工具识别），之后不带 BOM
  param([string]$Path, [string]$Text)
  if (-not (Test-Path -LiteralPath $Path)) {
    $fs = [IO.File]::Create($Path)
    try {
      $bom = [Text.Encoding]::UTF8.GetPreamble()
      $fs.Write($bom, 0, $bom.Length)
    }
    finally { $fs.Dispose() }
  }
  $sw = New-Object System.IO.StreamWriter($Path, $true, $script:DshUtf8NoBom)
  try { $sw.WriteLine($Text) } finally { $sw.Dispose() }
}

function Write-DshLogLine {
  param([string]$Path, [string]$Text, [string]$Stamp)
  if (-not $Stamp) { $Stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss' }
  $line = "$Stamp $Text"
  Add-DshLogRaw -Path $Path -Text $line
  Write-Host $line
}

function Add-DshLogSection {
  param([string]$Path, [string]$Text)
  $line = "==== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Text ===="
  Add-DshLogRaw -Path $Path -Text ''
  Add-DshLogRaw -Path $Path -Text $line
  Write-Host ''
  Write-Host $line
}

function Read-NewLogLines {
  # 按字节增量读取文本文件，显式按 UTF-8 解码（不依赖任何控制台代码页）
  # $Reader = @{ Path=...; Pos=0; Pending='' }（哈希表按引用传递，可原地更新）
  param($Reader)
  $out = New-Object System.Collections.Generic.List[string]
  if (-not (Test-Path -LiteralPath $Reader.Path)) { return $out }
  $fs = $null
  try { $fs = [IO.File]::Open($Reader.Path, 'Open', 'Read', 'ReadWrite') } catch { return $out }
  try {
    if ($fs.Length -lt $Reader.Pos) { $Reader.Pos = 0; $Reader.Pending = '' }
    $null = $fs.Seek($Reader.Pos, 'Begin')
    $buf = New-Object byte[] 65536
    $sb = New-Object System.Text.StringBuilder
    while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
      $null = $sb.Append($script:DshUtf8NoBom.GetString($buf, 0, $n))
      $Reader.Pos += $n
    }
    if ($sb.Length -gt 0) {
      $text = $Reader.Pending + $sb.ToString()
      $parts = $text -split "`r?`n"
      $Reader.Pending = $parts[$parts.Count - 1]
      for ($i = 0; $i -lt $parts.Count - 1; $i++) { $out.Add($parts[$i]) }
    }
  }
  catch { }
  finally { if ($fs) { $fs.Dispose() } }
  return $out
}

function Invoke-DshLogRotation {
  param([string]$Path, [int]$MaxMB = 5)
  if ($MaxMB -le 0) { return $false }
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  $fi = Get-Item -LiteralPath $Path
  if ($fi.Length -le ($MaxMB * 1MB)) { return $false }
  $old = Join-Path (Split-Path -Path $Path -Parent) 'web.1.log'
  if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue }
  Move-Item -LiteralPath $Path -Destination $old -Force
  return $true
}

# ───────────────────────── 浏览器 / 终端 ─────────────────────────

function Resolve-ChromePath {
  param($cfg)
  $c = Get-CfgVal $cfg 'chromePath' $null
  if ($c -and (Test-Path -LiteralPath $c)) { return $c }
  $fixed = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
  if (Test-Path -LiteralPath $fixed) { return $fixed }
  foreach ($key in @(
      'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
      'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe'
    )) {
    $reg = (Get-ItemProperty $key -ErrorAction SilentlyContinue).'(default)'
    if ($reg -and (Test-Path -LiteralPath $reg)) { return $reg }
  }
  return $null
}

function Resolve-EdgePath {
  param($cfg)
  $c = Get-CfgVal $cfg 'edgePath' $null
  if ($c -and (Test-Path -LiteralPath $c)) { return $c }
  foreach ($key in @(
      'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
      'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe'
    )) {
    $reg = (Get-ItemProperty $key -ErrorAction SilentlyContinue).'(default)'
    if ($reg -and (Test-Path -LiteralPath $reg)) { return $reg }
  }
  foreach ($p in @(
      "$env:ProgramFiles(x86)\Microsoft\Edge\Application\msedge.exe",
      "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
      "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe"
    )) {
    if (Test-Path -LiteralPath $p) { return $p }
  }
  return $null
}

function Resolve-WtPath {
  # Windows Terminal 可执行入口：PATH 别名 → WindowsApps → Appx 安装目录
  $cmd = Get-Command wt.exe -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) { return $cmd.Source }
  $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'
  if (Test-Path -LiteralPath $alias) { return $alias }
  $pkg = Get-AppxPackage -Name Microsoft.WindowsTerminal -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($pkg -and $pkg.InstallLocation) {
    $exe = Join-Path $pkg.InstallLocation 'WindowsTerminal.exe'
    if (Test-Path -LiteralPath $exe) { return $exe }
  }
  return $null
}

function Open-DshBrowser {
  param([string]$Url, $cfg)
  $chrome = Resolve-ChromePath $cfg
  if ($chrome) { Start-Process -FilePath $chrome -ArgumentList "--app=$Url", '--no-first-run' | Out-Null; return 'chrome' }
  $edge = Resolve-EdgePath $cfg
  if ($edge) { Start-Process -FilePath $edge -ArgumentList "--app=$Url" | Out-Null; return 'edge' }
  Start-Process $Url | Out-Null
  return 'default'
}

function Start-DshLogTab {
  # 在同一个 WT 命名窗口里再开一个「日志」标签页；失败返回 $false（调用方回退）
  param([string]$RunId, [string]$WindowName, [string]$Title, [string]$LogPath, [string]$StatePath)
  $wt = Resolve-WtPath
  if (-not $wt) { return $false }
  $exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
  $script_ = Join-Path $script:DshAppDir 'tail-log.ps1'
  $argStr = '-w "{0}" nt -d "{1}" --useApplicationTitle "{2}" -NoProfile -ExecutionPolicy Bypass -File "{3}" -RunId {4} -LogPath "{5}" -StatePath "{6}" --Title "{7}"' -f `
    $WindowName, $script:DshAppDir, $exe, $script_, $RunId, $LogPath, $StatePath, $Title
  try {
    Start-Process -FilePath $wt -ArgumentList $argStr | Out-Null
    return $true
  }
  catch { return $false }
}

function Show-DshNotice {
  param([string]$Message, [string]$Title = 'DeepSeek-Harness', [int]$Icon = 0x40)
  if (Test-DshConsoleVisible) { Write-Host $Message; return }
  try {
    $ws = New-Object -ComObject WScript.Shell
    $null = $ws.Popup($Message, 0, $Title, $Icon + 0x1000)
  }
  catch { }
}

function Test-DshConsoleVisible {
  try { return ((Get-Process -Id $PID).MainWindowHandle -ne 0) } catch { return $false }
}

# ───────────────────────── 安全模式补丁 ─────────────────────────

function Get-DshInstallNodeModules {
  # dsh 安装目录的 node_modules：核心 bundle（dsh-base / dsh-web-app）只在这里，不在 profile 里
  $cands = Get-ChildItem "$env:LOCALAPPDATA\npm-cache\_npx\*\node_modules\@deepseek-ai\dsh\package.json" -ErrorAction SilentlyContinue
  $newest = $cands | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $newest) { return $null }
  return (Split-Path -Path (Split-Path -Path (Split-Path -Path $newest.FullName -Parent) -Parent) -Parent)
}

function Get-DshBundleRowIds {
  # 读某个 bundle 包的 dsh.bundle.patch 文件，抽出 insert 列表里的行 id。
  # bundle 可能装在 profile 的 node_modules，也可能在 dsh 安装目录，因此依次探测多个根。
  param([string]$ProfileDir, [string]$Bundle)
  $out = New-Object System.Collections.Generic.List[string]
  $roots = New-Object System.Collections.Generic.List[string]
  $roots.Add((Join-Path $ProfileDir 'node_modules'))
  $inst = Get-DshInstallNodeModules
  if ($inst) { $roots.Add($inst) }
  $roots.Add((Join-Path (Split-Path -Path $ProfileDir -Parent) 'node_modules'))
  $dir = $null
  foreach ($r in $roots) {
    $cand = Join-Path $r $Bundle
    if (Test-Path -LiteralPath (Join-Path $cand 'package.json')) { $dir = $cand; break }
  }
  if (-not $dir) { return $out }
  $manifest = Join-Path $dir 'package.json'
  if (-not (Test-Path -LiteralPath $manifest)) { return $out }
  try { $p = [IO.File]::ReadAllText($manifest, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { return $out }
  $rel = $null
  if ($p.dsh -and $p.dsh.bundle -and $p.dsh.bundle.patch) { $rel = [string]$p.dsh.bundle.patch }
  if (-not $rel) { return $out }
  $pf = Join-Path $dir $rel
  if (-not (Test-Path -LiteralPath $pf)) { return $out }
  foreach ($line in [IO.File]::ReadAllLines($pf, [Text.Encoding]::UTF8)) {
    $m = [regex]::Match($line, "^\s*-\s*id:\s*['""]?([A-Za-z0-9._\-/@]+)['""]?\s*$")
    if ($m.Success) { $out.Add($m.Groups[1].Value) }
  }
  return $out
}

function Get-DshSafeModePlan {
  # 推导“安全模式要禁用哪些行 id”，同时给出保留项与数据来源，供 doctor/safe-mode 展示
  param($cfg)
  $profile = Get-DshConfigProfile $cfg
  $profileDir = Get-DshProfileDir $profile
  $keep = Get-DshKeepPlugins $cfg
  $result = @{
    Profile      = $profile
    ProfileDir   = $profileDir
    Keep         = @($keep)
    KeepBundles  = @('@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app')
    Disabled     = @()
    Bundles      = @()
    BundlesKept  = @()
    Notes        = @()
    Source       = 'none'
  }
  $pkgPath = Join-Path $profileDir 'package.json'
  if (-not (Test-Path -LiteralPath $pkgPath)) {
    $result.Notes += "profile 不存在或缺少 package.json: $pkgPath"
  }
  $disabled = New-Object System.Collections.Generic.List[string]
  if (Test-Path -LiteralPath $pkgPath) {
    try {
      $pkg = [IO.File]::ReadAllText($pkgPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
      $bundles = @()
      if ($pkg.dsh -and $pkg.dsh.profile -and $pkg.dsh.profile.bundles) { $bundles = @($pkg.dsh.profile.bundles) }
      $result.Bundles = $bundles
      foreach ($b in $bundles) {
        $ids = @(Get-DshBundleRowIds -ProfileDir $profileDir -Bundle $b)
        $isKeep = $false
        foreach ($kb in $result.KeepBundles) { if ($b -eq $kb) { $isKeep = $true } }
        foreach ($k in $keep) { if ($b -eq $k -or ($ids -contains $k)) { $isKeep = $true } }
        if ($isKeep) { $result.BundlesKept += $b; continue }
        foreach ($id in $ids) { if ($keep -notcontains $id) { $disabled.Add($id) } }
      }
      $result.Source = 'profile'
    }
    catch { $result.Notes += "profile package.json 解析失败: $($_.Exception.Message)" }
  }
  # profile 自带的用户层 patch（用户自己挂的行，同样在安全模式禁用）
  $ownPatch = Join-Path $profileDir 'cordis.patch.yml'
  if (Test-Path -LiteralPath $ownPatch) {
    foreach ($line in [IO.File]::ReadAllLines($ownPatch, [Text.Encoding]::UTF8)) {
      $m = [regex]::Match($line, "^\s*-\s*id:\s*['""]?([A-Za-z0-9._\-/@]+)['""]?\s*$")
      if ($m.Success -and $keep -notcontains $m.Groups[1].Value) { $disabled.Add($m.Groups[1].Value) }
    }
  }
  # 基线兜底 + 用户追加
  foreach ($id in $script:DshSafeModeBaselineIds) { if ($keep -notcontains $id) { $disabled.Add($id) } }
  foreach ($id in @(Get-CfgVal $cfg 'safeModeExtraIds' @())) { if ($keep -notcontains [string]$id) { $disabled.Add([string]$id) } }
  # 核心行保护：核心 bundle 自带的行 id 一律不动
  # （实测存在第三方插件复用核心行 id 的情况，例如 dsh-file-upload 用了 web-app 的 file-upload）
  $protected = New-Object System.Collections.Generic.List[string]
  foreach ($kb in $result.KeepBundles) {
    foreach ($id in @(Get-DshBundleRowIds -ProfileDir $profileDir -Bundle $kb)) { $protected.Add($id) }
  }
  $result.Protected = @($protected)
  # 去重（保持首次出现顺序）+ 过滤核心行
  $seen = @{}
  $final = New-Object System.Collections.Generic.List[string]
  $blocked = New-Object System.Collections.Generic.List[string]
  foreach ($id in $disabled) {
    if ($protected -contains $id) { $blocked.Add($id); continue }
    if (-not $seen.ContainsKey($id)) { $seen[$id] = $true; $final.Add($id) }
  }
  if ($blocked.Count -gt 0) {
    $result.Notes += ('已跳过 ' + $blocked.Count + ' 个与核心行同名的 id: ' + ($blocked -join ', '))
  }
  $result.Disabled = @($final)
  return $result
}

function New-DshSafeModePatch {
  # 生成 runtime\safe-mode.patch.yml（非破坏性覆盖层：只置 disabled，绝不改用户 profile 文件）
  param($cfg, [switch]$Force)
  $patchPath = Get-DshSafeModePatchPath
  $keyPath = Get-DshSafeModeKeyPath
  $profileDir = Get-DshProfileDir (Get-DshConfigProfile $cfg)
  $pkgPath = Join-Path $profileDir 'package.json'
  $key = ''
  # 缓存键必须包含 home + profile：同一台机器可能有多套 DSH home（~\.dsh 与 DSH Desktop），
  # 覆盖层是按各自 profile 推导的，不能互相复用。
  $homeProfile = (Get-DshHome) + '|' + (Get-DshConfigProfile $cfg)
  if (Test-Path -LiteralPath $pkgPath) {
    $fi = Get-Item -LiteralPath $pkgPath
    $key = '{0}|{1}|{2}|{3}' -f $homeProfile, $fi.LastWriteTimeUtc.Ticks, $fi.Length, (Get-NpxDshVersion)
  }
  else { $key = "$homeProfile|no-profile" }
  if (-not $Force -and (Test-Path -LiteralPath $patchPath) -and (Test-Path -LiteralPath $keyPath)) {
    try {
      $oldKey = ([IO.File]::ReadAllText($keyPath, [Text.Encoding]::UTF8)).Trim()
      if ($oldKey -eq $key) { return $patchPath }
    }
    catch { }
  }
  $plan = Get-DshSafeModePlan $cfg
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('# DeepSeek-Harness 安全模式覆盖层（自动生成，请勿手工编辑）')
  $lines.Add('# 只禁用外部插件行，保留 ' + (($plan.KeepBundles + $plan.Keep) -join ' / '))
  $lines.Add('# 生成时间: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '   profile: ' + $plan.Profile)
  foreach ($id in $plan.Disabled) {
    $lines.Add('- id: ' + $id)
    $lines.Add('  disabled: true')
  }
  if ($plan.Disabled.Count -eq 0) { $lines.Add('[]') }
  [IO.File]::WriteAllText($patchPath, (($lines -join "`r`n") + "`r`n"), $script:DshUtf8NoBom)
  [IO.File]::WriteAllText($keyPath, $key, $script:DshUtf8NoBom)
  return $patchPath
}

function Test-DshSafeModePatch {
  # 用 --dump-config 离线验证覆盖层：不启动服务，只合成插件树
  param($cfg, [string]$PatchPath)
  $profile = Get-DshConfigProfile $cfg
  $cmd = Get-DshServerCommandLine -Port (Get-DshConfigPort $cfg) -Profile $profile -PatchPath $PatchPath -cfg $cfg
  $dumpCmd = $cmd -replace '\s--no-open\s--port\s\d+', ' --dump-config'
  $tmp = Join-Path (Get-DshRuntimeDir) 'dump-config.tmp'
  $proc = Start-Process -FilePath $env:ComSpec -ArgumentList "/c $dumpCmd" -NoNewWindow -PassThru -RedirectStandardOutput $tmp -RedirectStandardError (Join-Path (Get-DshRuntimeDir) 'dump-config.err')
  $null = $proc.WaitForExit(120000)
  $out = ''
  if (Test-Path -LiteralPath $tmp) { $out = [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8) }
  $disabledIds = @()
  $marketOk = $false
  foreach ($line in ($out -split "`r?`n")) {
    if ($line -match '^\s*-\s*id:\s*([A-Za-z0-9._\-/@]+)') { $cur = $Matches[1]; if ($cur -eq 'dsh-market') { $marketOk = $true } }
    if ($line -match '^\s*disabled:\s*true') { if ($cur) { $disabledIds += $cur } }
  }
  # PS 5.1: 不带 -Wait 的 Start-Process -PassThru，ExitCode 需在 WaitForExit() 之后才可读
  $ec = -1
  try { $null = $proc.WaitForExit(1000); if ($null -ne $proc.ExitCode) { $ec = [int]$proc.ExitCode } } catch { }
  return @{ ExitCode = $ec; DisabledIds = $disabledIds; MarketPresent = $marketOk; Output = $out }
}
