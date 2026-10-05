# ============================================================================
# 微信读书脚本 · 交付检查（唯一入口）
# ----------------------------------------------------------------------------
# 一条命令跑完全部七道关卡，并往 工具/审查记录.md 追加一条记录。
#
#   1. 封号审查     工具/安全审查.ps1
#   2. 功能回归     工具/回归验证.ps1
#   3. 像素验证     工具/像素验证.ps1
#   4. 文档一致性   工具/关卡-文档一致性.ps1
#   5. 仓库卫生     工具/关卡-仓库卫生.ps1
#   6. 死代码       工具/关卡-死代码.ps1
#   7. 体积         工具/关卡-体积.ps1
#
# 每一关都是**独立脚本**，可以单独跑：
#   pwsh -File "工具/关卡-仓库卫生.ps1"
# 拆开有两个理由：
#   ① 本地排查不必跑全套；
#   ② CI 上可以一关一步 —— **Actions 的原始日志要登录才能取，但 step 列表是公开的**，
#      拆开就能不登录也看出是哪一关挂了（这个教训来自接入 CI 那次排查）。
#
# 用法：
#   pwsh -File "工具/交付检查.ps1"                    # 全套
#   pwsh -File "工具/交付检查.ps1" -SkipRegression    # 跳过要起浏览器的两关（快，CI 用这个）
#
# 退出码：0 = 全部通过；>0 = 未通过的关卡数
# ============================================================================
param([switch]$SkipRegression, [switch]$SkipPixel)

# ⚠️ 显式声明错误偏好，**不要依赖调用方**：
# GitHub Actions 的 pwsh shell 会在脚本前注入 $ErrorActionPreference = 'stop'，
# 而本脚本是按 Continue 写的（-ErrorAction SilentlyContinue + 查 $LASTEXITCODE）。
# 不写这一行就会出现「本地全过、CI 挂」而且挂得莫名其妙 —— 踩过。详见 设计思路.md 第九节。
$ErrorActionPreference = 'Continue'

$Root       = Split-Path $PSScriptRoot -Parent
$ScriptPath = Join-Path $Root 'weread-bg-theme.user.js'
$AuditPs1   = Join-Path $PSScriptRoot '安全审查.ps1'
$RegressPs1 = Join-Path $PSScriptRoot '回归验证.ps1'
$PixelPs1   = Join-Path $PSScriptRoot '像素验证.ps1'
$DocPs1     = Join-Path $PSScriptRoot '关卡-文档一致性.ps1'
$HygPs1     = Join-Path $PSScriptRoot '关卡-仓库卫生.ps1'
$DeadPs1    = Join-Path $PSScriptRoot '关卡-死代码.ps1'
$SizePs1    = Join-Path $PSScriptRoot '关卡-体积.ps1'
$LogPath    = Join-Path $PSScriptRoot '审查记录.md'

# 子关卡要另起进程跑（它们内部会 exit）。
# 用哪个解释器：优先 PowerShell 7（pwsh），没有就退回 Windows PowerShell 5.1 ——
# **不能写死 pwsh**，很多人只在 Windows 上用过 5.1。
$ShellExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }

if (-not (Test-Path $ScriptPath)) { Write-Host "找不到脚本：$ScriptPath" -ForegroundColor Red; exit 1 }

$raw   = Get-Content $ScriptPath -Raw -Encoding UTF8
$ver   = if ($raw -match '@version\s+([\d.]+)') { $Matches[1] } else { '?' }
$bytes = (Get-Item $ScriptPath).Length
$failed = 0

# 跑一个「关卡-*.ps1」，解析它最后一行 SUMMARY issues=N 作为问题数。
# **解析不到就算失败**（查不到目标也算失败）：否则关卡脚本一改输出格式，
# 父脚本就会静默把它当成通过 —— 而静默的绿比红危险得多。
function Invoke-Gate {
  param([string]$Ps1, [int]$Index, [string]$Title)
  Write-Host "【$Index/7】$Title" -ForegroundColor Yellow
  $out  = & $ShellExe -File $Ps1 2>&1
  $code = $LASTEXITCODE
  # 关卡脚本自己会打印 通过/失败 明细，这里原样回显（去掉它自己那行标题）
  $out | Where-Object { $_ -notmatch '^===== 关卡：' } | ForEach-Object { Write-Host $_ }
  $m = [regex]::Match(($out | Out-String), 'SUMMARY issues=(\d+)')
  if (-not $m.Success) {
    Write-Host "  [ 失败 ] 关卡没有输出 SUMMARY issues=N —— 无法判定，按失败处理" -ForegroundColor Red
    $script:failed++
    return -1
  }
  $issues = [int]$m.Groups[1].Value
  # 退出码与 SUMMARY 矛盾时以失败为准
  if ($code -ne 0 -and $issues -eq 0) { $issues = 1 }
  if ($issues -gt 0) { $script:failed++ }
  return $issues
}

Write-Host ""
Write-Host "################ 交付检查：weread-bg-theme.user.js  v$ver ################" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------- 1. 封号审查
# 封号打击的是「内容获取」和「账号行为」，不是本地改样式。这一关是发布前的硬门槛。
Write-Host "【1/7】封号风险审查" -ForegroundColor Yellow
& $ShellExe -File $AuditPs1
$auditOk = ($LASTEXITCODE -eq 0)
if (-not $auditOk) { $failed++ }

# ---------------------------------------------------------------- 2. 功能回归
$regPass = 0; $regFail = 0; $regOk = $true
Write-Host "【2/7】功能回归" -ForegroundColor Yellow
if ($SkipRegression) {
  Write-Host "  (已跳过)" -ForegroundColor DarkGray
} else {
  $regOut = & $ShellExe -File $RegressPs1 2>&1
  $regOk  = ($LASTEXITCODE -eq 0)
  $regPass = ($regOut | Select-String -Pattern '^\s+PASS').Count
  $regFail = ($regOut | Select-String -Pattern '^\s+FAIL').Count
  $regOut | Select-String -Pattern 'FAIL|SUMMARY|结论|快照' | ForEach-Object { Write-Host $_.Line }
  Write-Host ("  {0} 项通过 / {1} 项失败（2 个模式快照合计）" -f $regPass, $regFail)
  # 「0 通过 0 失败」= 断言一条都没跑出来（harness 崩了 / 报告没回传），绝不能算通过
  if ($regPass -eq 0) { Write-Host "  [ 失败 ] 一条断言都没跑出来 —— 测试链路本身坏了" -ForegroundColor Red; $failed++ }
  elseif (-not $regOk) { $failed++ }
}

# ---------------------------------------------------------------- 3. 像素验证
# 回归只断言「计算样式」，看不出渲染出来的观感 —— v1.8.0 就是计算样式全绿、观感却很差。
$pxPass = 0; $pxFail = 0; $pxOk = $true
Write-Host "【3/7】像素验证" -ForegroundColor Yellow
if ($SkipPixel -or $SkipRegression) {
  Write-Host "  (已跳过)" -ForegroundColor DarkGray
} else {
  $pxOut  = & $ShellExe -File $PixelPs1 2>&1
  $pxOk   = ($LASTEXITCODE -eq 0)
  $pxPass = ($pxOut | Select-String -Pattern '^\s+PASS').Count
  $pxFail = ($pxOut | Select-String -Pattern '^\s+FAIL').Count
  $pxOut | Select-String -Pattern 'FAIL|结论|快照' | ForEach-Object { Write-Host $_.Line }
  Write-Host ("  {0} 项通过 / {1} 项未达标（15 格组合 + 一条覆盖自检）" -f $pxPass, $pxFail)
  if ($pxPass -eq 0) { Write-Host "  [ 失败 ] 一格都没渲染出来" -ForegroundColor Red; $failed++ }
  elseif (-not $pxOk) { $failed++ }
}

# ---------------------------------------------------------------- 4-7. 独立关卡
$docIssues  = Invoke-Gate $DocPs1  4 '文档一致性'
$hygIssues  = Invoke-Gate $HygPs1  5 '仓库卫生'
$deadIssues = Invoke-Gate $DeadPs1 6 '死代码检查'
$null       = Invoke-Gate $SizePs1 7 '体积'

# ---------------------------------------------------------------- 结论 + 记录
Write-Host ""
$verdict = if ($failed -eq 0) { '全部通过' } else { "$failed 项未通过" }
$color = if ($failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "################ 结论：$verdict ################" -ForegroundColor $color
Write-Host ""

# 表头会随关卡增减变化：发现旧表头就替换，并**把历史行也重排对齐**。
# ⚠️ 只换表头是不够的 —— 历史行的列数变过（6 → 7 → 9），不重排会出现
# 「老行里的『封号审查=通过』显示在新表的『像素验证』列下面」。
# **审查记录被误读，比没有记录更糟。** 两种老布局按列数识别、补空位对齐：
#   6 列：版本|时间|字节|功能回归|封号审查|死代码
#   7 列：版本|时间|字节|功能回归|像素验证|封号审查|死代码
#   9 列：当前布局（版本|时间|字节|功能回归|像素验证|文档一致|仓库卫生|封号审查|死代码）
$wantedHeader = '| 版本 | 时间 | 字节 | 功能回归 | 像素验证 | 文档一致 | 仓库卫生 | 封号审查 | 死代码 |'
$wantedSep    = '|---|---|---|---|---|---|---|---|---|'
if (-not (Test-Path $LogPath)) {
  @(
    '# 审查记录',
    '',
    '由 `工具/交付检查.ps1` 自动追加。**每一版交付前都必须有一条记录。**',
    '',
    $wantedHeader,
    $wantedSep
  ) | Set-Content $LogPath -Encoding UTF8
} else {
  # 迁移必须是**幂等 + 自愈**的：不能挂在「表头变了」这个条件上。
  # 第一版就是这么写的，结果表头已经被替换过一次，条件再也不成立，错位的历史行永远修不上。
  # 现在改成无论表头如何，每一行都按列数检查一遍。
  $logLines = @(Get-Content $LogPath -Encoding UTF8)
  $changed = $false
  $migrated = 0

  # ① 表头
  $hi = -1
  for ($k = 0; $k -lt $logLines.Count; $k++) { if ($logLines[$k] -match '^\|\s*版本\s*\|') { $hi = $k; break } }
  if ($hi -ge 0 -and $logLines[$hi] -ne $wantedHeader) {
    $logLines[$hi] = $wantedHeader
    if (($hi + 1) -lt $logLines.Count -and $logLines[$hi + 1] -match '^\|-') { $logLines[$hi + 1] = $wantedSep }
    $changed = $true
  }

  # ② 历史行：列数不对就补空位对齐
  for ($k = 0; $k -lt $logLines.Count; $k++) {
    if ($logLines[$k] -notmatch '^\|\s*v[\d.]+\s*\|') { continue }
    $cells = @(($logLines[$k].Trim('|') -split '\|') | ForEach-Object { $_.Trim() })
    if ($cells.Count -eq 6) {
      $logLines[$k] = '| ' + (($cells[0..3] + @('', '', '') + $cells[4..5]) -join ' | ') + ' |'
      $migrated++
    } elseif ($cells.Count -eq 7) {
      $logLines[$k] = '| ' + (($cells[0..4] + @('', '') + $cells[5..6]) -join ' | ') + ' |'
      $migrated++
    }
  }
  if ($migrated) { $changed = $true }

  if ($changed) {
    Set-Content $LogPath -Value $logLines -Encoding UTF8
    if ($migrated) { Write-Host "  (审查记录已对齐：$migrated 行历史数据按新列序补位)" -ForegroundColor DarkGray }
  }
}
$regCell = if ($SkipRegression) { '跳过' } else { "$regPass 通过 / $regFail 失败" }
$pxCell  = if ($SkipPixel -or $SkipRegression) { '跳过' } else { "$pxPass 通过 / $pxFail 未达标" }
$row = '| v{0} | {1} | {2:N0} | {3} | {4} | {5} | {6} | {7} | {8} |' -f `
  $ver, (Get-Date -Format 'yyyy-MM-dd HH:mm'), $bytes,
  $regCell, $pxCell,
  $(if ($docIssues -eq 0) { '通过' } else { '**' + [Math]::Max(1, $docIssues) + ' 项**' }),
  $(if ($hygIssues -eq 0) { '通过' } else { '**' + [Math]::Max(1, $hygIssues) + ' 项**' }),
  $(if ($auditOk) { '通过' } else { '**未通过**' }),
  $(if ($deadIssues -eq 0) { '通过' } else { '**' + [Math]::Max(1, $deadIssues) + ' 项**' })
Add-Content $LogPath -Value $row -Encoding UTF8
Write-Host "已写入审查记录：$LogPath" -ForegroundColor DarkGray
Write-Host ""

exit $failed
