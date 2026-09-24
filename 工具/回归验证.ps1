# ============================================================================
# 微信读书脚本 · 回归验证
# ----------------------------------------------------------------------------
# 用途：把「SingleFile 快照 + 注入脚本 + headless 渲染 + 断言」这套验证流程固化，
#       以后每次改动跑一条命令即可回归，不用再临时搭环境。
#
# 用法：
#   pwsh -File "工具\回归验证.ps1"                  # 自动发现工作目录下的页面快照
#   pwsh -File "工具\回归验证.ps1" -Snapshot "a.html","b.html"
#   pwsh -File "工具\回归验证.ps1" -Keep            # 保留临时目录，便于排查
#
# 退出码：0 = 全部通过；>0 = 失败项数量
#
# 已知陷阱（headless 环境，脚本里已针对性处理）：
#   1. 虚拟时间会冻结 CSS transition 的动画时钟 → 计算的 background-color 会停在中间值。
#      测试脚本会先注入 *{transition:none} 规避。
#   2. 快照是「保存时的窗口宽度」下的静态 DOM，窄窗口下布局与真机不同
#      → 因此断言只做「计算样式 / 几何关系」，不做像素比对。
# ============================================================================
param(
  [string[]]$Snapshot,
  [int]$Port = 8799,
  [switch]$Keep
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$ScriptPath = Join-Path $Root 'weread-bg-theme.user.js'

if (-not (Test-Path $ScriptPath)) { Write-Host "找不到脚本：$ScriptPath" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------- 找浏览器
$Edge = @(
  "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
  "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
  "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
  "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
  "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $Edge) { Write-Host "找不到 Edge / Chrome，无法做 headless 渲染" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------- 找快照
if (-not $Snapshot -or $Snapshot.Count -eq 0) {
  $Snapshot = Get-ChildItem $Root -Filter *.html -File | Where-Object {
    $head = Get-Content $_.FullName -TotalCount 40 -Encoding UTF8 -ErrorAction SilentlyContinue | Out-String
    $head -match 'SingleFile' -and $head -match 'weread\.qq\.com'
  } | ForEach-Object { $_.FullName }
}
if (-not $Snapshot -or $Snapshot.Count -eq 0) {
  Write-Host "没找到可用于验证的页面快照（*.html，SingleFile 保存的阅读页）" -ForegroundColor Red
  exit 1
}

# ---------------------------------------------------------------- 临时目录
$Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wrbg-regress-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path (Join-Path $Tmp 'web\reader') | Out-Null

$serveJs = @'
const http=require('http'),fs=require('fs'),path=require('path');
const ROOT=__dirname,PORT=Number(process.argv[2]||8799);
const T={'.html':'text/html; charset=utf-8','.js':'text/javascript','.png':'image/png'};
http.createServer((q,s)=>{
// 收件口：页面把诊断结果 POST 回来落盘。
// 不走 --dump-dom 是因为 Edge 149 的启动器 fork 完就退出，子进程的 stdout 接不回来。
if(q.method==='POST'&&q.url.indexOf('/report')===0){
  let b='';q.on('data',c=>b+=c);q.on('end',()=>{fs.writeFileSync(path.join(ROOT,'report.txt'),b,'utf8');s.writeHead(200).end('ok');});
  return;
}
let r=decodeURIComponent(q.url.split('?')[0].split('#')[0]);
if(r==='/'||r.endsWith('/'))r+='index.html';
const f=path.join(ROOT,r);
if(!f.startsWith(ROOT)){s.writeHead(403).end('no');return;}
fs.readFile(f,(e,b)=>{if(e){s.writeHead(404).end('404');return;}
s.writeHead(200,{'content-type':T[path.extname(f)]||'application/octet-stream'});s.end(b);});
}).listen(PORT,'127.0.0.1',()=>console.log('up'));
'@
[System.IO.File]::WriteAllText((Join-Path $Tmp 'serve.js'), $serveJs, (New-Object System.Text.UTF8Encoding($false)))

# ---------------------------------------------------------------- 页内断言
$harness = @'
<div id="__diag" style="position:fixed;left:0;top:0;z-index:2147483647;background:#ff0;color:#000;font:11px/1.4 monospace;padding:5px;white-space:pre-wrap;border:3px solid #f00"></div>
<script>
(async function(){
  var S=function(ms){return new Promise(function(r){setTimeout(r,ms);});};
  var lines=[],fails=0;
  function ok(name,cond,extra){ lines.push((cond?'PASS  ':'FAIL  ')+name+(extra?('   ['+extra+']'):'')); if(!cond)fails++; }
  function q(s){return document.querySelector(s);}
  function norm(s){return (s||'').replace(/\s+/g,'');}
  function wantBg(){return getComputedStyle(document.documentElement).getPropertyValue('--wrbg-bg').trim();}
  var errs=[]; window.addEventListener('error',function(e){errs.push(e.message);});
  function finish(){
    lines.push('');
    lines.push('SUMMARY fails='+fails+' errors='+errs.length+(errs.length?('  '+errs.join(' ;; ')):''));
    var rep=lines.join('\n');
    // 诊断框可能被站点的标签结构吞掉（快照末尾没有 </body></html>），找不到就自己造一个，
    // 否则 finish() 自己抛异常 → 后面的 fetch 也不会执行 → 外面什么都收不到。
    var d=document.getElementById('__diag');
    if(!d){ d=document.createElement('pre'); d.id='__diag'; document.documentElement.appendChild(d); }
    d.textContent=rep;
    try{ fetch('/report',{method:'POST',body:rep}); }catch(e){}
  }

  // ⚠️ 整个断言过程必须包在 try 里。
  // 这里出过事故：某条断言对着 null 调方法抛异常 → 直接跳出 async IIFE →
  // finish() 永远不执行 → 报告发不出来 → 外面只看到「拿不到诊断结果」，
  // 排查了半天才知道是断言自己崩了。所以现在要求：抛异常也必须出一份报告，把栈一起写进去。
  try {
  var n=0; while(!window.wrbg && n++<80) await S(100);
  if(!window.wrbg){ lines.push('FAIL  脚本未就绪（window.wrbg 不存在）'); fails++; return; }

  // headless 冻结 transition 时钟 → 必须先禁用，否则读到中间值
  var st=document.createElement('style');
  st.textContent='*{transition:none !important;animation:none !important}';
  document.documentElement.appendChild(st);

  // --- 注入 ---
  ok('按钮注入（背景 + 全屏共 2 个）', document.querySelectorAll('.wrbg-btn').length===2,
     '实际 '+document.querySelectorAll('.wrbg-btn').length);
  ok('工具条内有 .wrbg-wrap', !!q('.readerControls .wrbg-wrap'));
  (function(){
    var rc=q('.readerControls'), w=q('.wrbg-wrap');
    var last = !!rc && !!w && rc.lastElementChild===w;
    ok('脚本按钮固定在所有原生按钮之后', last, 'wrap 是末位='+last);
  })();
  ok('注入失败时有兜底（不抛异常）', errs.length===0);

  // --- 面板与遮罩 ---
  var tbtn=q('.wrbg-btn:not(.wrbg-fs-btn)');
  tbtn.click(); await S(250);
  ok('面板可打开', q('.wrbg-panel').dataset.open==='1');
  ok('遮罩盖满视口（防双栏 transform 陷阱）', (function(){
      var m=q('.wrbg-mask'), r=m.getBoundingClientRect();
      return r.left<=0 && r.top<=0 && r.right>=innerWidth && r.bottom>=innerHeight;
    })(), (function(){var r=q('.wrbg-mask').getBoundingClientRect();return Math.round(r.width)+'x'+Math.round(r.height)+' vs 视口'+innerWidth+'x'+innerHeight;})());
  tbtn.click(); await S(250);
  ok('面板可关闭', q('.wrbg-panel').dataset.open==='0');

  // --- 浅色主题 ---
  window.wrbg.set({colorId:'sepia', bgId:'paper', brightness:1}); await S(350);
  ok('data-wrbg=sepia', document.documentElement.getAttribute('data-wrbg')==='sepia');
  (function(){
    var want=norm(wantBg()), bad=[];
    ['body','.app_content','.readerChapterContent','.wr_horizontalReader_app_content'].forEach(function(s){
      var e=q(s); if(!e) return;
      var g=getComputedStyle(e).backgroundColor;
      if(g==='rgba(0, 0, 0, 0)') return;
      if(norm(g)!==want) bad.push(s+'='+g);
    });
    ok('浅色：各容器底色 == --wrbg-bg', bad.length===0, bad.length?bad.join(' , '):('--wrbg-bg='+want));
  })();
  (function(){
    var c=q('canvas'), f=c?getComputedStyle(c).filter:'(无canvas)';
    ok('浅色：canvas 不做染色（位图只有字形）', f==='none', 'filter='+f);
  })();

  // --- 白天 / 黑夜：脚本只管白天，进黑夜整块让位（只留「全屏」一个按钮）---
  var root=document.documentElement;
  ok('浅色下脚本接管（data-wrbg=sepia）', root.getAttribute('data-wrbg')==='sepia');

  (function(){
    var sw=q('.wrbg-row-color').children, names=[];
    for(var i=0;i<sw.length;i++) names.push(sw[i].title);
    ok('颜色行 3 套（白/米黄/青绿）',
       sw.length===3 && names.join(',')==='白色,米黄,青绿', '色块='+names.join(','));
    var bw=q('.wrbg-row-bg').children, bn=[];
    for(var j=0;j<bw.length;j++) bn.push(bw[j].title);
    ok('背景行 5 种纹理（纯色/纸纹/素纸/云/月）',
       bw.length===5 && bn.join(',')==='纯色,纸纹,素纸,云,月', '色块='+bn.join(','));
  })();

  // 昼夜开关必须留给站点原装按钮：
  // v3.0.0 自己造过一个，只翻 CSS 类、不通知引擎重绘，回白天时位图还是浅色字 → 正文看不见。
  ok('脚本不再自己造「切换模式」按钮（昼夜交给站点原装按钮）',
     document.querySelectorAll('.wrbg-mode-btn').length===0,
     '实际 '+document.querySelectorAll('.wrbg-mode-btn').length);
  (function(){
    var it=q('.readerControls_item.dark');
    ok('站点原生「深色」按钮可见可用（唯一的昼夜开关）',
       !!it && getComputedStyle(it).display!=='none',
       'display='+(it?getComputedStyle(it).display:'无'));
  })();

  // 模拟用户点站点「深色」→ 进黑夜
  document.body.classList.remove('wr_whiteTheme'); await S(400);
  ok('进黑夜：脚本整块让位（data-wrbg 被摘掉）',
     root.getAttribute('data-wrbg')===null, 'data-wrbg='+root.getAttribute('data-wrbg'));
  (function(){
    var bad=[];
    ['body','.app_content','.readerChapterContent','.wr_horizontalReader_app_content'].forEach(function(s){
      var e=q(s); if(!e) return;
      var g=norm(getComputedStyle(e).backgroundColor);
      if(g==='rgb(246,239,221)'||g==='rgb(248,248,250)'||g==='rgb(192,237,198)') bad.push(s+'='+g);
    });
    ok('黑夜：阅读区不再被脚本染色（没有浅色底残留）', bad.length===0, bad.length?bad.join(' , '):'干净');
  })();
  (function(){
    var e=q('.readerChapterContent'), g=e?norm(getComputedStyle(e).color):'';
    ok('黑夜：正文字色交给站点深色主题（是浅色，不是我们那套深色）',
       !!g && g!=='rgb(61,52,39)' && g!=='rgb(13,20,30)' && g!=='rgb(47,58,44)',
       'color='+g);
  })();
  (function(){
    // 黑夜下 <html> 上不该再留任何 --wrbg-* 内联变量。
    // 这是「脚本对页面零残留」的结构性证据 —— 比逐条声明「我们的规则都写了作用域」可靠得多。
    var leaked=[];
    for(var i=0;i<root.style.length;i++){
      var p=root.style[i];
      if(p.indexOf('--wrbg-')===0) leaked.push(p+'='+root.style.getPropertyValue(p));
    }
    ok('黑夜：脚本写上的 --wrbg-* 内联变量已全部清除（零残留）',
       leaked.length===0, leaked.length?leaked.join(' , '):'内联变量 0 条');
  })();
  (function(){
    var c=q('canvas'), f=c?getComputedStyle(c).filter:'(无canvas)';
    ok('黑夜：canvas 不叠任何 filter', f==='none', 'filter='+f);
  })();
  (function(){
    var host=q('.wrbg-theme-host');
    ok('黑夜：「背景」按钮隐藏（没有背景功能）',
       !!host && getComputedStyle(host).display==='none',
       'display='+(host?getComputedStyle(host).display:'无'));
  })();
  (function(){
    var fs=q('.wrbg-fs-btn');
    var vis = fs ? getComputedStyle(fs).display!=='none' : false;
    var col = fs ? getComputedStyle(fs.querySelector('svg')).color : '';
    ok('黑夜：「全屏」按钮仍可用且图标有色（不是隐形）', vis && col!=='rgb(0, 0, 0)' && col!=='rgba(0, 0, 0, 0)',
       'display='+(fs?getComputedStyle(fs).display:'无')+' 图标色='+col);
  })();
  // 用 getClientRects() 判断「到底渲染出来没有」。
  // 不能看按钮自己的 computed display —— 被隐藏的是父容器 .wrbg-theme-host，
  // 子按钮自己的 display 照样是 flex（踩过这个坑，会误报成「有两个可见按钮」）。
  ok('黑夜：脚本只多出「全屏」一个可见按钮',
     (function(){var n=0,b=document.querySelectorAll('.wrbg-btn');
       for(var i=0;i<b.length;i++) if(b[i].getClientRects().length) n++;
       return n===1;})(),
     '可见脚本按钮数='+(function(){var n=0,b=document.querySelectorAll('.wrbg-btn');
       for(var i=0;i<b.length;i++) if(b[i].getClientRects().length) n++; return n;})());

  // 再点一次站点「深色」→ 回白天，脚本重新接管
  document.body.classList.add('wr_whiteTheme'); await S(400);
  ok('回白天：脚本重新接管', root.getAttribute('data-wrbg')==='sepia',
     'data-wrbg='+root.getAttribute('data-wrbg'));
  ok('不再有 data-wrbg-mode 这个模式标记', root.getAttribute('data-wrbg-mode')===null);
  (function(){
    var host=q('.wrbg-theme-host');
    ok('回白天 →「背景」按钮恢复显示',
       !!host && getComputedStyle(host).display!=='none',
       'display='+(host?getComputedStyle(host).display:'无'));
  })();
  (function(){
    var c=q('canvas'), f=c?getComputedStyle(c).filter:'(无canvas)';
    ok('回白天：canvas 恢复不染色（filter=none）', f==='none', 'filter='+f);
  })();

  window.wrbg.set({colorId:'sepia', bgId:'paper', brightness:1}); await S(250);

  // --- 自检逻辑不应误报 ---
  ok('主题正常时不产生控制台告警', errs.length===0);

  // --- 全屏按钮三态 ---
  var fbtn=q('.wrbg-fs-btn');
  ok('全屏按钮存在', !!fbtn);
  ok('普通状态：显示「全屏阅读」', fbtn.title==='全屏阅读', 'title='+fbtn.title);
  try{
    Object.defineProperty(window,'screen',{value:{height:900,availHeight:860,width:1400},configurable:true});
    Object.defineProperty(window,'innerHeight',{value:900,configurable:true});
    Object.defineProperty(window,'outerHeight',{value:900,configurable:true});
    window.dispatchEvent(new Event('resize')); await S(400);
    ok('模拟 F11：识别为全屏', window.wrbg.fullscreen.native===true, JSON.stringify(window.wrbg.fullscreen));
    ok('模拟 F11：按钮变「退出全屏（按 F11）」', fbtn.title.indexOf('按 F11')>=0, 'title='+fbtn.title);
    window.__req=false;
    document.documentElement.requestFullscreen=function(){window.__req=true;return Promise.resolve();};
    fbtn.click(); await S(150);
    ok('模拟 F11：点击不会误触 API 全屏', window.__req===false);
    ok('模拟 F11：点击给出提示', q('.wrbg-tip-host.wrbg-tip-force')!==null);
  }catch(e){ ok('F11 状态模拟', false, String(e)); }

  ok('全程无控制台报错', errs.length===0, errs.join(' ;; '));

  // ---------- D 类：可用性改进 ----------
  window.wrbg.set({colorId:'sepia', bgId:'solid', brightness:1}); await S(250);

  // D1 亮度百分比
  var pct=q('.wrbg-pct'), rng=q('.wrbg-range');
  ok('亮度百分比读数存在', !!pct, pct?('当前 '+pct.textContent):'（无）');
  if(pct && rng){
    rng.value='42'; rng.dispatchEvent(new Event('input',{bubbles:true}));
    ok('拖动滑杆后百分比同步为 42%', pct.textContent==='42%', 'text='+pct.textContent);
    rng.value='100'; rng.dispatchEvent(new Event('input',{bubbles:true}));
    ok('拉回 100% 后同步', pct.textContent==='100%', 'text='+pct.textContent);
  }

  // D2 站点原生的「深色」按钮必须还能用（黑夜整块交给它）
  var darkItem=q('.readerControls_item.dark');
  ok('站点原生「深色」按钮未被隐藏（黑夜交给站点）',
     !!darkItem && getComputedStyle(darkItem).display!=='none',
     'display='+(darkItem?getComputedStyle(darkItem).display:'无'));

  // D3 快捷键 b 开关面板（输入框内不触发）
  var pn=q('.wrbg-panel');
  if(pn.dataset.open==='1') q('.wrbg-btn:not(.wrbg-fs-btn)').click();
  document.dispatchEvent(new KeyboardEvent('keydown',{key:'b',bubbles:true}));
  var hotkeyOpened=(pn.dataset.open==='1');
  document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));
  ok('按 b 可打开面板', hotkeyOpened, '按 b 后 open='+(hotkeyOpened?'1':'0'));

  var inp=document.createElement('input'); document.body.appendChild(inp); inp.focus();
  inp.dispatchEvent(new KeyboardEvent('keydown',{key:'b',bubbles:true}));
  await S(60);
  ok('输入框/编辑区里按 b 不触发', pn.dataset.open==='0', 'open='+pn.dataset.open);
  inp.remove();

  // D4 面板始终落在视口内（窄窗口靠 transform 钳制）
  q('.wrbg-btn:not(.wrbg-fs-btn)').click(); await S(220);
  (function(){
    var r=pn.getBoundingClientRect();
    var inside = r.left>=-1 && r.top>=-1 && r.right<=innerWidth+1 && r.bottom<=innerHeight+1;
    ok('面板完全落在视口内', inside,
       Math.round(r.left)+','+Math.round(r.top)+' '+Math.round(r.width)+'x'+Math.round(r.height)+'  视口'+innerWidth+'x'+innerHeight);
  })();
  q('.wrbg-btn:not(.wrbg-fs-btn)').click();

  } catch (e) {
    lines.push('FAIL  断言脚本自身抛异常（后面的断言都没跑到）: ' + ((e && (e.stack || e.message)) || e));
    fails++;
  } finally {
    finish();
  }
})();
</script>
'@

$js = Get-Content $ScriptPath -Raw -Encoding UTF8

# ---------------------------------------------------------------- 启服务器
$job = Start-Job -ScriptBlock {
  param($dir,$port) & node (Join-Path $dir 'serve.js') $port
} -ArgumentList $Tmp, $Port
Start-Sleep -Seconds 2

# ---------------------------------------------------------------- 跑每个快照
$totalFails = 0
$report = @()

foreach ($snap in $Snapshot) {
  $name = Split-Path $snap -Leaf
  $text = Get-Content $snap -Raw -Encoding UTF8
  # ⚠️ 必须摘掉快照自带的 CSP。
  # SingleFile 把站点的 <meta http-equiv=content-security-policy> 原样存下来了，内容是
  # `default-src 'none'; …` 且**没有 connect-src** —— 于是 connect-src 回退到 default-src 'none'，
  # 页面里任何 fetch/XHR 都被浏览器掐掉，诊断结果永远回不来。
  # 症状极具迷惑性：断言其实全跑完了（截图上黄色诊断框里全是 PASS），只是回传被拦，
  # 外面只看到「拿不到诊断结果」，连 beacon 都发不出。本地测试夹具，摘掉无副作用。
  $text = $text -replace '<meta[^>]*Content-Security-Policy[^>]*>', ''
  $label = if ($text -match 'wr_horizontalReader') { '双栏/横向' } else { '纵向/单栏' }
  $page = Join-Path $Tmp ('web\reader\' + [System.IO.Path]::GetFileNameWithoutExtension($snap) + '.html')
  [System.IO.File]::WriteAllText($page, $text + "`n<script>`n" + $js + "`n</script>`n" + $harness,
    (New-Object System.Text.UTF8Encoding($false)))

  $url = "http://127.0.0.1:$Port/web/reader/" + [System.IO.Path]::GetFileNameWithoutExtension($snap) + '.html'
  # 结果不再从 stdout 拿（Edge 149 的启动器 fork 完就退出，子进程的 stdout 接不回来），
  # 改成页面自己 POST /report 落盘，这里只负责把浏览器拉起来 + 轮询那个文件。
  # --screenshot 是必须的：无头 Edge 如果没有任何「要产出点什么」的任务，加载完就直接退出，
  # 页面里 await 到一半的 harness 和它最后那个 fetch 都来不及跑。
  # 这个 png 只是让 Edge 活到 virtual-time-budget 结束，内容不要。
  $repFile = Join-Path $Tmp 'report.txt'
  $throw = Join-Path $Tmp 'throwaway.png'
  Remove-Item $repFile, $throw -Force -ErrorAction SilentlyContinue
  Start-Process -FilePath $Edge -ErrorAction SilentlyContinue -ArgumentList @(
    '--headless=old', '--disable-gpu', '--no-sandbox', '--no-first-run', '--hide-scrollbars',
    "--user-data-dir=$Tmp\profile", '--window-size=1400,900', '--virtual-time-budget=30000',
    "--screenshot=$throw", $url)

  $n = 0
  while ($n++ -lt 150) {
    if (Test-Path $repFile) {
      $probe = Get-Content $repFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
      if ($probe -and $probe -match 'SUMMARY fails=') { break }
    }
    Start-Sleep -Milliseconds 400
  }
  $txt = Get-Content $repFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
  if (-not $txt -or $txt -notmatch 'SUMMARY fails=') {
    $report += "【$label】$name`n  拿不到诊断结果（页面没跑完 / 服务没起来）"
    $report += "`n  排查顺序：① 快照的 CSP 是否已摘掉（default-src 'none' 会拦掉 fetch）" +
               "`n            ② 用 -Keep 保留临时目录，把页面直接截图看黄色诊断框里有没有 PASS"
    $totalFails++
    continue
  }

  $f = 0
  if ($txt -match 'SUMMARY fails=(\d+)') { $f = [int]$Matches[1] }
  $totalFails += $f
  # 先把明细拼成一个字符串再 +=。
  # 写成 `$report += "头" + (数组) -join "`n"` 是错的：-join 会绑到整个拼接结果上，
  # 结果 $report 里塞进的是一个**字符串数组**，Write-Host 用空格分隔打印 →
  # 86 条断言挤成一行，交付检查里 `^\s+PASS` 也就一条都数不到（会显示「2 项通过」）。
  $detail = ($txt -split "`n" | Where-Object { $_ -match '^(PASS|FAIL|SUMMARY)' } |
    ForEach-Object { '  ' + $_ }) -join "`n"
  $report += "【$label】$name`n" + $detail
}

# 只清掉带我们临时 profile 的 msedge，别碰用户自己的浏览器
Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like "*$Tmp*" } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Stop-Job $job -ErrorAction SilentlyContinue
Remove-Job $job -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------- 输出
Write-Host ""
Write-Host "===== 回归验证：$(Split-Path $ScriptPath -Leaf) =====" -ForegroundColor Cyan
Write-Host ""
foreach ($r in $report) { Write-Host $r; Write-Host "" }

if ($Keep) { Write-Host "临时目录（-Keep）：$Tmp" -ForegroundColor Yellow }
else { Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue }

if ($totalFails -eq 0) {
  Write-Host "结论：全部通过（$($Snapshot.Count) 个模式快照）" -ForegroundColor Green
  Write-Host ""
  exit 0
} else {
  Write-Host "结论：$totalFails 项失败" -ForegroundColor Red
  Write-Host ""
  exit $totalFails
}
