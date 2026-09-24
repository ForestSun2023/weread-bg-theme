# ============================================================================
# 微信读书脚本 · 交付检查（唯一入口）
# ----------------------------------------------------------------------------
# 一条命令跑完全部关卡，并往 工具/审查记录.md 追加一条记录。
#
#   1. 功能回归   工具/回归验证.ps1   —— 改了东西还能不能用（2 个模式快照）
#   2. 封号审查   工具/安全审查.ps1   —— 有没有引入封号风险（五类必须为 0）
#   3. 死代码     本脚本内联          —— 定义了却没人调用的函数（YAGNI）
#   4. 体积       本脚本内联          —— 与上次记录对比，防止悄悄膨胀
#   5. 像素验证   工具/像素验证.ps1   —— 15 种组合实拍，色值/走向/月亮位置对官方实测
#
# 用法：
#   pwsh -File "工具\交付检查.ps1"              # 全套
#   pwsh -File "工具\交付检查.ps1" -SkipRegression   # 只做静态检查（快）
#
# 退出码：0 = 全部通过；>0 = 未通过的关卡数
# ============================================================================
param([switch]$SkipRegression, [switch]$SkipPixel)

$Root       = Split-Path $PSScriptRoot -Parent
$ScriptPath = Join-Path $Root 'weread-bg-theme.user.js'
$AuditPs1   = Join-Path $PSScriptRoot '安全审查.ps1'
$RegressPs1 = Join-Path $PSScriptRoot '回归验证.ps1'
$LogPath    = Join-Path $PSScriptRoot '审查记录.md'
$PixelPs1   = Join-Path $PSScriptRoot '像素验证.ps1'

# 子脚本（回归 / 像素）要另起一个进程跑，因为它们内部会 exit。
# 用哪个解释器：优先 PowerShell 7（pwsh），没有就退回 Windows PowerShell 5.1。
# **不能写死 pwsh** —— 很多人只在 Windows 上用过 5.1，写死会让「一条命令跑完全部关卡」直接失败。
# 注意两个脚本都必须存成 **带 UTF-8 BOM** 的文件：5.1 对无 BOM 的 .ps1 会按 ANSI 代码页解码，
# 中文注释会变成乱码并直接报语法错误（这个坑本项目踩过，交付检查一度整个跑不起来）。
$ShellExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }

if (-not (Test-Path $ScriptPath)) { Write-Host "找不到脚本：$ScriptPath" -ForegroundColor Red; exit 1 }

$raw   = Get-Content $ScriptPath -Raw -Encoding UTF8
$ver   = if ($raw -match '@version\s+([\d.]+)') { $Matches[1] } else { '?' }
$bytes = (Get-Item $ScriptPath).Length
$failed = 0

Write-Host ""
Write-Host "################ 交付检查：weread-bg-theme.user.js  v$ver ################" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------- 1. 封号审查
Write-Host "【1/5】封号风险审查" -ForegroundColor Yellow
& $ShellExe -File $AuditPs1
$auditOk = ($LASTEXITCODE -eq 0)
if (-not $auditOk) { $failed++ }

# ---------------------------------------------------------------- 2. 功能回归
$regPass = 0; $regFail = 0; $regOk = $true
Write-Host "【2/5】功能回归" -ForegroundColor Yellow
if ($SkipRegression) {
  Write-Host "  (已跳过)" -ForegroundColor DarkGray
} else {
  $regOut = & $ShellExe -File $RegressPs1 2>&1
  $regOk  = ($LASTEXITCODE -eq 0)
  $regPass = ($regOut | Select-String -Pattern '^\s+PASS').Count
  $regFail = ($regOut | Select-String -Pattern '^\s+FAIL').Count
  $regOut | Select-String -Pattern 'FAIL|SUMMARY|结论' | ForEach-Object { Write-Host $_.Line }
  Write-Host ("  {0} 项通过 / {1} 项失败（2 个模式快照合计）" -f $regPass, $regFail)
  if (-not $regOk) { $failed++ }
}

# ---------------------------------------------------------------- 3. 死代码
# 判定：函数名在全文中只出现 1 次 = 只有定义、没有任何调用点。
# 这是启发式（名字出现在注释里也会算作"被引用"），但够用来兜住「写完忘了接上」。
Write-Host "【3/5】死代码检查" -ForegroundColor Yellow
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
  $failed++
}

# ---------------------------------------------------------------- 4. 体积
Write-Host "【4/5】体积" -ForegroundColor Yellow
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

# ---------------------------------------------------------------- 5. 像素验证
# 回归只断言「计算样式」，看不出渲染出来的观感 —— 上一版深色模式就是计算样式全绿、
# 观感却很差。这一关把 15 种组合真渲染成 1240x2772 截图，跟官方截图实测值逐格比。
$pxPass = 0; $pxFail = 0; $pxOk = $true
Write-Host "【5/5】像素验证" -ForegroundColor Yellow
if ($SkipPixel -or $SkipRegression) {
  Write-Host "  (已跳过)" -ForegroundColor DarkGray
} else {
  $pxOut  = & $ShellExe -File $PixelPs1 2>&1
  $pxOk   = ($LASTEXITCODE -eq 0)
  $pxPass = ($pxOut | Select-String -Pattern '^\s+PASS').Count
  $pxFail = ($pxOut | Select-String -Pattern '^\s+FAIL').Count
  $pxOut | Select-String -Pattern 'FAIL|结论' | ForEach-Object { Write-Host $_.Line }
  Write-Host ("  {0} 种组合通过 / {1} 种未达标（3 色 × 5 纹理）" -f $pxPass, $pxFail)
  if (-not $pxOk) { $failed++ }
}
# ---------------------------------------------------------------- 结论 + 记录
Write-Host ""
$verdict = if ($failed -eq 0) { '全部通过' } else { "$failed 项未通过" }
$color = if ($failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "################ 结论：$verdict ################" -ForegroundColor $color
Write-Host ""

if (-not (Test-Path $LogPath)) {
  @(
    '# 审查记录',
    '',
    '由 `工具/交付检查.ps1` 自动追加。**每一版交付前都必须有一条记录。**',
    '',
    '| 版本 | 时间 | 字节 | 功能回归 | 像素验证 | 封号审查 | 死代码 |',
    '|---|---|---|---|---|---|---|'
  ) | Set-Content $LogPath -Encoding UTF8
}
$regCell = if ($SkipRegression) { '跳过' } else { "$regPass 通过 / $regFail 失败" }
$row = '| v{0} | {1} | {2:N0} | {3} | {4} | {5} | {6} |' -f `
  $ver, (Get-Date -Format 'yyyy-MM-dd HH:mm'), $bytes, $regCell,
  $(if ($SkipPixel -or $SkipRegression) { '跳过' } else { "$pxPass 通过 / $pxFail 未达标" }),
  $(if ($auditOk) { '通过' } else { '**未通过**' }),
  $(if ($deadOk) { '通过' } else { '**' + ($dead -join ', ') + '**' })
Add-Content $LogPath -Value $row -Encoding UTF8
Write-Host "已写入审查记录：$LogPath" -ForegroundColor DarkGray
Write-Host ""

exit $failed
