<#
  tail-log.ps1 — 「DSH 日志」标签页入口
  =====================================
  由 DeepSeek-Harness.ps1 start 在同一个 Windows Terminal 命名窗口里拉起（Tab2）。
  只读跟随 logs\web.log；当服务停止或本次 runId 被新的启动接管时自动退出，
  从而让终端窗口在服务结束后自行关闭。
  兼容 Windows PowerShell 5.1；本文件 UTF-8 with BOM。
#>
[CmdletBinding()]
param(
  [string]$RunId = '',
  [string]$LogPath = '',
  [string]$StatePath = '',
  [string]$Title = 'DSH 日志'
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\common.ps1')
. (Join-Path $PSScriptRoot 'lib\service.ps1')

if (-not $LogPath) { $LogPath = Get-DshLogPath }
if (-not $StatePath) { $StatePath = Get-DshStatePath }

Invoke-DshLogTail -RunId $RunId -LogPath $LogPath -StatePath $StatePath -Title $Title
exit 0
