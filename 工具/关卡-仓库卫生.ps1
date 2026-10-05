# ============================================================================
# 交付检查 · 仓库卫生
# ----------------------------------------------------------------------------
# 独立关卡脚本：可单独运行，也由 工具/交付检查.ps1 汇总调用。
#   pwsh -File "工具/关卡-仓库卫生.ps1"            # 只跑这一关
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
Write-Host "===== 关卡：仓库卫生  (v$ver, $('{0:N0}' -f $bytes) 字节) =====" -ForegroundColor Cyan
# ---------------------------------------------------------------- 5. 仓库卫生
# 守两件事：**别把不该进仓库的东西提交上去**、**别让工具在本机跑不起来**。
# 每一条都对应一次真实踩坑：
#   · HAR 里有 20 处 Cookie（等于登录态）
#   · SingleFile 快照里有整章小说正文
#   · .ps1 丢了 UTF-8 BOM → 5.1 按 ANSI 解码，中文注释乱码、直接语法报错
#   · 官方安装包 136 MB、官方截图 28.8 MB
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
    # 必须 -Recurse：只扫根目录的话，放进子目录的快照会被漏掉（这次就漏了 20 MB 小说正文）
    $suspects += Get-ChildItem $Root -Filter $pat -Force -File -Recurse -ErrorAction SilentlyContinue
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
}

$issues = if ($hygieneOk) { 0 } else { [Math]::Max(1, $hygiene.Count) }
Write-Host "SUMMARY issues=$issues"
exit $issues
