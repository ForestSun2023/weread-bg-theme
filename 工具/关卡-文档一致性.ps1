# ============================================================================
# 交付检查 · 文档一致性
# ----------------------------------------------------------------------------
# 独立关卡脚本：可单独运行，也由 工具/交付检查.ps1 汇总调用。
#   pwsh -File "工具/关卡-文档一致性.ps1"            # 只跑这一关
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
Write-Host "===== 关卡：文档一致性  (v$ver, $('{0:N0}' -f $bytes) 字节) =====" -ForegroundColor Cyan
# ---------------------------------------------------------------- 4. 文档一致性
# 为什么需要这一关：**文档里写的取值和代码不一致，读者照着敲会直接报错**，而且这种错
# 不会让任何测试变红 —— 代码是对的、文档是错的，谁都不会发现。
# 本项目真发生过：GreasyFork 附加信息里把 wrbg.backgrounds 的最后一个 id 写成 'sky'，实际是 'moon'。
# 设计原则：**找不到断言目标也算失败**。否则文档一改结构，这一关就会「静默全绿」什么都不查
#（这个教训来自回归验证：曾经 4 次「全绿」其实一条断言都没跑）。
$docIssues = @()

# 4.1 先从脚本里解析出「真相」：COLORS / BACKGROUNDS 的 id
$colorsBlock = [regex]::Match($raw, '(?s)const COLORS = \[(.*?)\n  \];').Groups[1].Value
$bgBlock     = [regex]::Match($raw, '(?s)const BACKGROUNDS = \[(.*?)\n  \];').Groups[1].Value
$realColors  = @([regex]::Matches($colorsBlock, "id: '([a-z]+)'") | ForEach-Object { $_.Groups[1].Value })
$realBgs     = @([regex]::Matches($bgBlock, "id: '([a-z]+)'") | ForEach-Object { $_.Groups[1].Value })
$realColorIds = $realColors -join ','
$realBgIds    = $realBgs -join ','
if ($realColors.Count -lt 2) { $docIssues += "解析不出 COLORS 的 id（拿到 $($realColors.Count) 个）—— 关卡用的正则可能过期了" }
if ($realBgs.Count -le 1)    { $docIssues += "解析不出 BACKGROUNDS 的 id（拿到 $($realBgs.Count) 个）—— 关卡用的正则可能过期了" }

# 4.2 版本号三处对齐：脚本 @version = README 版本徽标 = CHANGELOG 最新条目 = 使用说明标注
$readmePath = Join-Path $Root 'README.md'
$readme = if (Test-Path $readmePath) { Get-Content $readmePath -Raw -Encoding UTF8 } else { '' }
if (-not $readme) { $docIssues += "README.md 不存在" }
$m = [regex]::Match($readme, 'badge/版本-([\d.]+)-')
if (-not $m.Success) { $docIssues += "README.md 里找不到版本徽标（形如 badge/版本-x.y.z-）" }
elseif ($m.Groups[1].Value -ne $ver) { $docIssues += "README.md 版本徽标是 $($m.Groups[1].Value)，脚本 @version 是 $ver" }

$chgPath = Join-Path $Root 'CHANGELOG.md'
if (Test-Path $chgPath) {
  $m = [regex]::Match((Get-Content $chgPath -Raw -Encoding UTF8), '(?m)^## v([\d.]+)')
  if (-not $m.Success) { $docIssues += "CHANGELOG.md 里找不到 '## vX.Y.Z' 版本标题" }
  elseif ($m.Groups[1].Value -ne $ver) { $docIssues += "CHANGELOG.md 最新版本是 $($m.Groups[1].Value)，脚本 @version 是 $ver" }
} else { $docIssues += "CHANGELOG.md 不存在" }

$usagePath = Join-Path $Root '使用说明.md'
if (Test-Path $usagePath) {
  $m = [regex]::Match((Get-Content $usagePath -Raw -Encoding UTF8), '\*\*(v[\d.]+)\*\*')
  if (-not $m.Success) { $docIssues += "使用说明.md 里找不到 **(vX.Y.Z)** 版本标注" }
  elseif ($m.Groups[1].Value -ne "v$ver") { $docIssues += "使用说明.md 标注的是 $($m.Groups[1].Value)，脚本是 v$ver" }
} else { $docIssues += "使用说明.md 不存在" }

# 4.3 各文档声称的 wrbg.colors / wrbg.backgrounds 取值
foreach ($doc in @('README.md', '发布/GreasyFork-附加信息.md')) {
  $p = Join-Path $Root $doc
  # ⚠️ 文档不存在时**不能直接 continue** —— 那会让这一关「静默少查几项」却仍然报通过。
  # 本项目吃过这个亏：回归验证曾经连续 4 次输出「0 通过 / 0 失败」看着像通过，
  # 其实是一条断言都没跑出来。查不到目标 = 失败。
  if (-not (Test-Path $p)) { $docIssues += "$doc 不存在 —— 这一关的覆盖范围变小了，不能算通过"; continue }
  $t = Get-Content $p -Raw -Encoding UTF8
  foreach ($pair in @(@('colors', $realColorIds), @('backgrounds', $realBgIds))) {
    $key = $pair[0]; $real = $pair[1]
    $mm = [regex]::Match($t, "wrbg\.$key\s+//\s*\[([^\]]+)\]")
    if (-not $mm.Success) { $docIssues += "$doc 里找不到 wrbg.$key 的取值行，无法核对"; continue }
    $claimed = ($mm.Groups[1].Value -replace "['\s]", '')
    if ($claimed -ne $real) { $docIssues += "$doc 的 wrbg.$key 写的是 [$claimed]，脚本实际是 [$real]" }
  }
}

# 4.4 README 里引用的颜色必须都在脚本里存在（防止色卡表过时）
foreach ($h in (@([regex]::Matches($readme, '#[0-9a-fA-F]{6}') | ForEach-Object { $_.Value.ToLower() }) | Sort-Object -Unique)) {
  if ($raw.ToLower() -notmatch [regex]::Escape($h)) { $docIssues += "README.md 里的颜色 $h 在脚本里找不到" }
}

# 4.5 GreasyFork 附加信息不能有相对链接
#   它的标记白名单只允许 https 图片，而且那个页面不在仓库上下文里 —— 相对路径必然失效。
$gfyPath = Join-Path $Root '发布/GreasyFork-附加信息.md'
if (Test-Path $gfyPath) {
  $gfy = Get-Content $gfyPath -Raw -Encoding UTF8
  $relCount = ([regex]::Matches($gfy, '\]\((?!https?:)[^)]+\)')).Count
  if ($relCount -gt 0) { $docIssues += "发布\GreasyFork-附加信息.md 里有 $relCount 处相对链接（GreasyFork 上会失效）" }
}

$docOk = ($docIssues.Count -eq 0)
if ($docOk) {
  Write-Host ("  [ 通过 ] 版本号 4 处对齐（脚本/README徽标/CHANGELOG/使用说明）；" +
              "文档声称的 colors=[{0}]、backgrounds=[{1}] 与代码一致；README 颜色均在脚本内" -f $realColorIds, $realBgIds) -ForegroundColor Green
} else {
  $docIssues | ForEach-Object { Write-Host "  [ 失败 ] $_" -ForegroundColor Red }
}

$issues = if ($docOk) { 0 } else { [Math]::Max(1, $docIssues.Count) }
Write-Host "SUMMARY issues=$issues"
exit $issues
