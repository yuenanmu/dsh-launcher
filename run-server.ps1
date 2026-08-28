<#
  run-server.ps1 — DeepSeek-Harness 后台服务进程（由 DeepSeek-Harness.ps1 start 以隐藏窗口方式启动）
  - 从环境变量 DSH_LAUNCHER_CMD 读取启动命令（由主脚本传入），未设置时自行解析
  - 输出带时间戳追加到同目录 logs\web.log
  - 阻塞常驻：dsh 进程退出时本脚本随即退出（"关闭服务即停"）
#>
$ErrorActionPreference = 'Continue'
$AppDir = $PSScriptRoot
$logDir = Join-Path $AppDir 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$log = Join-Path $logDir 'web.log'

# ── 解析启动命令 ──────────────────────────────────────────────
$cmd = $env:DSH_LAUNCHER_CMD
if (-not $cmd) {
  # 兜底：与主脚本同规则解析（config.json > 全局 dsh > npx）
  $cfg = @{}
  $cfgPath = Join-Path $AppDir 'config.json'
  if (Test-Path $cfgPath) {
    try { $j = Get-Content $cfgPath -Raw | ConvertFrom-Json; if ($j) { foreach ($p in $j.PSObject.Properties) { $cfg[$p.Name] = $p.Value } } } catch {}
  }
  $mode = $cfg['dshMode']
  if (-not $mode -or $mode -eq '') { $mode = 'auto' }
  $port = 3080
  try { if ($cfg['port'] -ne $null -and $cfg['port'] -ne '') { $port = [int]$cfg['port'] } } catch {}
  $portFlag = "--port $port"
  $g = Get-Command dsh -ErrorAction SilentlyContinue
  if ($mode -eq 'global' -and $g) { $cmd = "dsh web --no-open $portFlag" }
  elseif ($mode -eq 'npx') { $cmd = "npx -y @deepseek-ai/dsh web --no-open $portFlag" }
  elseif ($g) { $cmd = "dsh web --no-open $portFlag" }
  else { $cmd = "npx -y @deepseek-ai/dsh web --no-open $portFlag" }
}

# ── 执行（拆分为可执行文件 + 参数）──────────────────────────
$parts = $cmd -split ' ', 2
$exe = $parts[0]
$exeArgs = @()
if ($parts.Count -gt 1) { $exeArgs = $parts[1].Split(' ') }

"==== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') 启动: $cmd ====" |
  Out-File -Append -Encoding utf8 $log

try {
  & $exe @exeArgs 2>&1 | ForEach-Object {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $_"
  } | Out-File -Append -Encoding utf8 $log
}
catch {
  "==== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') 服务异常: $($_.Exception.Message) ====" |
    Out-File -Append -Encoding utf8 $log
}
