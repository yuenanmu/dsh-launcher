<#
  setup.ps1 — DeepSeek-Harness 安装/修复（每台机器运行一次）
  ============================================================
  用法:
    setup.ps1                      # 生成/修复桌面快捷方式（自动处理图标）
    setup.ps1 -IconPath logo.png   # 用自定义 logo 替换图标（png/ico/svg 均可）
    setup.ps1 -StopShortcut        # 额外生成 "停止" 快捷方式
    setup.ps1 -Remove              # 删除桌面快捷方式（保留应用目录）

  图标优先级: -IconPath 指定 > assets\DeepSeek-Harness.ico 已有 > 从已装 dsh 的 favicon.svg 生成 > Chrome 图标兜底
  全部路径动态解析（桌面路径兼容 OneDrive 重定向），无需管理员权限。
#>
[CmdletBinding()]
param(
  [string]$IconPath = '',
  [switch]$StopShortcut,
  [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$AppDir = $PSScriptRoot
$assetsDir = Join-Path $AppDir 'assets'
$icoTarget = Join-Path $assetsDir 'DeepSeek-Harness.ico'

# ── 配置读取（与主脚本同规则）──────────────────────────────
function Read-Config {
  $cfg = @{}
  $path = Join-Path $AppDir 'config.json'
  if (Test-Path $path) {
    try {
      $j = Get-Content $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
      if ($j) { foreach ($p in $j.PSObject.Properties) { $cfg[$p.Name] = $p.Value } }
    } catch { Write-Warning "config.json 读取失败，使用默认值: $($_.Exception.Message)" }
  }
  return $cfg
}
function Get-CfgVal {
  param($cfg, [string]$Key, $Default)
  $v = $cfg[$Key]
  if ($null -eq $v -or $v -eq '') { return $Default }
  return $v
}
function Resolve-ChromePath {
  param($cfg)
  $c = Get-CfgVal $cfg 'chromePath' $null
  if ($c -and (Test-Path $c)) { return @{ Path = $c; Source = 'config.json' } }
  $fixed = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
  if (Test-Path $fixed) { return @{ Path = $fixed; Source = '标准路径' } }
  foreach ($key in @(
      'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
      'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe'
    )) {
    $reg = (Get-ItemProperty $key -ErrorAction SilentlyContinue).'(default)'
    if ($reg -and (Test-Path $reg)) { return @{ Path = $reg; Source = '注册表 App Paths' } }
  }
  return @{ Path = $null; Source = '未找到' }
}
function Get-RealDesktop {
  param($cfg)
  $c = Get-CfgVal $cfg 'desktopPath' $null
  if ($c) { return @{ Path = $c; Source = 'config.json' } }
  return @{ Path = [Environment]::GetFolderPath('Desktop'); Source = 'GetFolderPath' }
}
function Resolve-WtPath {
  # Windows Terminal 入口：PATH 别名 → WindowsApps → Appx 安装目录（找不到则回退无窗口模式）
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

$cfg = Read-Config
$desktop = Get-RealDesktop $cfg
$name = Get-CfgVal $cfg 'shortcutName' 'DeepSeek-Harness'
$mainLnk = Join-Path $desktop.Path "$name.lnk"
$stopLnk = Join-Path $desktop.Path "$name 停止.lnk"

# ── 卸载 ──────────────────────────────────────────────────
if ($Remove) {
  foreach ($p in @($mainLnk, $stopLnk)) {
    if (Test-Path $p) { Remove-Item $p -Force; Write-Host "已删除: $p" }
  }
  Write-Host '卸载完成（应用目录与日志保留）。'
  exit 0
}

# ── 图标处理 ──────────────────────────────────────────────
function ConvertTo-PngFromSvg {
  # 用 headless Chrome 把 SVG 光栅化为 PNG（Chrome 是必需依赖，天然可用）
  param([string]$SvgPath, [string]$PngPath, $chromePath)
  $tmp = Join-Path $env:TEMP ('dsh-icon-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tmp | Out-Null
  try {
    $uri = [System.Uri]::new($SvgPath).AbsoluteUri
    $argStr = "--headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 --no-first-run --disable-extensions --user-data-dir=`"$tmp`" --window-size=256,256 --screenshot=`"$PngPath`" $uri"
    $p = Start-Process $chromePath -ArgumentList $argStr -Wait -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 500
    return (Test-Path $PngPath)
  }
  catch { return $false }
  finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function ConvertTo-IcoFromPng {
  # PNG → 多尺寸 ICO（16/32/48/64/128/256，PNG-in-ICO，Windows Vista+ 支持）
  param([string]$PngPath, [string]$IcoPath)
  Add-Type -AssemblyName System.Drawing
  $src = [System.Drawing.Image]::FromFile($PngPath)
  $sizes = @(256, 128, 64, 48, 32, 16)
  $entries = New-Object System.Collections.Generic.List[object]
  $payloads = New-Object System.Collections.Generic.List[byte[]]
  $offset = 6 + 16 * $sizes.Count
  foreach ($s in $sizes) {
    $bmp = New-Object System.Drawing.Bitmap($s, $s)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.DrawImage($src, 0, 0, $s, $s)
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bytes = $ms.ToArray()
    $ms.Dispose()
    $bmp.Dispose()
    $w = if ($s -ge 256) { 0 } else { $s }
    $entries.Add([pscustomobject]@{ W = $w; H = $w; Off = $offset; Len = $bytes.Length })
    $payloads.Add($bytes)
    $offset += $bytes.Length
  }
  $src.Dispose()
  $fs = [System.IO.File]::Create($IcoPath)
  try {
    $bw = New-Object System.IO.BinaryWriter($fs)
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$entries.Count)
    foreach ($e in $entries) {
      $bw.Write([byte]$e.W); $bw.Write([byte]$e.H)
      $bw.Write([byte]0); $bw.Write([byte]0)
      $bw.Write([uint16]1); $bw.Write([uint16]32)
      $bw.Write([uint32]$e.Len); $bw.Write([uint32]$e.Off)
    }
    foreach ($p in $payloads) { $bw.Write($p) }
    $bw.Flush()
  }
  finally { $fs.Close() }
  return (Test-Path $IcoPath)
}

function Find-DshFavicon {
  # npx 缓存哈希每台机器不同 → 通配发现已安装 dsh 的 favicon.svg
  $cands = Get-ChildItem "$env:LOCALAPPDATA\npm-cache\_npx\*\node_modules\@deepseek-ai\dsh-web-frontend\dist\favicon.svg" -ErrorAction SilentlyContinue
  $newest = $cands | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($newest) { return $newest.FullName }
  return $null
}

if (-not (Test-Path $assetsDir)) { New-Item -ItemType Directory -Force -Path $assetsDir | Out-Null }

$iconSource = $null
$iconNote = ''

if ($IconPath -ne '') {
  # 用户指定 logo
  if (-not (Test-Path $IconPath)) { throw "指定的图标文件不存在: $IconPath" }
  $ext = [System.IO.Path]::GetExtension($IconPath).ToLower()
  if ($ext -eq '.ico') {
    Copy-Item $IconPath $icoTarget -Force
    $iconSource = $icoTarget; $iconNote = "复制用户图标 -> $icoTarget"
  }
  elseif ($ext -eq '.svg') {
    $chrome = Resolve-ChromePath $cfg
    if (-not $chrome.Path) { throw 'SVG 转图标需要 Chrome，但未找到 Chrome。请改用 -IconPath 提供 .ico 或 .png。' }
    $png = Join-Path $assetsDir 'DeepSeek-Harness.png'
    if (ConvertTo-PngFromSvg $IconPath $png $chrome.Path) {
      if (ConvertTo-IcoFromPng $png $icoTarget) { $iconSource = $icoTarget; $iconNote = "SVG 光栅化 -> $icoTarget" }
    }
    if (-not $iconSource) { throw 'SVG 光栅化失败。' }
  }
  else {
    # png/jpg 等位图直接转换
    if (ConvertTo-IcoFromPng $IconPath $icoTarget) { $iconSource = $icoTarget; $iconNote = "位图转换 -> $icoTarget" }
    else { throw '位图转 ICO 失败。' }
  }
}
elseif (Test-Path $icoTarget) {
  $iconSource = $icoTarget
  $iconNote = "使用已有图标 $icoTarget"
}
else {
  # 自动从已安装 dsh 提取经典 logo
  $favicon = Find-DshFavicon
  if ($favicon) {
    $chrome = Resolve-ChromePath $cfg
    if ($chrome.Path) {
      $png = Join-Path $assetsDir 'DeepSeek-Harness.png'
      $ok1 = ConvertTo-PngFromSvg $favicon $png $chrome.Path
      $ok2 = if ($ok1) { ConvertTo-IcoFromPng $png $icoTarget } else { $false }
      if ($ok2) {
        $iconSource = $icoTarget
        $iconNote = "从 dsh favicon 生成: $favicon -> $icoTarget"
      }
    }
  }
  if (-not $iconSource) {
    $iconNote = '未生成图标，快捷方式将使用 Chrome 图标'
    Write-Warning $iconNote
  }
}
if ($iconSource) { Write-Host "图标: $iconNote" }

# ── 生成快捷方式 ──────────────────────────────────────────
$ws = New-Object -ComObject WScript.Shell

function New-Lnk {
  param([string]$Path, [string]$TargetPath, [string]$ArgsText, [string]$Desc)
  $lnk = $ws.CreateShortcut($Path)
  $lnk.TargetPath = $TargetPath
  $lnk.Arguments = $ArgsText
  $lnk.WorkingDirectory = $AppDir
  if ($iconSource) { $lnk.IconLocation = "$iconSource,0" }
  $lnk.Description = $Desc
  $lnk.Save()
}

# 入口形态:
#   Windows Terminal 可用 → 快捷方式直接拉起「命名窗口 + 第一个标签页」，
#     该标签页本身就是服务（关窗口=停服务），脚本会再补一个「DSH 日志」标签页。
#     （不能用 -WindowStyle Hidden 的隐藏进程: Win11 默认终端是 WT 时 SW_HIDE 不生效，
#       隐藏进程会变成一个可见窗口 —— 这正是旧版“双击后冒出两个命令行窗口”的原因。）
#   无 WT → 回退旧形态（隐藏进程 + 只写日志文件）
$psExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$windowName = Get-CfgVal $cfg 'terminalWindowName' 'DeepSeek-Harness'
$wtPath = Resolve-WtPath
if ($wtPath) {
  $mainTarget = $wtPath
  $mainArgs = '-w "{0}" nt -d "{1}" --useApplicationTitle "{2}" -NoProfile -ExecutionPolicy Bypass -File "{3}" start' -f `
    $windowName, $AppDir, $psExe, "$AppDir\DeepSeek-Harness.ps1"
  $mainDesc = 'DeepSeek-Harness 一键启动（单窗口：DSH 服务 + 日志 两个标签页）'
  Write-Host "入口: Windows Terminal ($wtPath) 窗口名: $windowName"
}
else {
  $mainTarget = $psExe
  $mainArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$AppDir\DeepSeek-Harness.ps1`" start"
  $mainDesc = 'DeepSeek-Harness 一键启动（服务 + Chrome 独立窗口）'
  Write-Warning '未找到 Windows Terminal，回退无窗口模式（日志只写文件，失败时弹窗提示）'
}
New-Lnk -Path $mainLnk -TargetPath $mainTarget -ArgsText $mainArgs -Desc $mainDesc
Write-Host "已生成: $mainLnk"

if ($StopShortcut) {
  $stopArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$AppDir\DeepSeek-Harness.ps1`" stop"
  New-Lnk -Path $stopLnk -TargetPath $psExe -ArgsText $stopArgs -Desc 'DeepSeek-Harness 停止服务并关闭窗口'
  Write-Host "已生成: $stopLnk"
}

# 刷新图标缓存（可能失败，忽略）
try { & "$env:SystemRoot\System32\ie4uinit.exe" -show -ErrorAction Stop | Out-Null } catch {}

Write-Host ''
Write-Host '安装完成。日常使用：双击桌面 "DeepSeek-Harness" 图标。'
Write-Host '子命令/诊断：setup.cmd doctor  或  powershell -File "DeepSeek-Harness.ps1" doctor'
