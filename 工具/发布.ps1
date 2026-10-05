# ============================================================================
# 发布自动化：自动打 tag + 建 GitHub Release
# ----------------------------------------------------------------------------
# 由 CI 在「push 到 main 且五道静态关卡全过」之后调用：
#     pwsh -File "工具\发布.ps1"
#
# 它做的事（**幂等**，重复跑不会出问题）：
#   1. 读脚本头部的 @version
#   2. 若 tag `v<版本>` 不存在 → 用它建一个（指向本次提交）
#   3. 若该版本的 Release 不存在 → 用 CHANGELOG 里对应段落作正文建一个
#
# 为什么值得自动化：
#   · 版本化的 CDN 地址（`…@v3.5.0/…`）**依赖 tag** —— 忘了打 tag，那个地址就是 404；
#   · 「哪个提交是哪个版本」的溯源也依赖 tag；
#   · 以前这三件事全靠人记得。**能被自动做的事，不要靠记忆。**
#
# 需要环境变量（CI 自动提供）：
#   GH_TOKEN / GITHUB_REPOSITORY / GITHUB_SHA / GITHUB_API_URL
# 缺 GH_TOKEN 时只做「本地预演」：打印将要做什么，不实际调用 API，退出码 0。
# ============================================================================
param(
  [string]$Repo  = $env:GITHUB_REPOSITORY,
  [string]$Sha   = $env:GITHUB_SHA,
  [string]$Token = $env:GH_TOKEN,
  [string]$Api   = $(if ($env:GITHUB_API_URL) { $env:GITHUB_API_URL } else { 'https://api.github.com' })
)

$ErrorActionPreference = 'Continue'
$Root = Split-Path $PSScriptRoot -Parent

$scriptPath = Join-Path $Root 'weread-bg-theme.user.js'
$raw = Get-Content $scriptPath -Raw -Encoding UTF8
$m = [regex]::Match($raw, '@version\s+([\d.]+)')
if (-not $m.Success) { Write-Host "读不到 @version，中止" -ForegroundColor Red; exit 1 }
$ver = $m.Groups[1].Value
$tag = "v$ver"

Write-Host ""
Write-Host "===== 发布 v$ver =====" -ForegroundColor Cyan

if (-not $Token -or -not $Repo -or -not $Sha) {
  Write-Host "  缺少 GH_TOKEN / GITHUB_REPOSITORY / GITHUB_SHA —— 本地预演模式，不调用 API。" -ForegroundColor Yellow
  Write-Host "  将会做：tag $tag（指向当前提交）+ Release「$tag」（正文取自 CHANGELOG）" -ForegroundColor DarkGray
  Write-Host ""
  exit 0
}

$headers = @{
  Authorization = "Bearer $Token"
  Accept        = 'application/vnd.github+json'
  'User-Agent'  = 'weread-bg-theme-release'
}

# ---------------------------------------------------------------- 1. tag
$needTag = $true
try {
  $existing = Invoke-RestMethod -Uri "$Api/repos/$Repo/git/ref/tags/$tag" -Headers $headers -TimeoutSec 30 -EA Stop
  if ($existing.ref) { $needTag = $false; Write-Host "  tag $tag 已存在（跳过）" -ForegroundColor DarkGray }
} catch {
  $code = 0; if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
  if ($code -ne 404) { Write-Host "  查询 tag 失败（HTTP $code）：$($_.Exception.Message)" -ForegroundColor Yellow }
}

if ($needTag) {
  $payload = @{ ref = "refs/tags/$tag"; sha = $Sha } | ConvertTo-Json -Compress
  try {
    [void](Invoke-RestMethod -Method Post -Uri "$Api/repos/$Repo/git/refs" -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $payload -TimeoutSec 30 -EA Stop)
    Write-Host "  ✅ 已打 tag $tag → $($Sha.Substring(0, 7))" -ForegroundColor Green
  } catch {
    Write-Host "  ❌ 打 tag 失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
  }
}

# ---------------------------------------------------------------- 2. Release
try {
  [void](Invoke-RestMethod -Uri "$Api/repos/$Repo/releases/tags/$tag" -Headers $headers -TimeoutSec 30 -EA Stop)
  Write-Host "  Release $tag 已存在（跳过）" -ForegroundColor DarkGray
  Write-Host ""
  exit 0
} catch {
  $code = 0; if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
  if ($code -ne 404) { Write-Host "  查询 Release 失败（HTTP $code）" -ForegroundColor Yellow }
}

# 正文：CHANGELOG 里本版本的段落
$chgPath = Join-Path $Root 'CHANGELOG.md'
$body = "（CHANGELOG 里没有 $tag 的条目）"
if (Test-Path $chgPath) {
  $chg = Get-Content $chgPath -Raw -Encoding UTF8
  $sec = [regex]::Match($chg, "(?ms)^## $([regex]::Escape($tag))\s*$(?:`r?`n)(.*?)(?=^## v|\z)")
  if ($sec.Success) { $body = $sec.Groups[1].Value.Trim() }
}

# 安装/更新说明（读者最关心的两句话，放在正文最上面）
$head = @"
**安装 / 更新**：[点此安装或更新](https://cdn.jsdelivr.net/gh/$Repo@$tag/weread-bg-theme.user.js)
（`@updateURL` 指向 `@main`，Tampermonkey 会自动提示更新。）

---

"@
$release = @{
  tag_name = $tag
  name     = $tag
  body     = $head + $body
}
$payload = $release | ConvertTo-Json -Depth 4
try {
  [void](Invoke-RestMethod -Method Post -Uri "$Api/repos/$Repo/releases" -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $payload -TimeoutSec 30 -EA Stop)
  Write-Host "  ✅ 已建 Release $tag（正文取自 CHANGELOG）" -ForegroundColor Green
} catch {
  Write-Host "  ❌ 建 Release 失败：$($_.Exception.Message)" -ForegroundColor Red
  exit 1
}

Write-Host ""
exit 0
