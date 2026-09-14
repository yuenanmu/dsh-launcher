<#
  run-server.ps1 — 兼容入口（保留旧调用方式）
  ===========================================
  新架构下服务由 DeepSeek-Harness.ps1 start 在 Windows Terminal 的
  「DSH 服务」标签页里前台运行；本文件等价于:

      DeepSeek-Harness.ps1 serve

  之所以保留: 老快捷方式、老文档、以及任何手工调用 run-server.ps1 的地方仍能用。
  兼容 Windows PowerShell 5.1；本文件 UTF-8 with BOM。
#>
[CmdletBinding()]
param(
  [string]$RunId = '',
  [int]$Port = 0,
  [string]$LogPath = '',
  [string]$StatePath = '',
  [switch]$SafeMode
)

$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'DeepSeek-Harness.ps1') serve -RunId $RunId -Port $Port -LogPath $LogPath -StatePath $StatePath -SafeMode:$SafeMode
exit $LASTEXITCODE
