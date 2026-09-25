# ============================================================================
# 微信读书脚本 · 像素验证（3 色 × 5 纹理 = 15 种组合）
# ----------------------------------------------------------------------------
# 回归验证只断言「计算样式」，看不出「渲染出来到底长什么样」——
# 上一版深色模式就是计算样式全绿、观感却很差的例子。
#
# 这个脚本把 15 种组合真的渲染成 1240×2772 的截图，再用**和当初测官方截图完全一样**
# 的采样方法取「左侧页边 3 段纵向亮度」，跟官方 40 张截图的实测值逐格比；
# 再用「月亮区相对于同色纯色的抬升」验证月亮的位置，用「底段 − 顶段」验证云的走向。
#
# 期望值全部来自官方截图实测（批 2 = 4 组 × 5 张）：
#   颜色  纯色        纸纹        素纸        云          月（官方无黑组，黑色已撤）
#   白    248,248,248 251,251,251 245,248,246 213,224,235 207,219,231
#   米黄  233,233,233 228,228,226 242,242,238 222,233,230 217,199,186
#   青绿  209,209,209 230,232,228 237,236,238 226,227,228 192,229,229
#
# 官方的「云 / 月」其实是照片（底部雪山、环形山月球），渐变只能还原明暗走向，
# 所以纹理项容差宽松、纯色项收紧。
#
# 用法：pwsh -File "工具\像素验证.ps1"           # 全部 15 种
#       pwsh -File "工具\像素验证.ps1" -Keep     # 保留截图，便于肉眼复核
# 退出码：0 = 全部通过；>0 = 失败项数量
# ============================================================================
param(
  [int]$Port = 8801,
  [switch]$Keep
)

# 不能用 Stop：Edge 会往 stderr 写网络告警，Stop 会把它当致命错误直接中断整轮
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Drawing
$Root = Split-Path $PSScriptRoot -Parent
$ScriptPath = Join-Path $Root 'weread-bg-theme.user.js'

# ---------------------------------------------------------------- 找浏览器
$Edge = @(
  "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
  "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
  "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
  "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
  "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $Edge) { Write-Host "找不到 Edge / Chrome" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------- 找纵向快照
# 只用纵向那个：双栏的 DOM 结构不同、几何基准不好统一，回归脚本已覆盖它的功能面
$snap = Get-ChildItem $Root -Filter *.html -File | Where-Object {
  $head = Get-Content $_.FullName -TotalCount 40 -Encoding UTF8 -ErrorAction SilentlyContinue | Out-String
  $head -match 'SingleFile' -and $head -match 'weread\.qq\.com'
} | Where-Object {
  -not ((Get-Content $_.FullName -TotalCount 400 -Encoding UTF8 -ErrorAction SilentlyContinue | Out-String) -match 'wr_horizontalReader')
} | Select-Object -First 1
if (-not $snap) { Write-Host "没找到纵向阅读页快照（*.html）" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------- 临时目录 + 服务
$Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wrbg-pixel-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path (Join-Path $Tmp 'web\reader'), (Join-Path $Tmp 'shot') | Out-Null

$serveJs = @'
const http=require('http'),fs=require('fs'),path=require('path');
const ROOT=__dirname,PORT=Number(process.argv[2]||8801);
const T={'.html':'text/html; charset=utf-8','.png':'image/png'};
http.createServer((q,s)=>{let r=decodeURIComponent(q.url.split('?')[0].split('#')[0]);
if(r==='/'||r.endsWith('/'))r+='index.html';
const f=path.join(ROOT,r);
if(!f.startsWith(ROOT)){s.writeHead(403).end('no');return;}
fs.readFile(f,(e,b)=>{if(e){s.writeHead(404).end('404');return;}
s.writeHead(200,{'content-type':T[path.extname(f)]||'application/octet-stream'});s.end(b);});
}).listen(PORT,'127.0.0.1',()=>console.log('up'));
'@
[System.IO.File]::WriteAllText((Join-Path $Tmp 'serve.js'), $serveJs, (New-Object System.Text.UTF8Encoding($false)))

# 页内：禁用动画（headless 虚拟时间会冻结 transition 时钟）→ 按 hash 选中组合
$inject = @'
<style>*{transition:none !important;animation:none !important}</style>
<script>
(async function(){
  var S=function(ms){return new Promise(function(r){setTimeout(r,ms);});};
  var n=0; while(!window.wrbg && n++<80) await S(100);
  var m=(location.hash||'').replace('#','').split(',');
  if(window.wrbg && m.length===2){ window.wrbg.set({colorId:m[0], bgId:m[1], brightness:1}); }
  await S(400);
  document.title='OK';
})();
</script>
'@

$page = Join-Path $Tmp 'web\reader\p.html'
$js = Get-Content $ScriptPath -Raw -Encoding UTF8
# 摘掉快照自带的 CSP（`default-src 'none'` 且无 connect-src）。
# 这里不靠 fetch 回传，理论上不受影响；但顺手摘掉，免得以后往页内加通信时再踩一次
#（回归验证就是这么被坑的：断言全跑完，回传被 CSP 拦掉，外面只看到「拿不到诊断结果」）。
$snapText = (Get-Content $snap.FullName -Raw -Encoding UTF8) -replace '<meta[^>]*Content-Security-Policy[^>]*>', ''
# 注意 $js 必须包在 <script> 里 —— 直接贴进页面只会被当成文本，脚本压根不执行
[System.IO.File]::WriteAllText($page,
  $snapText + "`n<script>`n" + $js + "`n</script>`n" + $inject,
  (New-Object System.Text.UTF8Encoding($false)))

$job = Start-Job -ScriptBlock {
  param($dir, $port)
  Set-Location $dir
  & node (Join-Path $dir 'serve.js') $port
} -ArgumentList $Tmp, $Port
Start-Sleep -Seconds 2

# ---------------------------------------------------------------- 采样工具
# 和当初测官方截图用的完全同一套：左侧页边 3 段（避开正文）
function Bands($bmp) {
  $out = @()
  foreach ($r in @(@(0.05, 0.15), @(0.45, 0.55), @(0.85, 0.95))) {
    $sr = 0L; $sg = 0L; $sb = 0L; $n = 0
    for ($y = [int]($bmp.Height * $r[0]); $y -lt [int]($bmp.Height * $r[1]); $y += 7) {
      for ($x = [int]($bmp.Width * 0.012); $x -lt [int]($bmp.Width * 0.055); $x += 5) {
        $c = $bmp.GetPixel($x, $y); $sr += $c.R; $sg += $c.G; $sb += $c.B; $n++
      }
    }
    $out += , @([int]($sr / $n), [int]($sg / $n), [int]($sb / $n))
  }
  return $out
}
# 月亮盒（x 84-92%，y 5-9%）。
# 为什么不从 y 0 开始：快照顶部是站点自己的外层导航栏，搜索图标正好压在月亮位置上，
# 从 0 起算会把导航栏当成月亮。官方那张月亮半径约 10% 高，5-9% 这一段仍在月面内。
function MoonBox($bmp) {
  $sr = 0L; $sg = 0L; $sb = 0L; $n = 0
  for ($y = [int]($bmp.Height * 0.05); $y -lt [int]($bmp.Height * 0.09); $y += 4) {
    for ($x = [int]($bmp.Width * 0.84); $x -lt [int]($bmp.Width * 0.92); $x += 4) {
      $c = $bmp.GetPixel($x, $y); $sr += $c.R; $sg += $c.G; $sb += $c.B; $n++
    }
  }
  return [int](($sr + $sg + $sb) / (3 * $n))
}
function Lum($t) { return [int](($t[0] + $t[1] + $t[2]) / 3) }

# ---------------------------------------------------------------- 期望值（官方实测）
$cases = @(
  @{ c = 'white'; b = 'solid'; desc = '白·纯色  '; bands = @(248, 248, 248); tol = 4 }
  @{ c = 'white'; b = 'paper'; desc = '白·纸纹  '; bands = @(251, 251, 251); tol = 5 }
  @{ c = 'white'; b = 'plain'; desc = '白·素纸  '; bands = @(245, 248, 246); tol = 6 }
  @{ c = 'white'; b = 'cloud'; desc = '白·云    '; bands = @(213, 224, 235); tol = 10; rise = 10 }
  @{ c = 'white'; b = 'moon';  desc = '白·月    '; bands = @(207, 219, 231); tol = 10; moonRef = 37 }

  @{ c = 'sepia'; b = 'solid'; desc = '米黄·纯色'; bands = @(233, 233, 233); tol = 4; warm = 1 }
  @{ c = 'sepia'; b = 'paper'; desc = '米黄·纸纹'; bands = @(228, 228, 226); tol = 8; warm = 1 }
  @{ c = 'sepia'; b = 'plain'; desc = '米黄·素纸'; bands = @(242, 242, 238); tol = 8; warm = 1 }
  @{ c = 'sepia'; b = 'cloud'; desc = '米黄·云  '; bands = @(222, 233, 230); tol = 10; rise = 6; warm = 1 }
  @{ c = 'sepia'; b = 'moon';  desc = '米黄·月  '; bands = @(217, 199, 186); tol = 12; moonRef = 25 }

  @{ c = 'green'; b = 'solid'; desc = '青绿·纯色'; bands = @(209, 209, 209); tol = 4; greenish = 1 }
  @{ c = 'green'; b = 'paper'; desc = '青绿·纸纹'; bands = @(230, 232, 228); tol = 8; greenish = 1 }
  @{ c = 'green'; b = 'plain'; desc = '青绿·素纸'; bands = @(237, 236, 238); tol = 8 }
  @{ c = 'green'; b = 'cloud'; desc = '青绿·云  '; bands = @(226, 227, 228); tol = 8; greenish = 1 }
  @{ c = 'green'; b = 'moon';  desc = '青绿·月  '; bands = @(192, 229, 229); tol = 12; moonRef = 20 }

)

# ---------------------------------------------------------------- 覆盖自检
# 用例本身是硬编码的（每格要填官方实测值，推导不出来），但**覆盖面**必须自动核对：
# 以后加了第 4 种底色或第 6 种纹理，很容易只改脚本、忘了加用例 ——
# 那样这一关就会「少验几格还报通过」。所以从脚本里解析出真实 id，
# 断言用例集合正好等于 COLORS × BACKGROUNDS 的笛卡尔积（少一个或多一个都算失败）。
$srcJs  = Get-Content $ScriptPath -Raw -Encoding UTF8
$cBlock = [regex]::Match($srcJs, '(?s)const COLORS = \[(.*?)\n  \];').Groups[1].Value
$bBlock = [regex]::Match($srcJs, '(?s)const BACKGROUNDS = \[(.*?)\n  \];').Groups[1].Value
$realColors = @([regex]::Matches($cBlock, "id: '([a-z]+)'") | ForEach-Object { $_.Groups[1].Value })
$realBgs    = @([regex]::Matches($bBlock, "id: '([a-z]+)'") | ForEach-Object { $_.Groups[1].Value })
$expectPairs = @()
foreach ($rc in $realColors) { foreach ($rb in $realBgs) { $expectPairs += "$rc/$rb" } }
$havePairs  = @($cases | ForEach-Object { "$($_.c)/$($_.b)" })
$missPairs  = @($expectPairs | Where-Object { $havePairs -notcontains $_ })
$extraPairs = @($havePairs | Where-Object { $expectPairs -notcontains $_ })

# ---------------------------------------------------------------- 逐格渲染 + 采样
$fails = 0
$rows = @()

if ($realColors.Count -lt 2 -or $realBgs.Count -le 1) {
  $rows += "  FAIL  覆盖自检  解析不出脚本的 COLORS/BACKGROUNDS（拿到 $($realColors.Count) 色 / $($realBgs.Count) 纹理）—— 自检本身失效了"
  $fails++
} elseif ($missPairs.Count -or $extraPairs.Count) {
  $rows += "  FAIL  覆盖自检  用例 $($havePairs.Count) 种 ≠ 脚本 $($realColors.Count) 色 × $($realBgs.Count) 纹理 = $($expectPairs.Count) 种"
  if ($missPairs.Count)  { $rows += "         缺用例：$($missPairs -join ', ')" }
  if ($extraPairs.Count) { $rows += "         多余或拼错：$($extraPairs -join ', ')" }
  $fails++
} else {
  $rows += "  PASS  覆盖自检  用例 $($havePairs.Count) 种 == 脚本 $($realColors.Count) 色 × $($realBgs.Count) 纹理"
}

foreach ($cs in $cases) {
  $png = Join-Path $Tmp ("shot\" + $cs.c + '-' + $cs.b + '.png')
  $url = "http://127.0.0.1:$Port/web/reader/p.html#" + $cs.c + ',' + $cs.b
  # 必须用 Start-Process -Wait（同回归脚本：& 调用 GUI 子系统程序时 PowerShell 不等它）
  Start-Process -FilePath $Edge -Wait -NoNewWindow -ErrorAction SilentlyContinue -ArgumentList @(
    '--headless=old', '--disable-gpu', '--no-sandbox', '--hide-scrollbars', '--no-first-run',
    "--user-data-dir=$Tmp\profile", '--window-size=1240,2772', '--virtual-time-budget=20000',
    "--screenshot=$png", $url) -RedirectStandardOutput "$Tmp\edge-out.txt" -RedirectStandardError "$Tmp\edge-err.txt"
  if (-not (Test-Path $png)) { $rows += ("  [渲染失败] " + $cs.desc); $fails++; continue }

  $bmp = [System.Drawing.Bitmap]::FromFile($png)
  $bands = Bands $bmp
  $mb = MoonBox $bmp
  $bmp.Dispose()

  $bad = @()
  # 必须逐条调用：写成 @(Lum $bands[0], Lum $bands[1], …) 会被 PowerShell 当成
  # 「一条命令带三个参数」，结果是空数组（这个坑踩过一次，会伪造出一堆假 FAIL）。
  $l0 = Lum $bands[0]
  $l1 = Lum $bands[1]
  $l2 = Lum $bands[2]
  $l = @($l0, $l1, $l2)

  # ① 三段页边亮度对官方实测
  for ($i = 0; $i -lt 3; $i++) {
    if ([Math]::Abs($l[$i] - $cs.bands[$i]) -gt $cs.tol) {
      $bad += ("段{0} 期望{1}±{2} 实测{3}" -f ($i + 1), $cs.bands[$i], $cs.tol, $l[$i])
    }
  }
  # ② 云的走向：越往下越亮
  if ($cs.rise -and ($l2 - $l0) -lt $cs.rise) { $bad += ("底部只比顶部亮 {0}，要求 ≥ {1}" -f ($l2 - $l0), $cs.rise) }
  # ③ 月亮：月亮盒 vs **同一张图的顶部页边**。
  #    不能拿「同色纯色那张」当基准 —— 那会把纹理本身的底色变暗也算进月亮的贡献；
  #    也不能拿左边的天空盒当基准 —— 那一带正好压着章节标题文字。左侧页边是纯背景，最干净。
  $lift = 0
  if ($cs.moonRef) {
    $lift = $mb - $l0
    # 门槛 = 官方实测抬升的 60%（官方值：白 37 / 米黄 25 / 青绿 20 / 黑 111）
    $need = [int]($cs.moonRef * 0.6)
    if ($lift -lt $need) { $bad += ("月亮区抬升 {0} < 官方 {1} 的 60%({2})" -f $lift, $cs.moonRef, $need) }
  }
  # ④ 色调方向：米黄偏暖（R>B）、青绿偏绿（G>R）
  $mid = $bands[1]
  if ($cs.warm -and -not ($mid[0] -gt $mid[2] + 8)) { $bad += ("米黄不偏暖 ({0},{1},{2})" -f $mid[0], $mid[1], $mid[2]) }
  if ($cs.greenish -and -not ($mid[1] -gt $mid[0] + 8)) { $bad += ("青绿不偏绿 ({0},{1},{2})" -f $mid[0], $mid[1], $mid[2]) }

  $tag = 'PASS'
  if ($bad.Count) { $tag = 'FAIL'; $fails++ }
  $rows += ("  {0}  {1}  页边 {2,3},{3,3},{4,3}  (RGB {5,3},{6,3},{7,3})  月亮抬升 {8,3}/{9}{10}" -f `
      $tag, $cs.desc, $l[0], $l[1], $l[2], $mid[0], $mid[1], $mid[2], $lift, $(if ($cs.moonRef) { $cs.moonRef } else { "-" }),
    $(if ($bad.Count) { "  ← " + ($bad -join ' ; ') } else { '' }))
  if (-not $Keep) { Remove-Item $png -Force -ErrorAction SilentlyContinue }
}

Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like "*$Tmp*" } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Stop-Job $job -ErrorAction SilentlyContinue
Remove-Job $job -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------- 输出
Write-Host ""
Write-Host "===== 像素验证：3 色 × 5 纹理 = 15 种组合（1240x2772 实拍）=====" -ForegroundColor Cyan
Write-Host "  快照：$($snap.Name)"
Write-Host ""
$rows | ForEach-Object { Write-Host $_ }
Write-Host ""

if ($Keep) { Write-Host "截图保留在（-Keep）：$Tmp\shot" -ForegroundColor Yellow }
else { Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue }

if ($fails -eq 0) {
  Write-Host "结论：15 种组合全部通过（三段色值、云的走向、月亮位置、色调方向）" -ForegroundColor Green
  Write-Host ""
  exit 0
} else {
  Write-Host "结论：$fails 种组合未达到官方实测" -ForegroundColor Red
  Write-Host ""
  exit $fails
}
