<#
  lib\service.ps1 — DeepSeek-Harness 服务角色
  ============================================
    Invoke-DshServiceSupervisor  Tab1「DSH 服务」：前台持有 dsh 服务、tee 日志、
                                 就绪后开 Chrome、失败自动进入安全模式重试
    Invoke-DshLogTail            Tab2「DSH 日志」：只读跟随日志文件
  依赖 lib\common.ps1（先点源 common，再点源本文件）。
  兼容 Windows PowerShell 5.1；本文件 UTF-8 with BOM。
#>

function Get-DshLogSnapshot {
  # 用 FileShare.ReadWrite 读日志尾部（MUST：避免与写入方互相占用）
  param([string]$Path, [int]$MaxBytes = 32768)
  $res = @{ Pos = 0; Text = '' }
  if (-not (Test-Path -LiteralPath $Path)) { return $res }
  $fs = $null
  try { $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite') } catch { return $res }
  try {
    $len = $fs.Length
    $res.Pos = $len
    $take = [Math]::Min([int64]$MaxBytes, $len)
    if ($take -gt 0) {
      $null = $fs.Seek($len - $take, 'Begin')
      $buf = New-Object byte[] $take
      $read = $fs.Read($buf, 0, $take)
      $res.Text = $script:DshUtf8NoBom.GetString($buf, 0, $read)
    }
  }
  catch { }
  finally { if ($fs) { $fs.Dispose() } }
  return $res
}

function Set-DshStateStatus {
  param([string]$StatePath, [string]$Status, [string]$LastError)
  $st = Read-DshState -Path $StatePath
  if (-not $st) { return }
  $st.status = $Status
  $st.updatedAt = (Get-Date).ToString('o')
  if ($LastError) { $st.lastError = $LastError }
  Write-DshState -Path $StatePath -State $st
}

function Invoke-DshServiceAttempt {
  # 一次启动尝试：跑到底（服务正常运行时一直阻塞），返回分类结果
  param(
    [string]$Mode, [int]$Port, [string]$Profile, [string]$LogPath, [string]$StatePath,
    [string]$RunId, [int]$TimeoutSec, [string]$PatchPath, $cfg, [int]$Attempt
  )
  $modeText = '正常模式'
  if ($Mode -eq 'safe') { $modeText = '安全模式' }
  $cmd = Get-DshServerCommandLine -Port $Port -Profile $Profile -PatchPath $PatchPath -cfg $cfg
  $outTmp = Get-DshOutTmpPath
  $errTmp = Get-DshErrTmpPath
  Add-DshLogSection -Path $LogPath -Text "[$modeText] 第 $Attempt 次尝试: $cmd"

  $S = @{ Ready = $false; Url = $null; Signature = $null; Opened = $false; Stopped = $false }
  $handle = {
    param([string]$line)
    if ([string]::IsNullOrEmpty($line)) { return }
    if ($line.Trim() -eq '') { return }
    Write-DshLogLine -Path $LogPath -Text $line
    if (-not $S.Ready) {
      $m = [regex]::Match($line, 'dsh web:\s*(http://127\.0\.0\.1:\d+/\?token=[A-Za-z0-9_\-]+)')
      if ($m.Success) { $S.Url = $m.Groups[1].Value; $S.Ready = $true }
    }
    if (-not $S.Signature) {
      foreach ($sig in $script:DshFailureSignatures) {
        if ($line.IndexOf($sig, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $S.Signature = $sig; break }
      }
    }
  }

  $proc = $null
  try {
    # cmd /c + 重定向到文件：完全绕开 PS 的文本管线，node 的 UTF-8 字节原样落盘，结构性杜绝乱码
    $proc = Start-Process -FilePath $env:ComSpec -ArgumentList "/c $cmd" -NoNewWindow -PassThru `
      -RedirectStandardOutput $outTmp -RedirectStandardError $errTmp
  }
  catch {
    Add-DshLogRaw -Path $LogPath -Text ("启动子进程失败: " + $_.Exception.Message)
    return @{ Ready = $false; ExitCode = -1; Signature = 'spawn-failed'; Stopped = $false; Url = $null }
  }

  $rdOut = @{ Path = $outTmp; Pos = 0; Pending = '' }
  $rdErr = @{ Path = $errTmp; Pos = 0; Pending = '' }
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  $i = 0
  while (-not $proc.HasExited) {
    foreach ($l in (Read-NewLogLines $rdOut)) { & $handle $l }
    foreach ($l in (Read-NewLogLines $rdErr)) { & $handle $l }

    if ($S.Ready -and -not $S.Opened) {
      $S.Opened = $true
      $st = New-DshStateObject -RunId $RunId -Status 'running' -Mode $Mode -Port $Port
      $st.pid = $proc.Id
      $st.url = $S.Url
      $st.attempt = $Attempt
      $m = [regex]::Match($S.Url, 'token=([A-Za-z0-9_\-]+)')
      if ($m.Success) { $st.token = $m.Groups[1].Value }
      Write-DshState -Path $StatePath -State $st
      $title = "DSH 服务 · $Port"
      if ($Mode -eq 'safe') { $title = $title + ' · 安全模式' }
      try { $Host.UI.RawUI.WindowTitle = $title } catch { }
      $browser = Open-DshBrowser -Url $S.Url -cfg $cfg
      Write-DshLogLine -Path $LogPath -Text "[$modeText] 服务已就绪 (PID $($proc.Id))，已用 $browser 打开: $($S.Url)"
      Write-Host ''
      Write-Host '服务运行中。关闭本窗口即停止服务。'
      Write-Host ''
    }

    $i++
    if (($i % 20) -eq 0) {
      $st2 = Read-DshState -Path $StatePath
      if ($st2 -and $st2.status -eq 'stopping') {
        $S.Stopped = $true
        Write-DshLogLine -Path $LogPath -Text '收到停止请求，结束服务进程'
        Stop-DshProcessTree -ProcessId $proc.Id
        break
      }
    }
    if (-not $S.Ready -and (Get-Date) -gt $deadline) {
      Write-DshLogLine -Path $LogPath -Text "[$modeText] 启动超时（$TimeoutSec 秒）未捕获就绪地址，结束本次尝试"
      if (-not $S.Signature) { $S.Signature = 'startup-timeout' }
      Stop-DshProcessTree -ProcessId $proc.Id
      break
    }
    Start-Sleep -Milliseconds 250
  }

  try { if (-not $proc.HasExited) { $null = $proc.WaitForExit(5000) } } catch { }
  foreach ($l in (Read-NewLogLines $rdOut)) { & $handle $l }
  foreach ($l in (Read-NewLogLines $rdErr)) { & $handle $l }
  $ec = -1
  try {
    # PS 5.1 的 Start-Process -PassThru 在不带 -Wait 时 ExitCode 可能为 $null；
    # 先 WaitForExit() 才会填上（进程已退出时该调用立即返回）。
    $null = $proc.WaitForExit(1000)
    if ($null -ne $proc.ExitCode) { $ec = [int]$proc.ExitCode }
  }
  catch { }
  return @{ Ready = $S.Ready; ExitCode = $ec; Signature = $S.Signature; Stopped = $S.Stopped; Url = $S.Url }
}

function Invoke-DshServiceSupervisor {
  param(
    [string]$RunId, [int]$Port, [string]$Profile, [string]$LogPath, [string]$StatePath,
    [bool]$ForceSafeMode, [int]$TimeoutSec, [bool]$AutoSafeMode, $cfg, [bool]$HiddenMode
  )
  Initialize-DshEncoding
  try { $Host.UI.RawUI.WindowTitle = "DSH 服务 · $Port" } catch { }

  Write-Host ''
  Write-Host "DeepSeek-Harness 服务 · 端口 $Port"
  Write-Host '关闭本窗口即停止服务（日志标签页可滚动回看）'
  Write-Host "日志文件: $LogPath"
  Write-Host ''

  $modes = New-Object System.Collections.Generic.List[string]
  if ($ForceSafeMode) { $modes.Add('safe') }
  else {
    $modes.Add('normal')
    if ($AutoSafeMode) { $modes.Add('safe') }
  }
  $patchPath = $null
  if ($modes.Contains('safe')) {
    try { $patchPath = New-DshSafeModePatch -cfg $cfg } catch { $patchPath = $null }
  }

  $attempt = 0
  $lastWhy = ''
  foreach ($mode in $modes) {
    $attempt++
    if ($mode -eq 'safe') {
      if (-not $patchPath) {
        Add-DshLogSection -Path $LogPath -Text '无法生成安全模式覆盖层，跳过安全模式'
        continue
      }
      Add-DshLogSection -Path $LogPath -Text '插件不兼容 → 进入安全模式：除 dsh-market 外的外部插件全部禁用（不改动你的配置文件）'
    }
    $r = Invoke-DshServiceAttempt -Mode $mode -Port $Port -Profile $Profile -LogPath $LogPath `
      -StatePath $StatePath -RunId $RunId -TimeoutSec $TimeoutSec -PatchPath $(if ($mode -eq 'safe') { $patchPath } else { $null }) `
      -cfg $cfg -Attempt $attempt

    if ($r.Stopped) {
      Set-DshStateStatus -StatePath $StatePath -Status 'stopped'
      Add-DshLogRaw -Path $LogPath -Text ''
      return 0
    }
    if ($r.Ready) {
      Set-DshStateStatus -StatePath $StatePath -Status 'stopped' -LastError $(if ($r.ExitCode -ne 0) { "服务进程退出，退出码 $($r.ExitCode)" } else { $null })
      Write-DshLogLine -Path $LogPath -Text "服务进程已退出（退出码 $($r.ExitCode)）"
      if ($r.ExitCode -eq 0) { return 0 }
      return 1
    }
    $lastWhy = '未捕获就绪地址'
    if ($r.Signature) { $lastWhy = "命中失败签名: $($r.Signature)" }
    $lastWhy = "$lastWhy（退出码 $($r.ExitCode)）"
    Write-DshLogLine -Path $LogPath -Text "[$mode] 启动失败：$lastWhy"
  }

  Set-DshStateStatus -StatePath $StatePath -Status 'failed' -LastError $lastWhy
  Add-DshLogSection -Path $LogPath -Text "启动失败：两轮尝试都未成功（$lastWhy）"
  Write-Host ''
  Write-Host '启动失败。排查建议：'
  Write-Host "  1) 看上面的报错，或滚动到日志标签页查看历史"
  Write-Host "  2) 完整日志: $LogPath"
  Write-Host "  3) 手动诊断: powershell -ExecutionPolicy Bypass -File `"$(Join-Path $script:DshAppDir 'DeepSeek-Harness.ps1')`" doctor"
  Write-Host "  4) 市场可用时在 GUI 或安全模式里修复/更新插件后重新启动"
  Write-Host ''
  if ($HiddenMode) { Show-DshNotice -Message "DeepSeek-Harness 启动失败：$lastWhy`n`n日志: $LogPath" -Icon 0x10 }
  return 1
}

function Invoke-DshLogTail {
  param([string]$RunId, [string]$LogPath, [string]$StatePath, [string]$Title = 'DSH 日志')
  Initialize-DshEncoding
  try { $Host.UI.RawUI.WindowTitle = $Title } catch { }

  Write-Host "DeepSeek-Harness 日志跟随 · $LogPath"
  Write-Host '（本标签页只读；服务在「DSH 服务」标签页运行，关闭窗口即停止服务）'
  Write-Host ''

  $snap = Get-DshLogSnapshot -Path $LogPath -MaxBytes 32768
  $rd = @{ Path = $LogPath; Pos = [int64]$snap.Pos; Pending = '' }
  if ($snap.Text -ne '') {
    $parts = $snap.Text -split "`r?`n"
    for ($i = 0; $i -lt $parts.Count; $i++) {
      if ($i -eq 0 -and [int64]$snap.Pos -gt 32768) { continue }   # 首行可能是截断的半个行
      if ($parts[$i].Trim() -ne '') { Write-Host $parts[$i] }
    }
    Write-Host ''
  }

  if (-not (Test-Path -LiteralPath $StatePath)) {
    Write-Host '未找到运行状态文件（服务可能由旧版本启动）。本标签页退出。'
    return
  }

  while ($true) {
    $st = Read-DshState -Path $StatePath
    if ($st) {
      if ($st.runId -and $st.runId -ne $RunId) { Write-Host ''; Write-Host '已被新的启动接管，本标签页退出。'; return }
      if ($st.status -eq 'stopped') { Write-Host ''; Write-Host '服务已停止，本标签页退出。'; return }
    }
    foreach ($l in (Read-NewLogLines $rd)) { if ($l.Trim() -ne '') { Write-Host $l } }
    Start-Sleep -Milliseconds 400
  }
}
