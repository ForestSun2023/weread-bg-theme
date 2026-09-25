# ============================================================================
# 微信读书脚本 · 交付检查（唯一入口）
# ----------------------------------------------------------------------------
# 一条命令跑完全部关卡，并往 工具/审查记录.md 追加一条记录。
#
#   1. 封号审查     工具/安全审查.ps1   —— 有没有引入封号风险（五类必须为 0）
#   2. 功能回归     工具/回归验证.ps1   —— 改了东西还能不能用（2 个模式快照）
#   3. 像素验证     工具/像素验证.ps1   —— 15 种组合实拍，色值/走向/月亮位置对官方实测
#   4. 文档一致性   本脚本内联          —— 文档里写的取值/版本号与代码是否一致
#   5. 仓库卫生     本脚本内联          —— BOM / 敏感文件是否被忽略 / 大文件 / 体积上限
#   6. 死代码       本脚本内联          —— 定义了却没人调用的函数（YAGNI）
#   7. 体积         本脚本内联          —— 与上次记录对比，防止悄悄膨胀
#
# 前 3 关要起浏览器（慢），后 4 关是纯静态（快）。
#
# 用法：
#   pwsh -File "工具\交付检查.ps1"                    # 全套
#   pwsh -File "工具\交付检查.ps1" -SkipRegression    # 跳过要起浏览器的关卡（快）
#
# 退出码：0 = 全部通过；>0 = 未通过的关卡数
# ============================================================================
param([switch]$SkipRegression, [switch]$SkipPixel)
# ⚠️ 显式声明错误偏好，**不要依赖调用方**。
# GitHub Actions 的 pwsh shell 会在脚本前注入 $ErrorActionPreference = 'stop'，
# 而这个脚本是按 Continue 写的（用 -ErrorAction SilentlyContinue + 查  处理错误）。
# 结果就是经典的「本地全过、CI 挂」，而且挂得莫名其妙 —— 所以这里把它钉死。
$ErrorActionPreference = 'Continue'

$Root       = Split-Path $PSScriptRoot -Parent
$ScriptPath = Join-Path $Root 'weread-bg-theme.user.js'
$AuditPs1   = Join-Path $PSScriptRoot '安全审查.ps1'
$RegressPs1 = Join-Path $PSScriptRoot '回归验证.ps1'
$PixelPs1   = Join-Path $PSScriptRoot '像素验证.ps1'
$LogPath    = Join-Path $PSScriptRoot '审查记录.md'

# 子脚本（回归 / 像素）要另起一个进程跑，因为它们内部会 exit。
# 用哪个解释器：优先 PowerShell 7（pwsh），没有就退回 Windows PowerShell 5.1。
# **不能写死 pwsh** —— 很多人只在 Windows 上用过 5.1，写死会让「一条命令跑完全部关卡」直接失败。
# 注意这几个脚本都必须存成 **带 UTF-8 BOM** 的文件：5.1 对无 BOM 的 .ps1 会按 ANSI 代码页解码，
# 中文注释会变成乱码并直接报语法错误（这个坑本项目踩过，交付检查一度整个跑不起来）。
# 这条规矩现在由第 5 关「仓库卫生」自动守着。
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
  $regOut | Select-String -Pattern 'FAIL|SUMMARY|结论' | ForEach-Object { Write-Host $_.Line }
  Write-Host ("  {0} 项通过 / {1} 项失败（2 个模式快照合计）" -f $regPass, $regFail)
  # 「0 通过 0 失败」= 断言一条都没跑出来（harness 崩了 / 报告没回传），绝不能算通过
  if ($regPass -eq 0) { Write-Host "  [ 失败 ] 一条断言都没跑出来 —— 测试链路本身坏了" -ForegroundColor Red; $failed++ }
  elseif (-not $regOk) { $failed++ }
}

# ---------------------------------------------------------------- 3. 像素验证
# 回归只断言「计算样式」，看不出渲染出来的观感 —— v1.8.0 就是计算样式全绿、观感却很差。
# 这一关把 15 种组合真渲染成截图，跟官方截图实测值逐格比。
$pxPass = 0; $pxFail = 0; $pxOk = $true
Write-Host "【3/7】像素验证" -ForegroundColor Yellow
if ($SkipPixel -or $SkipRegression) {
  Write-Host "  (已跳过)" -ForegroundColor DarkGray
} else {
  $pxOut  = & $ShellExe -File $PixelPs1 2>&1
  $pxOk   = ($LASTEXITCODE -eq 0)
  $pxPass = ($pxOut | Select-String -Pattern '^\s+PASS').Count
  $pxFail = ($pxOut | Select-String -Pattern '^\s+FAIL').Count
  $pxOut | Select-String -Pattern 'FAIL|结论' | ForEach-Object { Write-Host $_.Line }
  Write-Host ("  {0} 项通过 / {1} 项未达标（15 格组合 + 一条覆盖自检）" -f $pxPass, $pxFail)
  if ($pxPass -eq 0) { Write-Host "  [ 失败 ] 一格都没渲染出来" -ForegroundColor Red; $failed++ }
  elseif (-not $pxOk) { $failed++ }
}

# ---------------------------------------------------------------- 4. 文档一致性
# 为什么需要这一关：**文档里写的取值和代码不一致，读者照着敲会直接报错**，而且这种错
# 不会让任何测试变红 —— 代码是对的、文档是错的，谁都不会发现。
# 本项目真发生过：GreasyFork 附加信息里把 wrbg.backgrounds 的最后一个 id 写成 'sky'，实际是 'moon'。
# 设计原则：**找不到断言目标也算失败**。否则文档一改结构，这一关就会「静默全绿」什么都不查
#（这个教训来自回归验证：曾经 4 次「全绿」其实一条断言都没跑）。
Write-Host "【4/7】文档一致性" -ForegroundColor Yellow
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
  $failed++
}

# ---------------------------------------------------------------- 5. 仓库卫生
# 守两件事：**别把不该进仓库的东西提交上去**、**别让工具在本机跑不起来**。
# 每一条都对应一次真实踩坑：
#   · HAR 里有 20 处 Cookie（等于登录态）
#   · SingleFile 快照里有整章小说正文
#   · .ps1 丢了 UTF-8 BOM → 5.1 按 ANSI 解码，中文注释乱码、直接语法报错
#   · 官方安装包 136 MB、官方截图 28.8 MB
Write-Host "【5/7】仓库卫生" -ForegroundColor Yellow
$hygiene = @()
$gitExe = Get-Command git -ErrorAction SilentlyContinue
$isRepo = (Test-Path (Join-Path $Root '.git')) -and $gitExe

# 5.1 所有 PowerShell 脚本必须有 UTF-8 BOM
Get-ChildItem (Join-Path $Root '工具') -Filter *.ps1 -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
  $b = [IO.File]::ReadAllBytes($_.FullName)
  if ($b.Length -lt 3 -or $b[0] -ne 0xEF -or $b[1] -ne 0xBB -or $b[2] -ne 0xBF) {
    $hygiene += "工具\$($_.Name) 缺 UTF-8 BOM（Windows PowerShell 5.1 会按 ANSI 解码，中文注释直接语法错）"
  }
}

# 5.2 敏感文件 / 大件**存在时**必须被 .gitignore 挡住
if ($isRepo) {
  $suspects = @()
  foreach ($pat in @('*.har', '*.cookies.txt', '.env', 'base.apk*', '*.apk', '*.html')) {
    $suspects += Get-ChildItem $Root -Filter $pat -Force -File -ErrorAction SilentlyContinue
  }
  foreach ($d in @('_apk', '官方背景截图')) {
    $p = Join-Path $Root $d
    if (Test-Path $p) { $suspects += Get-Item $p }
  }
  foreach ($s in $suspects) {
    & git check-ignore -q $s.FullName 2>$null
    if ($LASTEXITCODE -ne 0) { $hygiene += "$($s.Name) 没有被 .gitignore 挡住 —— 它可能会被提交上去" }
  }
  # 5.3 已跟踪文件里的超大二进制（截图目录除外）
  # ⚠️ 必须 `-c core.quotePath=false`：git 默认会把非 ASCII 路径转义成 "\345\267\245..."
  #    那种带引号+八进制的字符串 Test-Path 必然为假 → 中文名的文件被**静默跳过**。
  #    实测：22 个已跟踪文件里只扫到 8 个（纯 ASCII 名的），却照样报「通过」。
  $tracked = @(& git -c core.quotePath=false ls-files)
  $scanned = 0
  foreach ($f in $tracked) {
    $fp = Join-Path $Root $f
    if (-not (Test-Path $fp)) { continue }
    $scanned++
    $len = (Get-Item $fp).Length
    if ($len -gt 1MB -and $f -notlike 'screenshots/*') {
      $hygiene += "$f 有 $([math]::Round($len / 1MB, 1)) MB —— 仓库里不该有这么大的文件（截图目录除外）"
    }
  }
  # 覆盖本身也要断言：少扫了文件就说明路径解析坏了，不能当通过
  if ($scanned -lt $tracked.Count) {
    $hygiene += "已跟踪 $($tracked.Count) 个文件，只检查到 $scanned 个（路径解析失败，或有文件被删除未提交）—— 大文件检查的覆盖不完整"
  }
} else {
  Write-Host "  (不是 git 仓库或缺 git，跳过忽略规则核对)" -ForegroundColor DarkGray
}

# 5.4 GreasyFork 硬限制：脚本不能超过 2 MB
if ($bytes -gt 2MB) { $hygiene += "脚本 $bytes 字节，超过 GreasyFork 的 2 MB 上限" }

$hygieneOk = ($hygiene.Count -eq 0)
if ($hygieneOk) {
  Write-Host "  [ 通过 ] 工具脚本 BOM 齐全；敏感/大件全被忽略；无超大跟踪文件；体积在 2 MB 限制内" -ForegroundColor Green
} else {
  $hygiene | ForEach-Object { Write-Host "  [ 失败 ] $_" -ForegroundColor Red }
  $failed++
}

# ---------------------------------------------------------------- 6. 死代码
# 判定：函数名在全文中只出现 1 次 = 只有定义、没有任何调用点。
# 这是启发式（名字出现在注释里也会算作"被引用"），但够用来兜住「写完忘了接上」。
Write-Host "【6/7】死代码检查" -ForegroundColor Yellow
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

# ---------------------------------------------------------------- 7. 体积
Write-Host "【7/7】体积" -ForegroundColor Yellow
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
  $(if ($docOk) { '通过' } else { '**' + $docIssues.Count + ' 项**' }),
  $(if ($hygieneOk) { '通过' } else { '**' + $hygiene.Count + ' 项**' }),
  $(if ($auditOk) { '通过' } else { '**未通过**' }),
  $(if ($deadOk) { '通过' } else { '**' + ($dead -join ', ') + '**' })
Add-Content $LogPath -Value $row -Encoding UTF8
Write-Host "已写入审查记录：$LogPath" -ForegroundColor DarkGray
Write-Host ""

exit $failed
