# ============================================================================
# 微信读书脚本 · 生成 README 截图
# ----------------------------------------------------------------------------
# 为什么不截官方 App 的图：
#   ① 官方截图属于腾讯的内容，不适合随开源仓库分发；
#   ② 更重要的是 —— 它们**不显示本脚本**，放进 README 当效果图是误导。
#
# 这里改用「本地 demo 页 + 真加载脚本 + headless 截图」：
#   · 页面骨架、CSS、文案全部是本项目自己的，零第三方素材、零书籍正文
#     （正文用《道德经》先秦公版 + 本项目的自我介绍）；
#   · 脚本是**真的在跑**，和线上同一份文件、同一套注入与主题逻辑。
#
# ⚠️ 这个生成器**自带校验**，因为第一版就翻过车：
#    当时忘了把用户脚本注入 demo 页，结果 15 格全是同一张底、面板也没打开，
#    图看上去「挺像那么回事」。所以现在每一步都要证据：
#      · 页面用 POST /report 回传 DOM 状态 → 断言真的注入了 2 个按钮、真的打开了面板
#      · 每格截图采样左上角底色 → 断言三行底色确实不同、且纯色格等于官方实测值
#    任一条不过就退出码非 0，不会静默产出一张假图。
#
# 用法：pwsh -File "工具\生成截图.ps1"
# 产出：screenshots/主题矩阵.png、screenshots/面板.png
# ============================================================================
param(
  [int]$Port = 8807,
  [switch]$Keep
)

$ErrorActionPreference = 'Continue'   # Edge 会往 stderr 写网络告警，Stop 会误判成致命错误
Add-Type -AssemblyName System.Drawing
$Root = Split-Path $PSScriptRoot -Parent
$ScriptPath = Join-Path $Root 'weread-bg-theme.user.js'
$OutDir = Join-Path $Root 'screenshots'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

if (-not (Test-Path $ScriptPath)) { Write-Host "找不到脚本：$ScriptPath" -ForegroundColor Red; exit 1 }

$Edge = @(
  "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
  "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
  "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
  "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
  "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $Edge) { Write-Host "找不到 Edge / Chrome" -ForegroundColor Red; exit 1 }

# 三套底色的官方实测值（必须与脚本 COLORS 里的一致，用来校验渲染结果）
$expect = @{ white = '#f8f8fa'; sepia = '#f5efd9'; green = '#c0edc6' }

# ---------------------------------------------------------------- 临时目录 + 服务
$Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wrbg-shot-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path (Join-Path $Tmp 'web\reader') | Out-Null

$serveJs = @'
const http=require('http'),fs=require('fs'),path=require('path');
const ROOT=__dirname,PORT=Number(process.argv[2]||8807);
http.createServer((q,s)=>{
  // 收件口：页面把 DOM 状态 POST 回来落盘，生成器据此断言「脚本真的跑了」
  if(q.method==='POST'&&q.url.indexOf('/report')===0){
    let b='';q.on('data',c=>b+=c);q.on('end',()=>{fs.writeFileSync(path.join(ROOT,'report.txt'),b,'utf8');s.writeHead(200).end('ok');});
    return;
  }
  let r=decodeURIComponent(q.url.split('?')[0].split('#')[0]);
  if(r==='/'||r.endsWith('/'))r+='index.html';
  fs.readFile(path.join(ROOT,r),(e,b)=>{if(e){s.writeHead(404).end('404');return;}
    s.writeHead(200,{'content-type':'text/html; charset=utf-8'});s.end(b);});
}).listen(PORT,'127.0.0.1',()=>console.log('up'));
'@
[System.IO.File]::WriteAllText((Join-Path $Tmp 'serve.js'), $serveJs, (New-Object System.Text.UTF8Encoding($false)))

# ---------------------------------------------------------------- demo 阅读页骨架
# 文案自己写：第 1 段介绍本脚本，第 2 段《道德经》首章（先秦公版，无版权问题）。
$demo = @'
<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><title>demo</title>
<style>
  *{box-sizing:border-box}
  html,body{margin:0;height:100%}
  body{background:#f8f8fa;font-family:"PingFang SC","Microsoft YaHei",-apple-system,sans-serif;
       color:#0d141e}
  .app_content,.readerContent,.readerChapterContent_container,.readerChapterContent{
       background-color:inherit}
  .app_content{min-height:100%;padding:64px 72px 96px}
  .readerChapterContent{max-width:46em;margin:0 auto;font-size:19px;line-height:1.95}
  .readerChapterContent h2{font-size:23px;line-height:1.5;margin:0 0 34px;font-weight:600}
  .readerChapterContent p{margin:0 0 22px;text-indent:2em}
  .readerChapterContent p.noindent{text-indent:0}
  .renderTargetPageInfo{position:fixed;left:0;right:0;bottom:18px;text-align:center;
       font-size:13px;color:#858c96}
  /* 工具条：真站点是 .readerControls{position:fixed;right:0;top:50%;transform:translateY(-50%)}。
     这个 transform 很关键 —— 它让 .readerControls 成为 position:fixed 后代的包含块，
     脚本的面板与遮罩正是靠这一点定位并向外扩的，所以骨架里必须照抄。 */
  .readerControls{position:fixed;right:0;top:50%;transform:translateY(-50%);
       z-index:90;display:flex;flex-direction:column;align-items:center;gap:24px;padding:0 12px}
  .readerControls_item{width:48px;height:48px;border:0;border-radius:50%;cursor:pointer;
       display:flex;align-items:center;justify-content:center;background:transparent}
  .wr_tooltip_container{position:relative}
  .wr_tooltip_item{position:absolute;right:60px;top:50%;transform:translateY(-50%);
       white-space:nowrap;font-size:12px;color:#858c96}
</style></head>
<body class="wr_whiteTheme">
  <div class="app_content"><div class="readerContent"><div class="readerChapterContent_container">
    <div class="readerChapterContent">
      <h2>第 1 章 · 为什么要有这个脚本</h2>
      <p class="noindent">手机版微信读书有一套很好用的阅读背景：白色、米黄、青绿三套底色，
        各配纯色、纸纹、素纸、云、月五种纸张纹理，随手一搭就是 15 种组合。</p>
      <p>桌面网页版没有这个功能。这个脚本把它补上了 —— 三套底色与五种纹理的取值，
        全部来自官方手机版截图的逐像素采样，而不是凭感觉调的。</p>
      <p>脚本只改本机浏览器的显示样式：不发任何网络请求，不上传数据，
        也不碰你的书架、笔记和阅读进度。</p>
      <h2 style="margin-top:46px">第 2 章 · 道德经（节选）</h2>
      <p class="noindent">道可道，非常道。名可名，非常名。</p>
      <p>无名天地之始，有名万物之母。故常无欲，以观其妙；常有欲，以观其徼。</p>
      <p>此两者，同出而异名，同谓之玄。玄之又玄，众妙之门。</p>
      <p>天下皆知美之为美，斯恶已；皆知善之为善，斯不善已。</p>
      <p>故有无相生，难易相成，长短相较，高下相倾，音声相和，前后相随。</p>
    </div>
  </div></div></div>
  <div class="renderTargetPageInfo">1956 / 21864</div>
  <div class="readerControls"></div>
<script>
(async function(){
  var S=function(ms){return new Promise(function(r){setTimeout(r,ms);});};
  var n=0; while(!window.wrbg && n++<80) await S(100);
  var m=(location.hash||'').replace('#','').split(',');
  if(window.wrbg && m.length>=2 && m[0] && m[1]){ window.wrbg.set({colorId:m[0], bgId:m[1], brightness:1}); }
  await S(300);
  // hash 里写 panel 就把面板打开（点「背景」按钮 = 不是全屏按钮的那个）
  if(m.indexOf('panel')>=0){
    var b=document.querySelector('.wrbg-btn:not(.wrbg-fs-btn)');
    if(b) b.click();
    await S(300);
  }
  // hash 里写 debug 就在页面上打出关键 DOM 状态（人看的）
  if(m.indexOf('debug')>=0){
    var rc=document.querySelector('.readerControls'), w=document.querySelector('.wrbg-wrap'), pn=document.querySelector('.wrbg-panel');
    var pre=document.createElement('pre');
    pre.style.cssText='position:fixed;left:6px;top:6px;z-index:2147483647;background:#ff0;color:#000;font:12px/1.5 monospace;padding:6px;margin:0';
    var rect=function(el){ if(!el) return 'null'; var r=el.getBoundingClientRect();
      return Math.round(r.left)+','+Math.round(r.top)+' '+Math.round(r.width)+'x'+Math.round(r.height); };
    pre.textContent='btns='+document.querySelectorAll('.wrbg-btn').length+'  panel='+(pn?pn.dataset.open:'无')
      +'\nreaderControls='+rect(rc)+'\nwrap='+rect(w)+'\npanel='+rect(pn)
      +'\ndata-wrbg='+document.documentElement.getAttribute('data-wrbg');
    document.body.appendChild(pre);
    await S(200);
  }
  // 校验用的证据（机器看的）：脚本到底有没有真的把按钮注进来、面板有没有真的打开
  var pn2=document.querySelector('.wrbg-panel');
  var rep='btns='+document.querySelectorAll('.wrbg-btn').length
    +'\nwrap='+(document.querySelector('.wrbg-wrap')?1:0)
    +'\npanelOpen='+(pn2?pn2.dataset.open:'none')
    +'\ndataWrbg='+document.documentElement.getAttribute('data-wrbg');
  try{ await fetch('/report',{method:'POST',body:rep}); }catch(e){}
})();
</script>
</body></html>
'@

# ⚠️ 关键一步：把用户脚本注入 demo 页，且必须放在 demo 自己的 <script> **之前**，
#    这样 demo 里 `while(!window.wrbg)` 才能等到它。
$js = Get-Content $ScriptPath -Raw -Encoding UTF8
$demoPage = $demo.Replace('<script>', "<script>`n" + $js + "`n</script>`n<script>")
$demoPath = Join-Path $Tmp 'web\reader\demo.html'
[System.IO.File]::WriteAllText($demoPath, $demoPage, (New-Object System.Text.UTF8Encoding($false)))

$job = Start-Job -ScriptBlock { param($d, $p) Set-Location $d; & node (Join-Path $d 'serve.js') $p } -ArgumentList $Tmp, $Port
Start-Sleep -Seconds 2

function Shot($file, $hash, $w, $h) {
  $png = Join-Path $Tmp $file
  Remove-Item $png -Force -ErrorAction SilentlyContinue
  $rep = Join-Path $Tmp 'report.txt'
  Remove-Item $rep -Force -ErrorAction SilentlyContinue
  $url = "http://127.0.0.1:$Port/web/reader/demo.html" + $(if ($hash) { "#$hash" } else { '' })
  Start-Process -FilePath $Edge -ErrorAction SilentlyContinue -ArgumentList @(
    '--headless=old', '--disable-gpu', '--no-sandbox', '--no-first-run', '--hide-scrollbars',
    "--user-data-dir=$Tmp\profile", "--window-size=$w,$h", '--virtual-time-budget=15000',
    "--screenshot=$png", $url)
  $n = 0
  while ($n++ -lt 40) {
    if ((Test-Path $png) -and (Test-Path $rep)) { break }
    Start-Sleep -Milliseconds 400
  }
  return $png
}
function Report($file) {
  $r = Join-Path $Tmp 'report.txt'
  if (Test-Path $r) { return (Get-Content $r -Raw -Encoding UTF8) }
  return ''
}
# 取一块区域的均值色（避开文字，取页边）
function BlockColor($bmp, $x, $y, $s) {
  $r = 0L; $g = 0L; $b = 0L; $n = 0
  for ($yy = $y; $yy -lt $y + $s; $yy++) { for ($xx = $x; $xx -lt $x + $s; $xx++) {
    $c = $bmp.GetPixel($xx, $yy); $r += $c.R; $g += $c.G; $b += $c.B; $n++ } }
  return @([int]($r / $n), [int]($g / $n), [int]($b / $n))
}
function HexRgb($hex) {
  $h = $hex.TrimStart('#'); return @(
    [Convert]::ToInt32($h.Substring(0, 2), 16),
    [Convert]::ToInt32($h.Substring(2, 2), 16),
    [Convert]::ToInt32($h.Substring(4, 2), 16))
}

$fails = 0
$log = @()

# ---------------------------------------------------------------- 5 × 3 主题矩阵
$colors = @(@('white', '白'), @('sepia', '米黄'), @('green', '青绿'))
$bgs = @(@('solid', '纯色'), @('paper', '纸纹'), @('plain', '素纸'), @('cloud', '云'), @('moon', '月'))
$TW = 300; $TH = 472; $PAD = 10; $LBL = 30; $HDR = 46
$sheetW = $PAD + ($TW + $PAD) * $bgs.Count
$sheetH = $HDR + $PAD + ($TH + $LBL + $PAD) * $colors.Count
$sheet = New-Object System.Drawing.Bitmap($sheetW, $sheetH)
$g = [System.Drawing.Graphics]::FromImage($sheet)
$g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'
$g.Clear([System.Drawing.Color]::FromArgb(250, 250, 251))
$fTitle = New-Object System.Drawing.Font('Microsoft YaHei', 15, [System.Drawing.FontStyle]::Bold)
$fLbl = New-Object System.Drawing.Font('Microsoft YaHei', 10)
$brText = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(60, 66, 78))
$brSub = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(130, 138, 150))
$g.DrawString('微信读书网页版 · 背景颜色主题   3 套底色 × 5 种纹理 = 15 种组合',
  $fTitle, $brText, $PAD + 2, 12)

$rowColor = @{}
for ($ci = 0; $ci -lt $colors.Count; $ci++) {
  $cid = $colors[$ci][0]
  for ($bi = 0; $bi -lt $bgs.Count; $bi++) {
    $bid = $bgs[$bi][0]
    $png = Shot "$cid-$bid.png" "$cid,$bid" 660 1040
    # ① 证据一：脚本真的注入了按钮
    $rep = Report $png
    if ($rep -notmatch 'btns=2') { $log += "  [失败] $cid/$bid：注入证据不对（$(if($rep){$rep -replace "`n",' '}else{'拿不到报告'})）"; $fails++ }
    if (-not (Test-Path $png)) { $log += "  [失败] $cid/$bid：截图没生成"; $fails++; continue }
    $src = [System.Drawing.Bitmap]::FromFile($png)
    # ② 证据二：这一格的底色确实被脚本改成了对应配色（采页边，避开文字与纹理中心）
    $got = BlockColor $src 8 8 24
    if ($bi -eq 0) {
      $rowColor[$cid] = $got
      $want = HexRgb $expect[$cid]
      $d = [Math]::Abs($got[0] - $want[0]) + [Math]::Abs($got[1] - $want[1]) + [Math]::Abs($got[2] - $want[2])
      if ($d -gt 12) {
        $log += ("  [失败] {0}/纯色 底色偏离官方实测：实测 rgb({1},{2},{3}) 期望 {4}" -f $cid, $got[0], $got[1], $got[2], $expect[$cid]); $fails++
      }
    }
    $x = $PAD + $bi * ($TW + $PAD)
    $y = $HDR + $PAD + $ci * ($TH + $LBL + $PAD)
    $g.DrawImage($src, (New-Object System.Drawing.Rectangle($x, $y, $TW, $TH)),
      0, 0, $src.Width, [int]($src.Height * 0.98), [System.Drawing.GraphicsUnit]::Pixel)
    $src.Dispose()
    $g.DrawString("$($colors[$ci][1]) · $($bgs[$bi][1])", $fLbl, $brSub, $x + 2, $y + $TH + 6)
  }
}
# ③ 证据三：三行底色必须真的互不相同（防「脚本没跑，15 格一个样」这种假图）
$ids = @('white', 'sepia', 'green')
for ($i = 0; $i -lt 3; $i++) { for ($j = $i + 1; $j -lt 3; $j++) {
  $a = $rowColor[$ids[$i]]; $b = $rowColor[$ids[$j]]
  if ($a -and $b) {
    $d = [Math]::Abs($a[0] - $b[0]) + [Math]::Abs($a[1] - $b[1]) + [Math]::Abs($a[2] - $b[2])
    if ($d -lt 20) { $log += "  [失败] $($ids[$i]) 与 $($ids[$j]) 的底色几乎一样（差 $d）——脚本可能没生效"; $fails++ }
  } else { $log += "  [失败] 缺少 $($ids[$i])/$($ids[$j]) 的采样"; $fails++ }
} }
# 矩阵存成 JPEG：PNG 要 2.0 MB（颗粒纹理熵太高、压不动），JPEG q92 只要 ~470 KB。
# 这张图的用途是「一眼看出 15 种背景的差异」，文字清晰度不是重点。
$jpgCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
  Where-Object { $_.MimeType -eq 'image/jpeg' }
$jpgParams = New-Object System.Drawing.Imaging.EncoderParameters(1)
$jpgParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
  [System.Drawing.Imaging.Encoder]::Quality, 92L)
$sheet.Save((Join-Path $OutDir '主题矩阵.jpg'), $jpgCodec, $jpgParams)
$g.Dispose(); $sheet.Dispose()

# ---------------------------------------------------------------- 面板展开
$panelPng = Shot 'panel.png' 'sepia,paper,panel' 1400 900
$prep = Report $panelPng
if ($prep -notmatch 'panelOpen=1') {
  $log += "  [失败] 面板没打开（$(if($prep){$prep -replace "`n",' '}else{'拿不到报告'})）"; $fails++
}
if (Test-Path $panelPng) {
  $src = [System.Drawing.Bitmap]::FromFile($panelPng)
  # 不裁左边 —— 裁了会把文字切成半句，很难看。只削掉底部空白。
  # 坐标先算成变量：不能写 New-Object Rectangle(a,b,c, d-80) ——
  # 括号里的逗号列表会被当成一个数组再对数组做减法（op_Subtraction 报错）。
  $cx = 0; $cy = 0
  $cw = $src.Width; $ch = $src.Height - 60
  $out = New-Object System.Drawing.Bitmap($cw, $ch)
  $g2 = [System.Drawing.Graphics]::FromImage($out)
  $dst = New-Object System.Drawing.Rectangle(0, 0, $cw, $ch)
  $g2.DrawImage($src, $dst, $cx, $cy, $cw, $ch, [System.Drawing.GraphicsUnit]::Pixel)
  $g2.Dispose()
  $out.Save((Join-Path $OutDir '面板.png'), [System.Drawing.Imaging.ImageFormat]::Png)
  $out.Dispose(); $src.Dispose()
} else { $log += "  [失败] 面板截图没生成"; $fails++ }

Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like "*$Tmp*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "===== 生成 README 截图 =====" -ForegroundColor Cyan
Get-ChildItem $OutDir -File | ForEach-Object { "  {0,-16} {1,9:N0} B" -f $_.Name, $_.Length }
$log | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
if ($fails -eq 0) {
  Write-Host "  校验通过：脚本已注入（每格都有 2 个按钮）、三行底色互不相同且纯色格等于官方实测值、面板确实打开" -ForegroundColor Green
} else {
  Write-Host "  $fails 项校验未通过 —— 图不可信，别拿去发" -ForegroundColor Red
}
if ($Keep) { Write-Host "临时目录（-Keep）：$Tmp" -ForegroundColor Yellow }
else { Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue }
exit $fails
