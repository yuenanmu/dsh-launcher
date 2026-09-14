<#
  DeepSeek-Harness.ps1 — 一键启动（Windows Terminal 单窗口双标签页）
  =================================================================
  子命令:
    start      启动服务并打开 Chrome 独立窗口（默认）。服务未运行时本进程即「DSH 服务」标签页。
    stop       停止服务、关闭 Chrome 独立窗口（终端窗口会随之自动关闭）
    status     查看运行状态（含正常/安全模式）
    doctor     环境诊断（-Json 写出 environment-report.json；-Verify 校验安全模式覆盖层）
    safe-mode  生成/查看/校验安全模式覆盖层（-Rebuild 强制重算 / -Show 打印 / -Verify 用 --dump-config 校验）
    serve      内部: 前台运行服务（run-server.ps1 与 start 都会用到）
    tail-log   内部: 日志跟随标签页

  设计要点:
    - 服务就绪判定不用 HTTP 标题（新版 DSH 的 GUI 需要进程令牌，裸访问必 401），
      而是抓 dsh 打印的 "dsh web: http://127.0.0.1:PORT/?token=..." 行；该令牌同时用于打开 Chrome。
    - 插件树加载失败/超时会自动以「安全模式」重试: 用 --patch 覆盖层禁用除 dsh-market 外的外部插件，
      不改动你的任何配置与 profile 文件。
    - 日志写入完全绕开 PowerShell 文本管线（cmd 重定向 + 显式 UTF-8 读取），杜绝 GBK 乱码。
  兼容 Windows PowerShell 5.1；本文件 UTF-8 with BOM。
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('start', 'stop', 'status', 'doctor', 'safe-mode', 'serve', 'tail-log')]
  [string]$Action = 'start',

  # doctor 附加: 写出机器可读报告 / 校验安全模式补丁
  [switch]$Json,
  [switch]$Verify,

  # stop 附加: 只报告将结束的进程，不实际执行
  [switch]$DryRun,

  # start 附加: 强制安全模式 / 覆盖窗口模式(terminal|hidden)
  [switch]$SafeMode,
  [string]$WindowMode = '',

  # safe-mode 附加
  [switch]$Rebuild,
  [switch]$Show,

  # 内部参数
  [string]$RunId = '',
  [int]$Port = 0,
  [string]$LogPath = '',
  [string]$StatePath = '',
  [string]$Title = 'DSH 日志',
  [switch]$InWindow
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')
. (Join-Path $PSScriptRoot 'lib\service.ps1')
Initialize-DshEncoding

$cfg = Read-DshConfig
$appDir = Get-DshAppDir
if ($Port -le 0) { $Port = Get-DshConfigPort $cfg }
if (-not $LogPath) { $LogPath = Get-DshLogPath }
if (-not $StatePath) { $StatePath = Get-DshStatePath }

function Get-DshEffectiveWindowMode {
  if ($WindowMode -ne '') { return $WindowMode }
  return (Get-DshConfigWindowMode $cfg)
}

function Test-DshServiceRunning {
  param([int]$PortNumber)
  if (-not (Test-TcpPort '127.0.0.1' $PortNumber)) { return $false }
  return (@(Get-DshServiceProcess -Port $PortNumber).Count -gt 0)
}

function Test-DshInsideTerminal {
  # 判断当前进程是否已经跑在 Windows Terminal 标签页里（用于手动 CLI 调用时自动并窗）
  try {
    $me = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue
    if (-not $me) { return $false }
    $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($me.ParentProcessId)" -ErrorAction SilentlyContinue
    if ($parent -and $parent.Name -match 'WindowsTerminal') { return $true }
    return $false
  }
  catch { return $false }
}

function Start-DshLauncher {
  param([bool]$ForceSafeMode, [bool]$AlreadyInWindow)

  $state = Read-DshState -Path $StatePath

  # ① 服务已在运行 → 只开浏览器，不再开窗/不加标签页
  if (Test-DshServiceRunning -Port $Port) {
    $procs = @(Get-DshServiceProcess -Port $Port)
    $pids = ($procs | ForEach-Object { $_.ProcessId }) -join ','
    Write-Host "服务已在运行（端口 $Port, PID $pids），直接打开窗口。"
    Add-DshLogRaw -Path $LogPath -Text ("$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') 复用已在运行的服务（端口 $Port, PID $pids）")
    $url = $null
    if ($state -and $state.status -eq 'running' -and $state.url) { $url = [string]$state.url }
    if (-not $url) { $url = Get-DshTokenFromLog -LogPath $LogPath -Port $Port }
    $open = "http://127.0.0.1:$Port/"
    if ($url) {
      $code = Test-DshHttpCode -Url $url
      if ($code -eq 303 -or $code -eq 200) { $open = $url }
      else { Write-Host "本地令牌校验返回 $code，改用无令牌地址（浏览器通常已有登录 cookie）。" }
    }
    else { Write-Host '未在日志里找到启动令牌，改用无令牌地址（浏览器通常已有登录 cookie）。' }
    $b = Open-DshBrowser -Url $open -cfg $cfg
    Write-Host "已用 $b 打开: $open"
    return 0
  }

  # ② 端口被别的程序占用（绝不是 dsh）
  if (Test-TcpPort '127.0.0.1' $Port) {
    $msg = "端口 $Port 已被其他程序占用（不是 DeepSeek Harness）。请先处理占用或修改 config.json 的 port。"
    Write-Host $msg
    if (-not (Test-DshConsoleVisible)) { Show-DshNotice -Message $msg -Icon 0x10 }
    return 1
  }

  # ③ 防连点：上一次启动还在进行
  if ($state -and $state.status -eq 'starting' -and $state.updatedAt) {
    try {
      $age = ((Get-Date) - ([datetime]$state.updatedAt)).TotalSeconds
      if ($age -lt 90) {
        Write-Host ("另一次启动正在进行中（{0:N0} 秒前），本次不再重复启动。" -f $age)
        return 0
      }
    }
    catch { }
  }

  # ④ 手动在普通控制台里调用时，自动把工作搬到 Windows Terminal 命名窗口（保持一致体验）
  $wm = Get-DshEffectiveWindowMode
  $wt = Resolve-WtPath
  if ($wm -eq 'terminal' -and $wt -and -not $AlreadyInWindow -and -not (Test-DshInsideTerminal)) {
    $exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    # 标签标题由脚本内部用 RawUI 设置（避免中文经由命令行传递带来的编码风险）
    $argsText = '-w "{0}" nt -d "{1}" --useApplicationTitle "{2}" -NoProfile -ExecutionPolicy Bypass -File "{3}" start' -f `
      (Get-DshConfigWindowName $cfg), $appDir, $exe, $PSCommandPath
    if ($ForceSafeMode) { $argsText = $argsText + ' -SafeMode' }
    $argsText = $argsText + ' -InWindow'
    Start-Process -FilePath $wt -ArgumentList $argsText | Out-Null
    Write-Host '已在 Windows Terminal「DeepSeek-Harness」窗口中启动服务。'
    return 0
  }

  # ⑤ 正常启动：写状态 → 开日志标签页 → 前台监督
  if (Invoke-DshLogRotation -Path $LogPath -MaxMB (Get-DshConfigLogMaxMB $cfg)) {
    Write-Host '日志超过上限，已轮转为 logs\web.1.log'
  }
  $newRunId = New-DshRunId
  $mode = 'normal'
  if ($ForceSafeMode) { $mode = 'safe' }
  Write-DshState -Path $StatePath -State (New-DshStateObject -RunId $newRunId -Status 'starting' -Mode $mode -Port $Port)

  $hidden = ($wm -eq 'hidden')
  if (-not $hidden -and $AlreadyInWindow) {
    if (Start-DshLogTab -RunId $newRunId -WindowName (Get-DshConfigWindowName $cfg) -Title 'DSH 日志' -LogPath $LogPath -StatePath $StatePath) {
      Write-Host '已在本窗口新建「DSH 日志」标签页。'
    }
    else {
      Write-Host '未找到 Windows Terminal，日志只写入文件。'
      $hidden = $true
    }
  }

  return (Invoke-DshServiceSupervisor -RunId $newRunId -Port $Port -Profile (Get-DshConfigProfile $cfg) `
      -LogPath $LogPath -StatePath $StatePath -ForceSafeMode $ForceSafeMode `
      -TimeoutSec (Get-DshConfigTimeout $cfg) -AutoSafeMode (Get-DshConfigAutoSafeMode $cfg) -cfg $cfg -HiddenMode $hidden)
}

function Get-DshProcessTable {
  # 一次性取全量进程快照（PID/父PID/名/命令行），供进程树归属判断
  $t = @{}
  foreach ($p in (Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
    $t[[int]$p.ProcessId] = @{ Pid = [int]$p.ProcessId; Parent = [int]$p.ParentProcessId; Name = $p.Name; Cmd = [string]$p.CommandLine }
  }
  return $t
}

function Test-DshDescendantOf {
  # 判断 $TargetPid 是否在 $AncestorPid 的进程树里（向上走父链，最多 12 层）
  # 注意: 参数不能叫 $Pid —— $PID 是 PowerShell 的只读自动变量，绑定会直接抛
  #       "Cannot overwrite variable Pid because it is read-only or constant"。
  param($Table, [int]$TargetPid, [int]$AncestorPid, [int]$MaxDepth = 12)
  if (-not $AncestorPid -or -not $TargetPid) { return $false }
  if ($TargetPid -eq $AncestorPid) { return $true }
  $cur = $TargetPid
  for ($d = 0; $d -lt $MaxDepth; $d++) {
    if (-not $Table.ContainsKey($cur)) { return $false }
    $par = $Table[$cur].Parent
    if (-not $par -or $par -le 0) { return $false }
    if ($par -eq $AncestorPid) { return $true }
    $cur = $par
  }
  return $false
}

function Stop-Dsh {
  param([bool]$Dry)
  $state = Read-DshState -Path $StatePath
  if ($state -and -not $Dry) {
    $state.status = 'stopping'
    $state.updatedAt = (Get-Date).ToString('o')
    Write-DshState -Path $StatePath -State $state
  }

  # 安全红线（血泪教训，务必保持）：
  #   · 旧版曾用「按命令行匹配所有 dsh node 进程」批量清理，把 DSH Desktop（Electron 版）
  #     自己的 node 宿主一起杀了 —— 桌面版当场退出。**永不恢复那种写法。**
  #   · 归属判据以「进程树」为准，不以进程名/路径为准：
  #       ① state.pid（本次启动的包装进程 cmd.exe）死亡则整棵树 taskkill /T；
  #       ② 本端口的监听者若在 state.pid 的进程树内 → 属于我们；
  #       ③ 无 state.pid（旧版启动的服务）时退化为「命令行含 @deepseek-ai\dsh 且不带
  #          --expose-internals」——`--expose-internals` 是 DSH Desktop 宿主的特征。
  #   · 注意环境陷阱：某些会话里 `node` 会解析到桌面版自带的 node.exe
  #     （…\DSH Desktop\resources\app\node_modules\node\bin\node.exe），
  #     所以「命令行/路径里出现 DSH Desktop」并不能说明它不是我们的服务，不能据此排除。
  $table = Get-DshProcessTable
  $statePid = 0
  if ($state -and $state.pid) { try { $statePid = [int]$state.pid } catch { $statePid = 0 } }

  $listeners = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
  $serverPids = @()
  $skipped = @()
  $foreign = @()
  foreach ($l in $listeners) {
    $lp = [int]$l.OwningProcess
    if (-not $table.ContainsKey($lp)) { $skipped += $lp; continue }
    $rec = $table[$lp]
    $isOurs = $false
    if ($statePid -gt 0 -and (Test-DshDescendantOf -Table $table -TargetPid $lp -AncestorPid $statePid)) { $isOurs = $true }
    elseif ($statePid -le 0 -and $rec.Cmd -match '@deepseek-ai[\\/]dsh' -and $rec.Cmd -notmatch '--expose-internals') { $isOurs = $true }
    if ($isOurs) { $serverPids += $lp }
    elseif ($rec.Cmd -match '--expose-internals' -or $rec.Name -match 'DSH Desktop') { $foreign += $lp }
    else { $skipped += $lp }
  }

  if ($Dry) { Write-Host '== 演练模式(-DryRun)，未执行任何操作 ==' }
  foreach ($target in $foreign) { Write-Warning "PID $target 看起来是 DSH Desktop 桌面版宿主，已跳过（绝不结束桌面版）。" }

  # ① 优先按进程树整体结束本次启动（cmd 包装器 → npx → node）
  $ownTreeKilled = $false
  if ($statePid -gt 0 -and $table.ContainsKey($statePid)) {
    $rec = $table[$statePid]
    if ($Dry) {
      Write-Host "将结束本次启动的进程树: PID=$statePid ($($rec.Name))"
    }
    else {
      Stop-DshProcessTree -ProcessId $statePid
      Write-Host "已结束本次启动的进程树: PID=$statePid ($($rec.Name))"
    }
    $ownTreeKilled = $true
  }

  # ② 端口监听者（state.pid 缺失或包装器已退出时的兜底）
  foreach ($target in $serverPids) {
    if ($target -eq $statePid -and $ownTreeKilled) { continue }
    $name = (Get-Process -Id $target -ErrorAction SilentlyContinue).ProcessName
    if ($Dry) { Write-Host "将结束 dsh 服务进程: PID=$target ($name)" }
    else {
      Stop-Process -Id $target -Force -ErrorAction SilentlyContinue
      Write-Host "已结束 dsh 服务进程: PID=$target ($name)"
    }
  }
  if ($serverPids.Count -eq 0) { Write-Host "端口 $Port 上没有检测到 dsh 服务进程。" }
  foreach ($target in $skipped) { Write-Warning "端口 $Port 被疑似非 dsh 进程占用 (PID=$target)，已跳过，未结束。" }

  # 关闭 Chrome 独立窗口（先优雅关闭，再兜底强杀）
  $appWindows = Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match "app=http://127\.0\.0\.1:$Port" }
  foreach ($cw in $appWindows) {
    if ($Dry) { Write-Host "将关闭 Chrome 独立窗口: PID=$($cw.ProcessId)" }
    else {
      $p = Get-Process -Id $cw.ProcessId -ErrorAction SilentlyContinue
      if ($p) { $null = $p.CloseMainWindow() }
    }
  }
  if (-not $Dry -and @($appWindows).Count -gt 0) {
    Start-Sleep -Milliseconds 800
    foreach ($cw in $appWindows) {
      if (Get-Process -Id $cw.ProcessId -ErrorAction SilentlyContinue) {
        Stop-Process -Id $cw.ProcessId -Force -ErrorAction SilentlyContinue
      }
    }
    Write-Host "已关闭 Chrome 独立窗口: $(@($appWindows).Count) 个"
  }

  if (-not $Dry) {
    Set-DshStateStatus -StatePath $StatePath -Status 'stopped'
    Add-DshLogRaw -Path $LogPath -Text ("$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') 服务已由 stop 停止")
    Write-Host '已停止。「DSH 服务」「DSH 日志」标签页会自动退出，终端窗口随之关闭。'
  }
}

function Show-Status {
  $state = Read-DshState -Path $StatePath
  $running = Test-DshServiceRunning -Port $Port
  if ($running) {
    $procs = @(Get-DshServiceProcess -Port $Port)
    Write-Host '状态: 运行中'
    Write-Host ("端口: {0} (PID {1})" -f $Port, (($procs | ForEach-Object { $_.ProcessId }) -join ','))
    if ($state) {
      Write-Host ("模式: {0}" -f $(if ($state.mode -eq 'safe') { '安全模式（除 dsh-market 外的外部插件已禁用）' } else { '正常模式' }))
      if ($state.startedAt) { Write-Host ("启动时间: {0}" -f ([datetime]$state.startedAt).ToString('yyyy-MM-dd HH:mm:ss')) }
      if ($state.url) { Write-Host ("地址: {0}" -f ($state.url -replace 'token=[A-Za-z0-9_\-]+', 'token=***')) }
      Write-Host ("runId: {0}" -f $state.runId)
    }
    $appWindows = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -match "app=http://127\.0\.0\.1:$Port" })
    Write-Host ("Chrome 独立窗口: {0} 个" -f $appWindows.Count)
    Write-Host ("地址: http://127.0.0.1:{0}" -f $Port)
  }
  else {
    Write-Host "状态: 未运行（端口 $Port 空闲）"
    if ($state -and $state.status -eq 'failed') { Write-Host ("上次启动失败: {0}" -f $state.lastError) }
  }
}

function Show-Doctor {
  param([bool]$WriteJson, [bool]$VerifySafeMode)
  $chrome = Resolve-ChromePath $cfg
  $edge = Resolve-EdgePath $cfg
  $wt = Resolve-WtPath
  $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
  $npmCmd = Get-Command npm -ErrorAction SilentlyContinue
  $globalDsh = Get-Command dsh -ErrorAction SilentlyContinue
  $npxVer = Get-NpxDshVersion
  $profile = Get-DshConfigProfile $cfg
  $profileDir = Get-DshProfileDir $profile
  $plan = Get-DshSafeModePlan $cfg
  $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
  $state = Read-DshState -Path $StatePath
  $svcCmd = Get-DshServerCommandLine -Port $Port -Profile $profile -PatchPath $null -cfg $cfg

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('=== DeepSeek-Harness 环境报告 (doctor) ===')
  $lines.Add("[系统]        $([System.Environment]::OSVersion.VersionString)")
  $lines.Add("[PowerShell]  $($PSVersionTable.PSVersion.ToString()) ($($PSVersionTable.PSEdition))")
  $lines.Add("[用户]        $env:USERNAME  ($env:USERPROFILE)")
  $lines.Add("[Chrome]      $(if ($chrome) { $chrome } else { '未找到' })")
  $lines.Add("[Edge]        $(if ($edge) { $edge } else { '未找到' })")
  $lines.Add("[Windows Terminal] $(if ($wt) { $wt } else { '未找到（将回退无窗口模式）' })")
  $lines.Add("[窗口模式]    $(Get-DshEffectiveWindowMode)")
  $nodeVer = if ($nodeCmd) { ((node --version 2>$null) -replace '^v', '') } else { $null }
  $npmVer = if ($npmCmd) { ((npm --version 2>$null) -replace '\s+$', '') } else { $null }
  $lines.Add("[Node.js]     $(if ($nodeCmd) { "$($nodeCmd.Source)  (v$nodeVer)" } else { '未找到 (请先安装 Node.js)' })")
  $lines.Add("[npm]         $(if ($npmCmd) { "$($npmCmd.Source)  (v$npmVer)" } else { '未找到' })")
  $dshText = '未安装（将用 npx）'
  if ($globalDsh) {
    $dshText = "$($globalDsh.Source)"
    if ($globalDsh.Source -match 'npm-cache\\_npx') { $dshText = "$dshText  (注意: 来自 npx 缓存的临时 PATH，不是全局安装)" }
  }
  $lines.Add("[全局 dsh]    $dshText")
  $lines.Add("[npx 缓存dsh] $(if ($npxVer) { "v$npxVer" } else { '未发现 (首次运行 npx 会自动下载)' })")
  $lines.Add("[服务命令]    $svcCmd")
  $lines.Add("[DSH 数据目录] $(Get-DshHome)")
  $lines.Add("[profile]     $profile  ($profileDir)")
  $lines.Add("[bundle 数]   $(@($plan.Bundles).Count) 个: $(@($plan.Bundles) -join ', ')")
  $lines.Add("[安全模式保留] $(@($plan.KeepBundles + $plan.Keep) -join ' / ')")
  $lines.Add("[安全模式禁用] $(@($plan.Disabled).Count) 个行 id: $(@($plan.Disabled) -join ', ')")
  $lines.Add("[端口 $Port]   $(if ($listener) { "占用中 (PID $($listener.OwningProcess))" } else { '空闲' })")
  if ($state) { $lines.Add("[上次状态]    $($state.status) / $($state.mode)  runId=$($state.runId)") }
  $lines | ForEach-Object { Write-Host $_ }

  if ($VerifySafeMode) {
    Write-Host ''
    Write-Host '--- 校验安全模式覆盖层（dsh --dump-config，不启动服务）---'
    $patch = New-DshSafeModePatch -cfg $cfg -Force
    $res = Test-DshSafeModePatch -cfg $cfg -PatchPath $patch
    Write-Host ("覆盖层: $patch")
    Write-Host ("dump-config 退出码: $($res.ExitCode)")
    Write-Host ("dsh-market 行存在: $($res.MarketPresent)")
    Write-Host ("被 disabled 的行: $($res.DisabledIds -join ', ')")
  }

  if ($WriteJson) {
    $report = [ordered]@{
      os            = "$([System.Environment]::OSVersion.VersionString)"
      psVersion     = "$($PSVersionTable.PSVersion.ToString())"
      user          = $env:USERNAME
      userProfile   = $env:USERPROFILE
      chrome        = $chrome
      edge          = $edge
      windowsTerminal = $wt
      windowMode    = (Get-DshEffectiveWindowMode)
      node          = if ($nodeCmd) { @{ path = $nodeCmd.Source; version = (node --version 2>$null) } } else { $null }
      npm           = if ($npmCmd) { @{ path = $npmCmd.Source; version = (npm --version 2>$null) } } else { $null }
      globalDsh     = if ($globalDsh) { $globalDsh.Source } else { $null }
      npxCacheDsh   = $npxVer
      serverCommand = $svcCmd
      dshHome       = (Get-DshHome)
      profile       = $profile
      profileDir    = $profileDir
      bundles       = @($plan.Bundles)
      safeModeKeep  = @($plan.KeepBundles + $plan.Keep)
      safeModeDisabled = @($plan.Disabled)
      port          = $Port
      portInUse     = [bool]$listener
      state         = $state
      config        = $cfg
    }
    $out = Join-Path $appDir 'environment-report.json'
    [IO.File]::WriteAllText($out, ($report | ConvertTo-Json -Depth 6), $script:DshUtf8NoBom)
    Write-Host ''
    Write-Host "已写出机器可读报告: $out"
  }
}

function Show-SafeModeInfo {
  param([bool]$Force, [bool]$PrintContent, [bool]$DoVerify)
  if ($Force) { Remove-Item -LiteralPath (Get-DshSafeModePatchPath) -Force -ErrorAction SilentlyContinue }
  $patch = New-DshSafeModePatch -cfg $cfg -Force:$Force
  $plan = Get-DshSafeModePlan $cfg
  Write-Host "安全模式覆盖层: $patch"
  Write-Host "保留: $(@($plan.KeepBundles + $plan.Keep) -join ' / ')"
  Write-Host ("禁用 $(@($plan.Disabled).Count) 个行 id:")
  foreach ($id in $plan.Disabled) { Write-Host "  - $id" }
  if ($plan.Notes.Count -gt 0) { foreach ($n in $plan.Notes) { Write-Warning $n } }
  if ($PrintContent) {
    Write-Host ''
    Write-Host '--- 覆盖层内容 ---'
    Write-Host ([IO.File]::ReadAllText($patch, [Text.Encoding]::UTF8))
  }
  if ($DoVerify) {
    Write-Host ''
    Write-Host '--- 校验（dsh --dump-config）---'
    $res = Test-DshSafeModePatch -cfg $cfg -PatchPath $patch
    Write-Host ("退出码: $($res.ExitCode)   dsh-market 行存在: $($res.MarketPresent)")
    Write-Host ("被 disabled 的行: $($res.DisabledIds -join ', ')")
  }
}

# ───────────────────────── 入口 ─────────────────────────

switch ($Action) {
  'start' { exit (Start-DshLauncher -ForceSafeMode ([bool]$SafeMode) -AlreadyInWindow ([bool]$InWindow)) }
  'stop' { Stop-Dsh -Dry ([bool]$DryRun); exit 0 }
  'status' { Show-Status; exit 0 }
  'doctor' { Show-Doctor -WriteJson ([bool]$Json) -VerifySafeMode ([bool]$Verify); exit 0 }
  'safe-mode' { Show-SafeModeInfo -Force ([bool]$Rebuild) -PrintContent ([bool]$Show) -DoVerify ([bool]$Verify); exit 0 }
  'serve' {
    if (-not $RunId) { $RunId = New-DshRunId }
    $st = Read-DshState -Path $StatePath
    if (-not $st -or $st.runId -ne $RunId) {
      Write-DshState -Path $StatePath -State (New-DshStateObject -RunId $RunId -Status 'starting' -Mode $(if ($SafeMode) { 'safe' } else { 'normal' }) -Port $Port)
    }
    exit (Invoke-DshServiceSupervisor -RunId $RunId -Port $Port -Profile (Get-DshConfigProfile $cfg) `
        -LogPath $LogPath -StatePath $StatePath -ForceSafeMode ([bool]$SafeMode) `
        -TimeoutSec (Get-DshConfigTimeout $cfg) -AutoSafeMode (Get-DshConfigAutoSafeMode $cfg) -cfg $cfg -HiddenMode ([bool](Get-DshEffectiveWindowMode -eq 'hidden')))
  }
  'tail-log' {
    if (-not $RunId) { $RunId = New-DshRunId }
    Invoke-DshLogTail -RunId $RunId -LogPath $LogPath -StatePath $StatePath -Title $Title
    exit 0
  }
}
