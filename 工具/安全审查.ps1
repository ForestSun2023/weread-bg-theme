# ============================================================================
# 微信读书脚本 · 封号风险静态审查
# ----------------------------------------------------------------------------
# 用法：
#   pwsh -File "工具\安全审查.ps1"
#   pwsh -File "工具\安全审查.ps1" -Path "别的脚本.user.js"
#
# 退出码：0 = 通过（无高风险项）；1 = 发现高风险项
#
# 审查思路：封号打击的是「内容获取」和「账号行为」，不是本地改样式。
# 所以只须确认脚本不碰下列任何一类即可。
# ============================================================================
param(
  [string]$Path = (Join-Path (Split-Path $PSScriptRoot -Parent) 'weread-bg-theme.user.js')
)

if (-not (Test-Path $Path)) { Write-Host "找不到脚本：$Path" -ForegroundColor Red; exit 1 }

$t = Get-Content $Path -Raw -Encoding UTF8
$version = if ($t -match '@version\s+([\d.]+)') { $Matches[1] } else { '(未知)' }
$bytes = (Get-Item $Path).Length

Write-Host ""
Write-Host "===== 封号风险审查：$(Split-Path $Path -Leaf)  v$version  ($('{0:N0}' -f $bytes) 字节) =====" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------- 高风险项
# 每一项都必须为 0，否则判定不通过
$FORBIDDEN = [ordered]@{
  '网络请求'         = @('fetch(', 'XMLHttpRequest', 'WebSocket', 'EventSource', 'sendBeacon', 'GM_xmlhttpRequest')
  '动态执行代码'     = @('eval(', 'new Function', 'setTimeout("', "setTimeout('", 'setInterval("', "setInterval('")
  '外部依赖/注入脚本' = @('@connect', '@require', '@resource', 'unsafeWindow', '<script', 'importScripts')
  '读取/篡改站点数据' = @('document.cookie', 'sessionStorage', 'indexedDB', '__vue__', '.prototype', 'Object.defineProperty(document')
  '模拟用户操作'     = @('.click()', 'dispatchEvent', 'MouseEvent', 'KeyboardEvent', '.submit()', '.focus()', 'InputEvent')
}

$fail = @()
foreach ($cat in $FORBIDDEN.Keys) {
  $hits = @()
  foreach ($pat in $FORBIDDEN[$cat]) {
    $n = ([regex]::Matches($t, [regex]::Escape($pat))).Count
    if ($n -gt 0) { $hits += "$pat×$n" }
  }
  if ($hits.Count -eq 0) {
    Write-Host ("  [ 通过 ] {0,-18} 0" -f $cat) -ForegroundColor Green
  } else {
    Write-Host ("  [ 失败 ] {0,-18} {1}" -f $cat, ($hits -join ', ')) -ForegroundColor Red
    $fail += $cat
  }
}

# ---------------------------------------------------------------- 元数据
Write-Host ""
Write-Host "  元数据" -ForegroundColor Yellow
$grant = ([regex]::Matches($t, '@grant\s+(\S+)') | ForEach-Object { $_.Groups[1].Value }) -join ', '
if (-not $grant) { $grant = '(未声明)' }
Write-Host "    @grant      = $grant"
if ($grant -notmatch 'none' -and $grant -ne '(未声明)') {
  Write-Host "    ⚠ 声明了 GM_* 权限，请确认未实际使用" -ForegroundColor Yellow
}
([regex]::Matches($t, '@match\s+(\S+)') | ForEach-Object { $_.Groups[1].Value }) | ForEach-Object {
  Write-Host "    @match      = $_"
}
$key = if ($t -match "STORE_KEY\s*=\s*'([^']+)'") { $Matches[1] } else { '(未找到)' }
Write-Host "    localStorage 键 = $key"
if ($key -notmatch '^wrbg\.') {
  Write-Host "    ⚠ 存储键不在 wrbg.* 自有命名空间下，可能覆盖站点数据" -ForegroundColor Yellow
  $fail += '存储键命名'
}

# ---------------------------------------------------------------- URL 出处
Write-Host ""
Write-Host "  脚本内出现的 URL（应仅限元数据与 SVG 命名空间）" -ForegroundColor Yellow
$urlHits = Select-String -Path $Path -Pattern 'https?://' -AllMatches
if (-not $urlHits) {
  Write-Host "    (无)"
} else {
  foreach ($h in $urlHits) {
    $line = $h.Line.Trim()
    if ($line.Length -gt 96) { $line = $line.Substring(0, 96) + '…' }
    $isMeta = $line -match '^\s*//\s*@(namespace|match|icon|require|updateURL|downloadURL)'
    $isSvg  = $line -match 'www\.w3\.org/2000/svg'
    $mark = if ($isMeta -or $isSvg) { '  ok ' } else { '  ⚠  ' }
    Write-Host "$mark L$($h.LineNumber): $line"
    if (-not ($isMeta -or $isSvg)) { $fail += '可疑URL' }
  }
}

# ---------------------------------------------------------------- 结论
Write-Host ""
if ($fail.Count -eq 0) {
  Write-Host "  结论：通过 —— 无网络请求、无动态执行、无外部依赖、无站点数据读写、无模拟操作" -ForegroundColor Green
  Write-Host "        全部行为限于本地 CSS/DOM 显示层，不产生可被服务端观测的异常流量。" -ForegroundColor Green
  Write-Host ""
  exit 0
} else {
  Write-Host "  结论：未通过 —— $($fail -join '、')" -ForegroundColor Red
  Write-Host ""
  exit 1
}
