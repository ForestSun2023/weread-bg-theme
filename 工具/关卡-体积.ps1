# ============================================================================
# 交付检查 · 体积
# ----------------------------------------------------------------------------
# 独立关卡脚本：可单独运行，也由 工具/交付检查.ps1 汇总调用。
#   pwsh -File "工具/关卡-体积.ps1"            # 只跑这一关
#
# 退出码：0 = 通过；>0 = 问题数（父脚本按退出码记入 审查记录.md）
# 输出约定：最后一行打印 SUMMARY issues=N，供父脚本解析问题数。
# ============================================================================
param([string]$Root = (Split-Path $PSScriptRoot -Parent))

# ⚠️ 显式声明错误偏好，不要依赖调用方：
# GitHub Actions 的 pwsh shell 会在脚本前注入 $ErrorActionPreference = 'stop'，
# 而本脚本是按 Continue 写的（-ErrorAction SilentlyContinue + 查 $LASTEXITCODE）。
$ErrorActionPreference = 'Continue'

$ScriptPath = Join-Path $Root 'weread-bg-theme.user.js'
$LogPath    = Join-Path $PSScriptRoot '审查记录.md'
if (-not (Test-Path $ScriptPath)) { Write-Host "找不到脚本：$ScriptPath" -ForegroundColor Red; exit 1 }
$raw   = Get-Content $ScriptPath -Raw -Encoding UTF8
$ver   = if ($raw -match '@version\s+([\d.]+)') { $Matches[1] } else { '?' }
$bytes = (Get-Item $ScriptPath).Length

Write-Host ""
Write-Host "===== 关卡：体积  (v$ver, $('{0:N0}' -f $bytes) 字节) =====" -ForegroundColor Cyan
# ---------------------------------------------------------------- 7. 体积
$prev = $null
if (Test-Path $LogPath) {
  $lastRow = Get-Content $LogPath -Encoding UTF8 |
    Where-Object { $_ -match '^\|\s*v[\d.]+\s*\|' } | Select-Object -Last 1
  if ($lastRow -and $lastRow -match '\|\s*([\d,]+)\s*\|') { $prev = [int]($Matches[1] -replace ',', '') }
}
if ($prev) {
  $delta = $bytes - $prev
  $sign = if ($delta -ge 0) { '+' } else { '' }
  Write-Host ("  {0:N0} 字节（上次 {1:N0}，{2}{3:N0}）" -f $bytes, $prev, $sign, $delta)
} else {
  Write-Host ("  {0:N0} 字节（无历史记录）" -f $bytes)
}

Write-Host "SUMMARY issues=0"
exit 0
