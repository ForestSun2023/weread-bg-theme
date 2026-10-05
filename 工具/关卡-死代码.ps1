# ============================================================================
# 交付检查 · 死代码
# ----------------------------------------------------------------------------
# 独立关卡脚本：可单独运行，也由 工具/交付检查.ps1 汇总调用。
#   pwsh -File "工具/关卡-死代码.ps1"            # 只跑这一关
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
Write-Host "===== 关卡：死代码  (v$ver, $('{0:N0}' -f $bytes) 字节) =====" -ForegroundColor Cyan
# ---------------------------------------------------------------- 6. 死代码
# 判定：函数名在全文中只出现 1 次 = 只有定义、没有任何调用点。
# 这是启发式（名字出现在注释里也会算作"被引用"），但够用来兜住「写完忘了接上」。
$names = [regex]::Matches($raw, 'function ([A-Za-z_][A-Za-z0-9_]*)') |
  ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
$dead = @()
foreach ($n in $names) {
  if (([regex]::Matches($raw, '\b' + [regex]::Escape($n) + '\b')).Count -le 1) { $dead += $n }
}
$deadOk = ($dead.Count -eq 0)
if ($deadOk) {
  Write-Host ("  [ 通过 ] {0} 个函数全部有调用点" -f $names.Count) -ForegroundColor Green
} else {
  Write-Host ("  [ 失败 ] 定义了但没人调用：{0}" -f ($dead -join ', ')) -ForegroundColor Red
}

$issues = if ($deadOk) { 0 } else { [Math]::Max(1, $dead.Count) }
Write-Host "SUMMARY issues=$issues"
exit $issues
