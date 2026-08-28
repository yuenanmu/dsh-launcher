<#
  DeepSeek-Harness 一键启动（双机统一版）
  ========================================
  子命令:
    start   启动服务(如未运行)并打开 Chrome 独立窗口  [默认]
    stop    停止 3080 上的 dsh 服务并关闭对应 Chrome 窗口
    status  查看运行状态
    doctor  输出环境报告(含取值来源)，-Json 同时写出 environment-report.json

  配置: 同目录 config.json 可覆盖自动探测结果（优先级: config.json > 自动探测）。
  要求: Windows PowerShell 5.1+，Node.js + npm（DSH 依赖），Chrome（无则回退 Edge/默认浏览器）。
  全程不写死用户路径；所有路径动态解析，同一份文件可在任意 Windows 机器直接使用。
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('start', 'stop', 'status', 'doctor')]
  [string]$Action = 'start',

  # doctor 附加: 同时写出 environment-report.json（机器可读，供另一台机器的 agent 读取）
  [switch]$Json,

  # stop 附加: 只报告将要结束的进程，不实际执行（安全演练）
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$AppDir = $PSScriptRoot

# ───────────────────────── 工具函数 ─────────────────────────

function Read-Config {
  # 读取同目录 config.json；缺省/损坏时返回空表（全部回退自动探测）
  $cfg = @{}
  $path = Join-Path $AppDir 'config.json'
  if (Test-Path $path) {
    try {
      $j = Get-Content $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
      if ($j) { foreach ($p in $j.PSObject.Properties) { $cfg[$p.Name] = $p.Value } }
    }
    catch {
      Write-Warning "config.json 读取失败，改用自动探测: $($_.Exception.Message)"
    }
  }
  return $cfg
}

function Get-CfgVal {
  param($cfg, [string]$Key, $Default)
  $v = $cfg[$Key]
  if ($null -eq $v -or $v -eq '') { return $Default }
  return $v
}

function Get-ConfigPort {
  param($cfg)
  try { return [int](Get-CfgVal $cfg 'port' 3080) } catch { return 3080 }
}

function Test-TcpPort {
  # 快速 TCP 连通探测（500ms 超时）
  param([string]$Host_, [int]$Port)
  try {
    $client = New-Object System.Net.Sockets.TcpClient
    $iar = $client.BeginConnect($Host_, $Port, $null, $null)
    $ok = $iar.AsyncWaitHandle.WaitOne(500, $false)
    if ($ok) { $client.EndConnect($iar) }
    $client.Close()
    return [bool]$ok
  }
  catch { return $false }
}

function Test-DshHttp {
  # HTTP GET / 并校验标题含 "DeepSeek Harness"，确认占用端口的确实是 dsh
  param([int]$Port)
  try {
    $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$Port/")
    $req.Timeout = 1500
    $req.Method = 'GET'
    $resp = $req.GetResponse()
    $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
    $html = $reader.ReadToEnd()
    $reader.Close(); $resp.Close()
    return ($html -match 'DeepSeek Harness')
  }
  catch { return $false }
}

function Show-Popup {
  # 隐藏窗口(无控制台可见)时用弹窗提示；正常终端运行时输出到控制台
  param([string]$Message, [string]$Title = 'DeepSeek-Harness', [int]$Icon = 0x40)
  $hidden = ((Get-Process -Id $PID).MainWindowHandle -eq 0)
  if ($hidden) {
    $ws = New-Object -ComObject WScript.Shell
    $null = $ws.Popup($Message, 0, $Title, $Icon + 0x1000)
  }
  else {
    Write-Host $Message
  }
}

function Resolve-ChromePath {
  # 返回 @{ Path; Source }；优先级: config.json > 标准路径 > 注册表 App Paths
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

function Resolve-EdgePath {
  param($cfg)
  $c = Get-CfgVal $cfg 'edgePath' $null
  if ($c -and (Test-Path $c)) { return @{ Path = $c; Source = 'config.json' } }
  foreach ($key in @(
      'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
      'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe'
    )) {
    $reg = (Get-ItemProperty $key -ErrorAction SilentlyContinue).'(default)'
    if ($reg -and (Test-Path $reg)) { return @{ Path = $reg; Source = '注册表 App Paths' } }
  }
  foreach ($p in @(
      "$env:ProgramFiles(x86)\Microsoft\Edge\Application\msedge.exe",
      "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
      "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe"
    )) {
    if (Test-Path $p) { return @{ Path = $p; Source = '标准路径' } }
  }
  return @{ Path = $null; Source = '未找到' }
}

function Resolve-ServerCommand {
  # 返回 @{ Cmd; Mode }；dshMode: auto(默认) | npx | global
  # 注意: 必须把 --port 显式传给 dsh，否则服务端永远按默认 3080 绑定
  param($cfg, [int]$Port)
  $mode = Get-CfgVal $cfg 'dshMode' 'auto'
  $portFlag = "--port $Port"
  $g = Get-Command dsh -ErrorAction SilentlyContinue
  if ($mode -eq 'global') {
    if ($g) { return @{ Cmd = "dsh web --no-open $portFlag"; Mode = 'global' } }
    Write-Warning "config 指定 dshMode=global，但 PATH 中没有 dsh，回退 npx"
    return @{ Cmd = "npx -y @deepseek-ai/dsh web --no-open $portFlag"; Mode = 'npx(回退)' }
  }
  if ($mode -eq 'npx') { return @{ Cmd = "npx -y @deepseek-ai/dsh web --no-open $portFlag"; Mode = 'npx' } }
  # auto
  if ($g) { return @{ Cmd = "dsh web --no-open $portFlag"; Mode = 'global(auto)' } }
  return @{ Cmd = "npx -y @deepseek-ai/dsh web --no-open $portFlag"; Mode = 'npx(auto)' }
}

function Get-NpxDshVersion {
  # npx 缓存哈希每台机器不同，必须通配发现
  $cands = Get-ChildItem "$env:LOCALAPPDATA\npm-cache\_npx\*\node_modules\@deepseek-ai\dsh\package.json" -ErrorAction SilentlyContinue
  $newest = $cands | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $newest) { return $null }
  try { return (Get-Content $newest.FullName -Raw | ConvertFrom-Json).version } catch { return $null }
}

function Get-DshHome {
  $envHome = $env:DSH_HOME
  if ($envHome -and $envHome.Trim() -ne '') { return $envHome }
  return (Join-Path $env:USERPROFILE '.dsh')
}

function Get-RealDesktop {
  param($cfg)
  $c = Get-CfgVal $cfg 'desktopPath' $null
  if ($c) { return @{ Path = $c; Source = 'config.json' } }
  return @{ Path = [Environment]::GetFolderPath('Desktop'); Source = 'GetFolderPath' }
}

# ───────────────────────── 子命令: start ─────────────────────────

function Start-Dsh {
  $cfg = Read-Config
  $port = Get-ConfigPort $cfg
  $url = "http://127.0.0.1:$port"
  $log = Join-Path $AppDir 'logs\web.log'

  $listening = Test-TcpPort '127.0.0.1' $port

  if (-not $listening) {
    # 服务未运行 → 后台隐藏启动
    $logDir = Split-Path $log
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
    $svc = Resolve-ServerCommand $cfg $port
    # 通过环境变量传递启动命令，规避 Start-Process 参数引号问题
    $env:DSH_LAUNCHER_CMD = $svc.Cmd
    $run = Join-Path $AppDir 'run-server.ps1'
    $argStr = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$run`""
    try {
      Start-Process powershell.exe -ArgumentList $argStr | Out-Null
    }
    catch {
      Show-Popup "启动服务进程失败: $($_.Exception.Message)" -Icon 0x10
      exit 1
    }
    Write-Host "正在启动 DeepSeek Harness 服务 ($($svc.Mode))，等待端口 $port ..."

    $ready = $false
    for ($i = 0; $i -lt 120; $i++) {
      Start-Sleep -Milliseconds 500
      if (Test-TcpPort '127.0.0.1' $port) { $ready = $true; break }
    }
    if (-not $ready) {
      Show-Popup "服务启动超时(60s)。请查看日志: $log" -Icon 0x10
      exit 1
    }
    Start-Sleep -Milliseconds 800
    if (-not (Test-DshHttp $port)) {
      Show-Popup "端口 $port 已打开但 HTTP 校验失败，可能不是 dsh 服务。请查看日志: $log" -Icon 0x10
      exit 1
    }
    Write-Host "服务已就绪: $url"
  }
  else {
    # 已监听 → 校验是否确实是 dsh，避免把陌生程序当服务
    if (-not (Test-DshHttp $port)) {
      Show-Popup "端口 $port 已被其他程序占用（不是 DeepSeek Harness）。请先处理占用或修改 config.json 中的 port。" -Icon 0x10
      exit 1
    }
    Write-Host "检测到服务已在运行，直接打开窗口..."
  }

  # 打开 Chrome 独立窗口（--app 模式隐藏地址栏；任务栏图标自动取页面 favicon = dsh logo）
  $chrome = Resolve-ChromePath $cfg
  if ($chrome.Path) {
    Start-Process $chrome.Path -ArgumentList "--app=$url", '--no-first-run' | Out-Null
  }
  else {
    $edge = Resolve-EdgePath $cfg
    if ($edge.Path) {
      Start-Process $edge.Path -ArgumentList "--app=$url" | Out-Null
    }
    else {
      Start-Process $url
    }
  }
  Write-Host "已打开: $url"
}

# ───────────────────────── 子命令: stop ─────────────────────────

function Stop-Dsh {
  param([bool]$Dry)
  $cfg = Read-Config
  $port = Get-ConfigPort $cfg
  $url = "http://127.0.0.1:$port"

  $listeners = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
  $serverPids = @()
  $skipped = @()
  foreach ($l in $listeners) {
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$($l.OwningProcess)" -ErrorAction SilentlyContinue
    if ($proc -and $proc.Name -match '^node' -and $proc.CommandLine -match '@deepseek-ai[\\/]dsh') {
      $serverPids += $l.OwningProcess
    }
    else {
      $skipped += $l.OwningProcess
    }
  }

  if ($Dry) {
    Write-Host "== 演练模式(-DryRun)，未执行任何操作 =="
  }

  foreach ($pid_ in $serverPids) {
    $name = (Get-Process -Id $pid_ -ErrorAction SilentlyContinue).ProcessName
    if ($Dry) {
      Write-Host "将结束 dsh 服务进程: PID=$pid_ ($name)"
    }
    else {
      Stop-Process -Id $pid_ -Force -ErrorAction SilentlyContinue
      Write-Host "已结束 dsh 服务进程: PID=$pid_ ($name)"
    }
  }
  if ($serverPids.Count -eq 0) {
    Write-Host "端口 $port 上没有检测到 dsh 服务进程。"
  }
  foreach ($pid_ in $skipped) {
    Write-Warning "端口 $port 被疑似非 dsh 进程占用 (PID=$pid_)，已跳过，未结束。"
  }

  # 关闭匹配的 Chrome 独立窗口（先优雅关闭，再兜底强杀）
  $appWindows = Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match "app=http://127\.0\.0\.1:$port" }
  foreach ($cw in $appWindows) {
    if ($Dry) {
      Write-Host "将关闭 Chrome 独立窗口: PID=$($cw.ProcessId)"
    }
    else {
      $p = Get-Process -Id $cw.ProcessId -ErrorAction SilentlyContinue
      if ($p) { $null = $p.CloseMainWindow() }
    }
  }
  if (-not $Dry -and $appWindows.Count -gt 0) {
    Start-Sleep -Milliseconds 800
    foreach ($cw in $appWindows) {
      if (Get-Process -Id $cw.ProcessId -ErrorAction SilentlyContinue) {
        Stop-Process -Id $cw.ProcessId -Force -ErrorAction SilentlyContinue
      }
    }
    Write-Host "已关闭 Chrome 独立窗口: $($appWindows.Count) 个"
  }

  $hidden = ((Get-Process -Id $PID).MainWindowHandle -eq 0)
  if (-not $Dry -and $hidden) {
    $ws = New-Object -ComObject WScript.Shell
    $msg = "DeepSeek-Harness 已停止`n`n结束服务进程: $($serverPids.Count) 个`n关闭窗口: $($appWindows.Count) 个"
    if ($skipped.Count -gt 0) { $msg += "`n注意: 有 $($skipped.Count) 个非 dsh 进程占用端口，已跳过" }
    $null = $ws.Popup($msg, 0, 'DeepSeek-Harness', 0x40 + 0x1000)
  }
}

# ───────────────────────── 子命令: status ─────────────────────────

function Show-Status {
  $cfg = Read-Config
  $port = Get-ConfigPort $cfg
  $listener = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($listener) {
    $proc = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
    Write-Host "状态: 运行中"
    Write-Host "端口: $port (PID $($listener.OwningProcess), $($proc.ProcessName))"
    if ($proc) { Write-Host "启动时间: $($proc.StartTime.ToString('yyyy-MM-dd HH:mm:ss'))" }
    $appWindows = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -match "app=http://127\.0\.0\.1:$port" })
    Write-Host "Chrome 独立窗口: $($appWindows.Count) 个"
    Write-Host "地址: http://127.0.0.1:$port"
  }
  else {
    Write-Host "状态: 未运行（端口 $port 空闲）"
  }
}

# ───────────────────────── 子命令: doctor ─────────────────────────

function Show-Doctor {
  param([bool]$WriteJson)
  $cfg = Read-Config
  $port = Get-ConfigPort $cfg
  $chrome = Resolve-ChromePath $cfg
  $edge = Resolve-EdgePath $cfg
  $desktop = Get-RealDesktop $cfg
  $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
  $npmCmd = Get-Command npm -ErrorAction SilentlyContinue
  $globalDsh = Get-Command dsh -ErrorAction SilentlyContinue
  $npxVer = Get-NpxDshVersion
  $svc = Resolve-ServerCommand $cfg $port
  $listener = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
  $dshHome = Get-DshHome

  $lines = [System.Collections.Generic.List[string]]::new()
  $lines.Add('=== DeepSeek-Harness 环境报告 (doctor) ===')
  $lines.Add("[系统]        $([System.Environment]::OSVersion.VersionString)")
  $lines.Add("[PowerShell]  $($PSVersionTable.PSVersion.ToString()) ($($PSVersionTable.PSEdition))")
  $lines.Add("[用户]        $env:USERNAME  ($env:USERPROFILE)")
  $lines.Add("[桌面路径]    $($desktop.Path)  [$($desktop.Source)]")
  $lines.Add("[Chrome]      $(if ($chrome.Path) { $chrome.Path } else { '未找到' })  [$($chrome.Source)]")
  $lines.Add("[Edge]        $(if ($edge.Path) { $edge.Path } else { '未找到' })  [$($edge.Source)]")

  # 注意: PowerShell 5.1 禁止在双引号字符串的 $(...) 内再写双引号，因此先算好文本再拼行
  $nodeVer = if ($nodeCmd) { ((node --version 2>$null) -replace '^v', '') } else { $null }
  $npmVer = if ($npmCmd) { ((npm --version 2>$null) -replace '\s+$', '') } else { $null }
  $nodeText = if ($nodeCmd) { "$($nodeCmd.Source)  (v$nodeVer)" } else { '未找到 (请先安装 Node.js)' }
  $npmText = if ($npmCmd) { "$($npmCmd.Source)  (v$npmVer)" } else { '未找到' }
  $globalDshText = if ($globalDsh) { $globalDsh.Source } else { '未安装' }
  $npxText = if ($npxVer) { "v$npxVer (缓存哈希每台机器不同)" } else { '未发现 (首次运行 npx 会自动下载)' }
  $portText = if ($listener) { "占用中 (PID $($listener.OwningProcess))" } else { '空闲' }
  # 仅当值与内置默认不同才视为"覆盖"（避免把显式写入的默认值误报为覆盖）
  $defaults = @{ dshMode = 'auto'; port = 3080; shortcutName = 'DeepSeek-Harness' }
  $overrideKeys = @($cfg.Keys | Where-Object {
      $null -ne $cfg[$_] -and $cfg[$_] -ne '' -and $cfg[$_] -ne $defaults[$_]
    })
  $overrideText = if ($overrideKeys.Count -gt 0) { ($overrideKeys -join ', ') } else { '无 (全部自动探测)' }

  $lines.Add("[Node.js]     $nodeText")
  $lines.Add("[npm]         $npmText")
  $lines.Add("[全局 dsh]    $globalDshText")
  $lines.Add("[npx 缓存dsh] $npxText")
  $lines.Add("[服务命令]    $($svc.Cmd)  [模式: $($svc.Mode)]")
  $lines.Add("[DSH 数据目录] $dshHome")
  $lines.Add("[端口 $port]   $portText")
  $lines.Add("[配置覆盖]    $overrideText")

  $lines | ForEach-Object { Write-Host $_ }

  if ($WriteJson) {
    $report = [ordered]@{
      os            = "$([System.Environment]::OSVersion.VersionString)"
      psVersion     = "$($PSVersionTable.PSVersion.ToString())"
      user          = $env:USERNAME
      userProfile   = $env:USERPROFILE
      desktopPath   = @{ value = $desktop.Path; source = $desktop.Source }
      chrome        = @{ value = $chrome.Path; source = $chrome.Source }
      edge          = @{ value = $edge.Path; source = $edge.Source }
      node          = if ($nodeCmd) { @{ path = $nodeCmd.Source; version = (node --version 2>$null) } } else { $null }
      npm           = if ($npmCmd) { @{ path = $npmCmd.Source; version = (npm --version 2>$null) } } else { $null }
      globalDsh     = if ($globalDsh) { $globalDsh.Source } else { $null }
      npxCacheDsh   = $npxVer
      serverCommand = @{ cmd = $svc.Cmd; mode = $svc.Mode }
      dshHome       = $dshHome
      port          = $port
      portInUse     = [bool]$listener
      portOwnerPid  = if ($listener) { $listener.OwningProcess } else { $null }
      config        = $cfg
    }
    $out = Join-Path $AppDir 'environment-report.json'
    $report | ConvertTo-Json -Depth 4 | Set-Content -Path $out -Encoding utf8
    Write-Host ''
    Write-Host "已写出机器可读报告: $out"
  }
}

# ───────────────────────── 入口 ─────────────────────────

switch ($Action) {
  'start'  { Start-Dsh }
  'stop'   { Stop-Dsh -Dry $DryRun }
  'status' { Show-Status }
  'doctor' { Show-Doctor -WriteJson $Json }
}
