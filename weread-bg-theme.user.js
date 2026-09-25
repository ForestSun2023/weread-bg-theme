// ==UserScript==
// @name         微信读书网页版 · 背景颜色主题
// @name:zh-CN   微信读书网页版 · 背景颜色主题
// @namespace    https://github.com/ForestSun2023
// @version      3.3.0
// @description  给微信读书网页版阅读页补上手机 App 才有的「亮度 / 颜色 / 背景」功能：白天三色（白 / 米黄 / 青绿）× 五种纸张背景。白天/黑夜沿用站点原生的「深色」按钮，黑夜模式完全用官方原装外观。
// @author       ForestSun
// @license      MIT
// @homepageURL  https://github.com/ForestSun2023/weread-bg-theme
// @supportURL   https://github.com/ForestSun2023/weread-bg-theme/issues
// @icon         https://raw.githubusercontent.com/ForestSun2023/weread-bg-theme/main/assets/icon-96.png
// @match        https://weread.qq.com/web/reader/*
// @match        https://weread.qq.com/web/*
// @run-at       document-idle
// @grant        none
// @noframes
// @downloadURL  https://raw.githubusercontent.com/ForestSun2023/weread-bg-theme/main/weread-bg-theme.user.js
// @updateURL    https://raw.githubusercontent.com/ForestSun2023/weread-bg-theme/main/weread-bg-theme.user.js
// ==/UserScript==

/*
 * 工作原理（基于对 weread.qq.com 阅读页 DOM 的实测）：
 *   · 阅读区背景画在 .readerContent .app_content 上，顶栏 .readerTopBar，悬浮按钮 .readerControls_item；
 *   · 正文是逐字绝对定位的 <span class="wr_absolute" data-wr-role="text">，颜色继承自 .readerChapterContent；
 *   · <body> 上的 wr_whiteTheme 是「浅色主题」开关，站点 CSS 的默认（无该类）即深色；
 *   · 右侧工具条 .readerControls 为 position:fixed; z-index:90，其子元素绝对定位可溢出到左侧。
 * 因此本脚本：
 *   1) 在 .readerControls 里插入一个「背景」按钮（位置与原生按钮一致、样式沿用 readerControls_item）；
 *   2) 用自带 <style> + :root CSS 变量 + !important 覆盖上述几处颜色，优先级高于站点规则；
 *   3) 只负责**白天**：一进黑夜就摘掉 data-wrbg、所有覆盖规则自动失效，
 *      阅读区/正文/位图整块交还站点原装深色主题，脚本只剩「全屏」一个按钮。
 *      昼夜切换**必须用站点原生的「深色」按钮**，脚本不自己造 —— 原因见 apply() 上方那段 ⚠️ 注释。
 */

(function () {
  'use strict';

  /* ==================== 可调开关 ==================== */

  // 开关面板的快捷键（不区分大小写）。输入框/编辑区里不会触发，见 install()
  const PANEL_HOTKEY = 'b';

  const STORE_KEY = 'wrbg.settings.v1';

  /* ==================== 配色预设 ==================== */

  // 纸纹 / 素纸 的颗粒层。浅色纸面上 10% 刚好；因为脚本只管白天，不需要第二档。
  const NOISE = 'url("data:image/svg+xml,' + encodeURIComponent(
    "<svg xmlns='http://www.w3.org/2000/svg' width='160' height='160'>" +
    "<filter id='n'>" +
    "<feTurbulence type='fractalNoise' baseFrequency='0.85' numOctaves='3' stitchTiles='stitch'/>" +
    "<feColorMatrix type='saturate' values='0'/>" +
    "</filter>" +
    "<rect width='160' height='160' filter='url(#n)' opacity='0.10'/>" +
    '</svg>'
  ) + '")';

  // 底色全部取自**手机版官方截图的逐张采样**（40 张 = 4 颜色 × 5 背景 × 2 轮）。
  // 官方有 4 套配色，但**黑那套已经撤掉**：它和另外三色差别太小（同一纹理在黑白下几乎一样），
  // 与其在白天模式里塞一个「看着像黑其实是深蓝」的选项，不如把黑夜整块交还站点原装外观。
  //   · bg    = 该配色在「背景·纯色」下的官方实测底色
  //   · text  = 正文字色
  const COLORS = [
    {
      id: 'white', name: '白色',
      bg: '#f8f8fa', text: '#0d141e', bar: '#f8f8fa', card: '#ffffff',
      panel: '#f4f5f7', line: 'rgba(33,40,50,.1)', icon: '#858c96', tooltip: '#858c96',
    },
    {
      id: 'sepia', name: '米黄',
      bg: '#f5efd9', text: '#3d3427', bar: '#f5efd9', card: '#fbf7ea',
      panel: '#f2eedd', line: 'rgba(90,72,45,.14)', icon: '#8a7d63', tooltip: '#8a7d63',
    },
    {
      id: 'green', name: '青绿',
      bg: '#c0edc6', text: '#2f3a2c', bar: '#c0edc6', card: '#dcf6e0',
      panel: '#c9ebcc', line: 'rgba(47,58,44,.14)', icon: '#6d7d68', tooltip: '#6d7d68',
    },
  ];

  // 当前该用哪套：直接用用户选的那套（选不到就退回白色）
  function currentColor() {
    return COLORS.find((c) => c.id === state.colorId) || COLORS[0];
  }

  /* ==================== 背景预设 ==================== */

  // 用 CSS 渐变 + inline SVG 噪点合成，不依赖任何外部图片，离线可用。
  //
  // 官方手机版有 5 种背景，且**同一种背景在不同颜色下色调不同**——
  // 实测：背景④在白色下是蓝天、米黄下是暖灰、青绿下是淡绿。
  // 所以每个背景按颜色各存一份实测值，全部来自官方 40 张截图
  //（4 颜色 × 5 背景 × 2 轮）的逐张采样。保持半透明/渐变而非贴图，理由有两条：
  //   ① 亮度滑杆仍然有效（做成不透明贴图的话，底色一压暗就被完全盖住）
  //   ② 不引入任何外部图片，脚本仍是单文件、离线可用
  //
  // 半透明层的取值方法：底色记 B、官方实测记 T，层用 alpha=0.5 时
  // 合成结果是 0.5*层 + 0.5*B，所以**层 = 2T − B**（下面每个值都是这么反推的）。
  // 官方那几张纹理其实是照片（云底部是雪山、月是环形山月球），渐变只能还原明暗走向。
  const BACKGROUNDS = [
    {
      id: 'solid', name: '纯色',
      image: 'none',
    },
    {
      // 官方背景②：细纸纹（半透明值按「叠在该颜色上 ≈ 官方实测值」反推，a=0.5）
      id: 'paper', name: '纸纹',
      grain: true,
      per: {
        white: 'linear-gradient(180deg, rgba(255,255,254,.5), rgba(252,252,250,.5))',
        sepia: 'linear-gradient(180deg, rgba(253,229,193,.5), rgba(251,227,191,.5))',
        green: 'linear-gradient(180deg, rgba(248,249,252,.5), rgba(252,249,254,.5))',
      },
    },
    {
      // 官方背景③：素净纸（偏冷灰，会明显压掉底色，青绿下降需要更高 alpha）
      id: 'plain', name: '素纸',
      grain: true,
      per: {
        white: 'linear-gradient(180deg, rgba(248,250,252,.5), rgba(246,248,250,.5))',
        sepia: 'linear-gradient(180deg, rgba(253,249,255,.5), rgba(251,247,255,.5))',
        green: 'linear-gradient(180deg, rgba(248,238,255,.75), rgba(246,236,255,.75))',
      },
    },
    {
      // 官方背景④：下半部一大片柔和亮光（实测没有明确的小光团）
      id: 'cloud', name: '云',
      per: {
        // 官方实测 (194,214,232) → (228,235,242)，底色 #f8f8fa → 层 = 2T−B
        white: 'radial-gradient(ellipse 62% 46% at 72% 86%, #ffffff 0 26%, #ffffff00 100%),' +
               'linear-gradient(180deg, rgba(140,180,214,.5), rgba(208,222,234,.5))',
        sepia: 'radial-gradient(ellipse 62% 46% at 72% 86%, #fdfaf6 0 26%, #fdfaf600 100%),' +
               'linear-gradient(180deg, rgba(215,203,213,.5), rgba(255,227,193,.5))',
        green: 'radial-gradient(ellipse 62% 46% at 72% 86%, #ffffff 0 26%, #ffffff00 100%),' +
               'linear-gradient(180deg, rgba(232,255,238,.5), rgba(250,253,242,.5))',
      },
    },
    {
      // 官方背景⑤：右上角一轮月亮。
      // 实测（三色一致）：中心 x≈88~92%、y≈2.4~3.4%，可见宽约 260px ≈ 阅读区宽的 21%，
      // 即圆心基本压在顶边上方，只露出下半轮。
      id: 'moon', name: '月',
      per: {
        // 官方实测 (184,207,230) → (222,231,240)，底色 #f8f8fa → 层 = 2T−B
        white: 'radial-gradient(ellipse 10.5% 9% at 89% 1%, #ffffff 0 62%, #ffffff00 100%),' +
               'linear-gradient(180deg, rgba(120,166,210,.5), rgba(196,214,230,.5))',
        // 官方实测 (228,217,208) → (214,175,171)，底色 #f5efd9
        sepia: 'radial-gradient(ellipse 10.5% 9% at 89% 1%, #fdfaf4 0 62%, #fdfaf400 100%),' +
               'linear-gradient(180deg, rgba(211,195,199,.5), rgba(183,111,125,.5))',
        // 官方实测 (176,217,185) → (226,236,226) → (231,232,226)：中段起得很快，
        // 两段线性拉不出来，所以中间加一个实测的折点
        green: 'radial-gradient(ellipse 10.5% 9% at 89% 1%, #ffffff 0 62%, #ffffff00 100%),' +
               'linear-gradient(180deg, rgba(160,197,172,.5) 0%, rgba(255,235,254,.5) 50%, rgba(255,227,254,.5) 100%)',
      },
    },
  ];

  // 取某个背景在指定配色下的图层；grain 的再加一层颗粒
  function bgImage(bg, color) {
    const img = (bg.per && bg.per[color.id]) || bg.image || 'none';
    if (img === 'none') return 'none';
    return bg.grain ? NOISE + ', ' + img : img;
  }
  function bgSize(bg) { return bg.grain ? '160px 160px, cover' : 'cover'; }
  function bgRepeat(bg) { return bg.grain ? 'repeat, no-repeat' : 'no-repeat'; }

  /* ==================== 设置读写 ==================== */

  const DEFAULTS = { colorId: 'white', bgId: 'solid', brightness: 1 };

  function loadSettings() {
    try {
      const raw = localStorage.getItem(STORE_KEY);
      if (!raw) return Object.assign({}, DEFAULTS);
      const s = JSON.parse(raw);
      return {
        colorId: COLORS.some((c) => c.id === s.colorId) ? s.colorId : DEFAULTS.colorId,
        bgId: BACKGROUNDS.some((b) => b.id === s.bgId) ? s.bgId : DEFAULTS.bgId,
        brightness: typeof s.brightness === 'number' && s.brightness >= 0 && s.brightness <= 1
          ? s.brightness : DEFAULTS.brightness,
      };
    } catch (e) {
      return Object.assign({}, DEFAULTS);
    }
  }

  function saveSettings() {
    try {
      localStorage.setItem(STORE_KEY, JSON.stringify(state));
    } catch (e) { /* 隐私模式下忽略 */ }
  }

  let state = loadSettings();

  /* ==================== 颜色工具 ==================== */

  function hexToRgb(hex) {
    let h = String(hex).replace('#', '');
    if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2];
    const n = parseInt(h, 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }

  // 把颜色按系数 k 压暗（k=1 原样），用于实现「亮度」——不去动 filter，
  // 避免 filter 改变绝对定位正文的包含块而错位。
  function scaleHex(hex, k) {
    const rgb = hexToRgb(hex).map((v) => Math.max(0, Math.min(255, Math.round(v * k))));
    return 'rgb(' + rgb.join(',') + ')';
  }

  /* ==================== 样式注入 ==================== */

  const STYLE_ID = 'wrbg-style';

  const CSS = `
/* ---------- 阅读区：底色 + 纸张背景 ----------
   纵向阅读画在 .readerContent .app_content 上；
   横向/双栏阅读（.wr_horizontalReader）用的是另一套容器，且 .app_content / .readerContent
   在那套 DOM 里根本不存在，所以必须一并列出，否则双栏模式背景完全不生效。 */
html[data-wrbg] body,
html[data-wrbg] .app,
html[data-wrbg] .app_content,
html[data-wrbg] .readerContent,
html[data-wrbg] .readerContent .app_content,
html[data-wrbg] .readerChapterContent_container,
html[data-wrbg] .readerChapterContent,
html[data-wrbg] .wr_horizontalReader,
html[data-wrbg] .wr_horizontalReader_app_content {
  background-color: var(--wrbg-bg) !important;
  background-image: var(--wrbg-image) !important;
  background-size: var(--wrbg-size) !important;
  background-repeat: var(--wrbg-repeat) !important;
  background-attachment: fixed !important;
}

/* ---------- canvas 位图 ----------
   引擎只把「当前视口那一屏」留成逐字 DOM span，其余光栅化成 <canvas>。
   位图**只有字形、背景透明**（解码存档确认：1683x1992 采样 1640 点，全透明 1504、不透明白 0），
   所以浅色主题下深色字本来就对，不需要染色；这里只用它跟随「亮度」。 */
html[data-wrbg] canvas { filter: var(--wrbg-canvas-filter, none); }

/* ---------- 正文颜色 ----------
   黑色那套也走这条规则：DOM 那一屏的字色同样由 --wrbg-text 给，
   和反相后的位图（见 apply 的 invert）算出来是同一个灰，滚动时不会露接缝。 */
html[data-wrbg] .readerChapterContent,
html[data-wrbg] .readerChapterContent *,
html[data-wrbg] .renderTargetContent .wr_absolute,
html[data-wrbg] .readerFooter_button {
  color: var(--wrbg-text) !important;
  text-decoration-color: var(--wrbg-text) !important;
}

/* ---------- 顶栏 / 底栏 / 悬浮按钮 ---------- */
html[data-wrbg] .readerTopBar {
  background-color: var(--wrbg-bar) !important;
  border-bottom-color: var(--wrbg-line) !important;
}
html[data-wrbg] .readerTopBar:after { opacity: .18; }
html[data-wrbg] .readerBottomBar { background-color: var(--wrbg-bar) !important; }
html[data-wrbg] .readerBottomBar.showShadow { box-shadow: 0 -.3px 20px rgba(0,0,0,.16) !important; }
/* 横向/双栏模式的页码、章节标题、翻页按钮 */
html[data-wrbg] .renderTargetPageInfo,
html[data-wrbg] .renderTargetPageInfo_header_chapterTitle,
html[data-wrbg] .renderTarget_pager_button,
html[data-wrbg] .renderTarget_pager_content { color: var(--wrbg-tooltip) !important; }
html[data-wrbg] .readerControls_item {
  background-color: var(--wrbg-card) !important;
  box-shadow: 0 4px 20px rgba(0,0,0,.10) !important;
}
html[data-wrbg] .wr_tooltip_container .wr_tooltip_item { color: var(--wrbg-tooltip) !important; }

/* ---------- 脚本自己的按钮在两种模式下的表现 ---------- */
/* 白天：脚本接管，图标跟配色走 */
html[data-wrbg] .wrbg-btn svg { color: var(--wrbg-icon) !important; }
/* 黑夜（以及非阅读页 / 首帧）：用站点自己的图标灰，保证在官方深色底上看得清 */
html:not([data-wrbg]) .wrbg-btn svg { color: #858c96 !important; }

/* ---------- 「背景」按钮只在白天出现 ----------
   黑夜模式整块交还站点原装外观，这个面板没有用武之地。
   靠 data-wrbg 的存无来切换：黑夜下 apply() 会摘掉它，规则自动生效，不用额外状态。
   「全屏」按钮不受这条规则影响（它不带 wrbg-theme-host）。 */
html:not([data-wrbg]) .wrbg-theme-host { display: none !important; }
/* 脚本自己的 tooltip：默认隐藏，鼠标移到按钮上才显示。
   内联的 display:none 用 !important 覆盖（author 的 !important 优先于内联普通声明）。 */
.wrbg-tip-host .wr_tooltip_item { display: none; }
.wrbg-tip-host:hover .wr_tooltip_item { display: block !important; }
/* 点 F11 全屏下的按钮时，强制把提示显示出来（因为脚本没法帮他退出） */
.wrbg-tip-host.wrbg-tip-force .wr_tooltip_item { display: block !important; }

/* ---------- 站点弹层跟随配色 ---------- */
html[data-wrbg] .readerCatalog,
html[data-wrbg] .readerNotePanel,
html[data-wrbg] .font-panel-content,
html[data-wrbg] .reader_float_panel_container {
  background-color: var(--wrbg-panel) !important;
  color: var(--wrbg-text) !important;
}

/* ================= 本脚本自己的面板 ================= */
/* 两个按钮（全屏、背景）纵向排列，间距与站点 .readerControls>* 的 24px 一致。
   遮罩与面板都是 out-of-flow，不受 flex 布局影响。 */
.wrbg-wrap { position: static; display: flex; flex-direction: column; gap: 24px; }

.wrbg-mask {
  /* 不能写 inset:0。
     双栏模式下 .readerControls 带 transform:translateY(-50%)，而 transform 会让元素
     成为 position:fixed 后代的包含块 —— 于是 inset:0 的遮罩不再是整个视口，而是被缩成
     「工具条那一格」(48×504)，在页面上表现为工具条背后一条深色竖条。
     这里用负的 100vw / 100vh 向外扩，无论包含块是谁，都保证盖满整个视口。 */
  position: fixed;
  top: -100vh; left: -100vw; right: -100vw; bottom: -100vh;
  z-index: 109;
  background: rgba(0, 0, 0, .07);
  display: none;
}

.wrbg-panel {
  position: absolute; z-index: 110;
  right: 96px; bottom: 0;
  width: 440px; max-width: calc(100vw - 150px);
  max-height: calc(100vh - 130px);
  box-sizing: border-box; overflow: auto;
  padding: 20px 18px 26px;
  border-radius: 16px;
  background-color: var(--wrbg-panel, #f4f5f7);
  box-shadow: 0 10px 50px rgba(0, 0, 0, .18);
  transition: background-color .2s ease-in-out;
  display: none;
  scrollbar-width: none;
  font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Microsoft YaHei", sans-serif;
  -webkit-user-select: none; user-select: none;
}
.wrbg-panel::-webkit-scrollbar { display: none; }
.wrbg-panel[data-open="1"] { display: block; }

/* ---------- 亮度 ---------- */
.wrbg-brightness { display: flex; align-items: center; gap: 12px; padding: 2px 4px 0; }
.wrbg-sun { width: 20px; height: 20px; flex: none; color: var(--wrbg-tooltip, #858c96); }
.wrbg-range { -webkit-appearance: none; appearance: none; flex: 1; height: 28px; background: transparent; cursor: pointer; }
.wrbg-range::-webkit-slider-runnable-track {
  height: 28px; border-radius: 14px; background: var(--wrbg-track);
}
.wrbg-range::-webkit-slider-thumb {
  -webkit-appearance: none; appearance: none;
  width: 44px; height: 44px; margin-top: -8px; border-radius: 50%;
  background: #fff; box-shadow: 0 2px 8px rgba(0, 0, 0, .2);
}
.wrbg-range::-moz-range-track { height: 28px; border-radius: 14px; background: var(--wrbg-track); }
.wrbg-range::-moz-range-thumb {
  width: 44px; height: 44px; border: 0; border-radius: 50%;
  background: #fff; box-shadow: 0 2px 8px rgba(0, 0, 0, .2);
}

/* ---------- 分区与色块 ---------- */
.wrbg-label { font-size: 12px; line-height: 17px; margin: 20px 0 10px 2px; color: var(--wrbg-tooltip, #858c96); }
.wrbg-row { display: flex; flex-wrap: wrap; gap: 12px; }
.wrbg-swatch {
  position: relative;
  width: 56px; height: 44px;
  box-sizing: border-box;
  border: 2px solid transparent;
  border-radius: 10px;
  cursor: pointer;
  overflow: hidden;
  transition: border-color .15s ease, box-shadow .15s ease;
}
.wrbg-swatch:hover { border-color: rgba(180, 150, 100, .5); }
.wrbg-swatch[data-active="1"] {
  border-color: #c8a06a;
  box-shadow: 0 0 0 2px rgba(200, 160, 106, .22);
}
.wrbg-foot {
  margin-top: 18px; padding-top: 14px;
  border-top: 1px solid var(--wrbg-line);
  display: flex; align-items: center; justify-content: space-between; gap: 12px;
}
.wrbg-reset {
  font-size: 12px; line-height: 1; padding: 8px 12px; border-radius: 8px; cursor: pointer;
  border: 1px solid var(--wrbg-line); background: transparent; flex: none;
  color: var(--wrbg-tooltip, #858c96);
}
.wrbg-reset:hover { border-color: #c8a06a; color: #c8a06a; }

/* 亮度百分比读数 */
.wrbg-pct {
  flex: none; width: 36px; text-align: right; font-size: 12px;
  font-variant-numeric: tabular-nums;
  color: var(--wrbg-tooltip, #858c96);
}
`;

  function ensureStyle() {
    if (document.getElementById(STYLE_ID)) return;
    const el = document.createElement('style');
    el.id = STYLE_ID;
    el.textContent = CSS;
    (document.head || document.documentElement).appendChild(el);
  }

  /* ==================== 应用设置 ==================== */

  // 脚本只负责**白天**。黑夜交给站点自带的深色模式 —— 它本来就完整
  //（面板、插图、正文位图逐帧重绘全都有），脚本再压一层只会做出「一半深一半浅」。
  //
  // 反面教材：v1.8.0 / v2.0.0 试过「黑夜下脚本自己刷底色」和「脚本把站点钉在浅色 + 藏掉深色按钮」，
  // 两条路都不行 —— 前者会和站点深色主题抢同一片区域，正文被两套规则来回改，字色就花了；
  // 后者等于把官方的黑夜模式整个废掉。所以现在回到最省事也最稳的分工：
  // **一进黑夜就摘掉 data-wrbg，所有覆盖规则自动失效，脚本什么都不做。**
  function siteIsDark() {
    return !!document.body && !document.body.classList.contains('wr_whiteTheme');
  }

  // ⚠️ 这里**故意没有**「自己造一个白天/黑夜切换按钮」的代码，原因值得写下来：
  // v3.0.0 加过那么一个按钮，它只翻 body 上的 wr_whiteTheme 类。
  // 结果从黑夜切回白天时，正文会变成「浅色字压在浅色纸上」几乎看不见 ——
  // 因为阅读器的正文有一部分是引擎光栅化进 <canvas> 的**位图**，字色在绘制时就烤进去了；
  // 只翻 CSS 类不会通知引擎重绘，于是它还以为在黑夜、继续按浅色画字。
  // 站点原生的「深色」按钮走的是引擎自己的状态，重绘时机对，所以没有这个毛病。
  // 结论：**昼夜这个开关必须留给站点自己**，脚本只跟着它的类变化切换接管/让位。

  function apply() {
    const root = document.documentElement;

    // 黑夜：脚本完全让位。
    // 摘掉 data-wrbg → 阅读区、正文颜色、位图 filter、弹层配色全部交还站点原装；
    // 同时 CSS 会把「背景」按钮一并藏掉（黑夜下它没有用武之地），只留「全屏」——
    // 这就是需求里的「黑夜模式纯用官方原装」。
    if (siteIsDark()) {
      root.removeAttribute('data-wrbg');
      // 再把白天写在 <html> 上的 --wrbg-* 内联变量一并清掉。
      // 覆盖规则全都挂在 html[data-wrbg] 上，属性一摘它们就失效了 —— 变量留着本来也没人读。
      // 但「没人读」是靠**每条规则都记得写作用域**撑着的，这种承诺太脆：
      // 以后谁新加一条忘了带作用域的规则，黑夜下就会静默串色，而且极难查。
      // 变量一清，「黑夜下脚本对页面零影响」就从一句承诺变成结构性事实。
      // 不维护第二份变量名单，直接扫 <html> 现有的内联声明（倒着删，避免下标漂移）。
      for (let i = root.style.length - 1; i >= 0; i--) {
        const prop = root.style[i];
        if (prop.indexOf('--wrbg-') === 0) root.style.removeProperty(prop);
      }
      return;
    }

    const color = currentColor();
    const bg = BACKGROUNDS.find((b) => b.id === state.bgId) || BACKGROUNDS[0];

    // 亮度：背景压得更狠、文字压得轻一些，保证对比度不会一起塌掉
    const bgK = 0.40 + 0.60 * state.brightness;
    const fgK = 0.74 + 0.26 * state.brightness;

    // canvas 位图只有字形、背景透明（解码存档确认：1683x1992 采样 1640 点，
    // 全透明 1504、不透明白 0），所以引擎画的就是深色字，本来就对；
    // 只需要让亮度跟着一起压，否则滚过去的区域（位图）会比可见区（DOM）更亮。
    // 用和 DOM 文字**同一个 fgK**，两屏字色同步，滚动时不会露出接缝。
    const filter = Math.abs(fgK - 1) > 0.005
      ? 'brightness(' + fgK.toFixed(3) + ')'
      : 'none';

    const vars = {
      '--wrbg-bg': scaleHex(color.bg, bgK),
      '--wrbg-text': scaleHex(color.text, fgK),
      '--wrbg-bar': scaleHex(color.bar, bgK),
      '--wrbg-card': scaleHex(color.card, bgK),
      '--wrbg-panel': scaleHex(color.panel, bgK),
      '--wrbg-icon': scaleHex(color.icon, fgK),
      '--wrbg-tooltip': scaleHex(color.tooltip, fgK),
      '--wrbg-line': color.line,
      '--wrbg-track': 'rgba(0,0,0,.08)',
      '--wrbg-image': bgImage(bg, color),
      '--wrbg-size': bgSize(bg),
      '--wrbg-repeat': bgRepeat(bg),
      '--wrbg-canvas-filter': filter,
    };
    Object.keys(vars).forEach((k) => root.style.setProperty(k, vars[k]));

    root.setAttribute('data-wrbg', color.id);
    root.setAttribute('data-wrbg-bg', bg.id);

    scheduleSelfCheck();
  }

  /* ==================== 主题生效自检 ==================== */

  // 站点改版的主要危害是「静默失效」：按钮还在、控制台不报错，但颜色就是不生效。
  // 保持最简：只比字符串（--wrbg-bg 与计算值去掉空格后必然相等），不做颜色解析。
  function themeMismatch() {
    const want = getComputedStyle(document.documentElement).getPropertyValue('--wrbg-bg').replace(/\s+/g, '');
    if (!want) return '';
    const bad = [];
    let found = 0;
    ['body', '.app_content', '.readerChapterContent', '.wr_horizontalReader_app_content'].forEach((sel) => {
      const el = document.querySelector(sel);
      if (!el) return;                                   // 该模式没有这个容器，正常
      found++;
      const cs = getComputedStyle(el);
      const got = cs.backgroundColor.replace(/\s+/g, '');
      if (got === 'rgba(0,0,0,0)' || got === want) return;   // 透明的不算失败
      bad.push(sel + ' 实际 ' + cs.backgroundColor);
    });
    // 阅读页已经渲染（工具条在），却一个预期容器都没找到 → 选择器大概失效了
    if (!bad.length && !found && document.querySelector('.readerControls')) {
      bad.push('未找到任何预期容器，选择器可能已失效');
    }
    return bad.join('；');
  }

  let selfCheckTimer = null;
  let selfCheckWarned = false;

  function scheduleSelfCheck() {
    clearTimeout(selfCheckTimer);
    // 站点给这些容器加了 .2s 的 background-color 过渡，等 1.2s 再测就必然已经稳定，
    // 所以不需要「连测两次确认」那一套。
    selfCheckTimer = setTimeout(() => {
      const bad = themeMismatch();
      if (!bad) { selfCheckWarned = false; return; }     // 恢复正常 → 下次还能再报
      if (selfCheckWarned) return;                       // 同一个问题不刷屏
      selfCheckWarned = true;
      console.warn(
        '[wrbg] 主题未生效，微信读书可能改版了。\n' +
        '  预期底色：' + getComputedStyle(document.documentElement).getPropertyValue('--wrbg-bg').trim() + '\n' +
        '  实际不符：' + bad + '\n' +
        '  请运行「工具/weread-probe2.js」，把报告反馈给脚本作者。'
      );
    }, 1200);
  }

  /* ==================== 面板 UI ==================== */

  const SUN_SVG = '<svg class="wrbg-sun" viewBox="0 0 24 24" fill="none" stroke="currentColor" ' +
    'stroke-width="1.6" stroke-linecap="round"><circle cx="12" cy="12" r="4"/>' +
    '<path d="M12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5.2 5.2l1.4 1.4M17.4 17.4l1.4 1.4' +
    'M18.8 5.2l-1.4 1.4M6.6 17.4l-1.4 1.4"/></svg>';

  const THEME_ICON = '<svg width="24" height="24" viewBox="0 0 24 24" fill="none" ' +
    'stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">' +
    '<circle cx="12" cy="12" r="4.2"/>' +
    '<path d="M12 2.6v2.2M12 19.2v2.2M2.6 12h2.2M19.2 12h2.2' +
    'M5.4 5.4l1.6 1.6M17 17l1.6 1.6M18.6 5.4L17 7M7 17l-1.6 1.6"/></svg>';

  // 全屏按钮：进入是全屏「展开」图标，已全屏时换成「收拢」图标
  const EXPAND_ICON = '<svg width="24" height="24" viewBox="0 0 24 24" fill="none" ' +
    'stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">' +
    '<path d="M4 9.5V4h5.5M20 9.5V4h-5.5M4 14.5V20h5.5M20 14.5V20h-5.5"/></svg>';

  const COMPRESS_ICON = '<svg width="24" height="24" viewBox="0 0 24 24" fill="none" ' +
    'stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">' +
    '<path d="M9.5 4v5.5H4M14.5 4v5.5H20M9.5 20v-5.5H4M14.5 20v-5.5H20"/></svg>';

  // 色块预览：底色用当前配色，再叠上该颜色对应的背景图层，所见即所得
  function swatchStyle(color, bg) {
    const img = bgImage(bg, color);
    return 'background-color:' + color.bg + ';' +
      'background-image:' + img + ';' +
      'background-size:' + (img === 'none' ? 'auto' : bgSize(bg)) + ';' +
      'background-repeat:' + bgRepeat(bg) + ';';
  }

  let panelEl = null;
  let rowColorEl = null;
  let rowBgEl = null;
  let rangeEl = null;
  let pctEl = null;
  let wrapEl = null;

  function renderSwatches() {
    if (!rowColorEl || !rowBgEl) return;
    const current = currentColor();

    // 颜色行：四套底色任何时候都在（黑只是第四种，不再跟「模式」绑定）
    rowColorEl.textContent = '';
    COLORS.forEach((c) => {
      const item = document.createElement('div');
      item.className = 'wrbg-swatch';
      item.title = c.name;
      item.dataset.active = c.id === state.colorId ? '1' : '0';
      item.style.cssText = swatchStyle(c, BACKGROUNDS[0]);
      item.addEventListener('click', () => {
        state.colorId = c.id;
        apply(); saveSettings(); renderSwatches();
      });
      rowColorEl.appendChild(item);
    });

    // 背景行：五种纹理对每种底色都各有一份实测值，预览底色跟着当前配色走
    rowBgEl.textContent = '';
    BACKGROUNDS.forEach((b) => {
      const item = document.createElement('div');
      item.className = 'wrbg-swatch';
      item.title = b.name;
      item.dataset.active = b.id === state.bgId ? '1' : '0';
      item.style.cssText = swatchStyle(current, b);
      item.addEventListener('click', () => {
        state.bgId = b.id;
        apply(); saveSettings(); renderSwatches();
      });
      rowBgEl.appendChild(item);
    });
  }

  function openPanel(open) {
    if (!panelEl) return;
    panelEl.dataset.open = open ? '1' : '0';
    const mask = wrapEl && wrapEl.querySelector('.wrbg-mask');
    if (mask) mask.style.display = open ? 'block' : 'none';
    if (open) clampPanel();
    else panelEl.style.removeProperty('transform');
  }

  // 窄窗口下把面板推回视口内。
  // 面板的包含块是工具条（不是视口），改 left/right 会以工具条为基准，算不准；
  // 所以用 transform 平移 —— 它永远以自身当前位置为基准，与包含块无关。
  function clampPanel() {
    if (!panelEl) return;
    panelEl.style.removeProperty('transform');
    const r = panelEl.getBoundingClientRect();
    const m = 12;
    const dx = r.left < m ? (m - r.left) : (r.right > innerWidth - m ? (innerWidth - m - r.right) : 0);
    const dy = r.top < m ? (m - r.top) : (r.bottom > innerHeight - m ? (innerHeight - m - r.bottom) : 0);
    if (dx || dy) panelEl.style.transform = 'translate(' + Math.round(dx) + 'px,' + Math.round(dy) + 'px)';
  }

  /* ==================== 全屏 ==================== */

  // ⚠️ JS 无法触发浏览器级的 F11（那是浏览器自身功能，网页没有权限）。
  // 但全屏 <html>（整个页面）在视觉上与 F11 等价：浏览器 UI 全部隐藏、页面铺满屏幕，
  // 而站点布局完全不受影响 —— 只是视口变大，排版引擎照常重排，与按 F11 的行为一致。
  //
  // 反例（不要这么做）：去全屏某个内容元素（如 .app_content）。那样必须把该元素硬撑成
  // 视口大小，还得手动隐藏顶栏、并用 setInterval 轮询去纠正底栏位置 ——
  // 布局 hack 一堆，还容易和站点的重排逻辑打架。

  let fsBtn = null;
  let fsTip = null;

  // 非全屏时浏览器 UI（标签栏 + 地址栏）占掉的高度，作为判断 F11 的基线
  let chromeH = 0;

  function fullscreenEl() {
    return document.fullscreenElement || document.webkitFullscreenElement || null;
  }

  // 浏览器原生全屏（F11）**没有 API 可查，也没有事件可监听**，只能推断。
  // 共同前提：视口高度必须占满屏幕；在此之上两条互补信号 ——
  //   有基线时：浏览器 UI 的高度相对基线塌掉（F11 时归零）
  //   无基线时：视口盖过了 screen.availHeight（即盖住任务栏），只有全屏才会这样
  // 基线的学习挪进了 resize 监听（见 install），少一个函数、少一次独立调用。
  function isNativeFullscreen() {
    const sc = window.screen || {};
    const ih = window.innerHeight || 0;
    if (!sc.height || ih < sc.height - 40) return false;   // 没占满屏幕高度 → 不是全屏
    if (chromeH > 0) return (window.outerHeight || 0) - ih < chromeH * 0.5;
    return sc.availHeight > 0 && ih > sc.availHeight;
  }

  // JS 无法退出浏览器原生全屏（F11）—— 没有对应 API，这是浏览器的安全边界。
  // 所以识别到 F11 时只能弹提示，让用户自己按 F11 / Esc。
  let fsHintTimer = null;
  function showFullscreenHint() {
    if (!fsTip) return;
    const host = fsTip.parentElement;
    fsTip.textContent = '浏览器全屏请按 F11 或 Esc 退出';
    if (host) host.classList.add('wrbg-tip-force');
    clearTimeout(fsHintTimer);
    fsHintTimer = setTimeout(() => {
      if (host) host.classList.remove('wrbg-tip-force');
      syncFullscreenUI();
    }, 2600);
  }

  function toggleFullscreen() {
    if (fullscreenEl()) {                 // 脚本自己开的全屏 → 能退出
      const exit = document.exitFullscreen || document.webkitExitFullscreen;
      if (exit) exit.call(document);
      return;
    }
    if (isNativeFullscreen()) {           // F11 原生全屏 → 退不了，给提示
      showFullscreenHint();
      return;
    }
    const el = document.documentElement;
    const req = el.requestFullscreen || el.webkitRequestFullscreen;
    if (!req) return;                     // 浏览器不支持：安静降级，不报错
    try {
      const p = req.call(el);
      if (p && typeof p.catch === 'function') p.catch(() => { /* 被拒绝就算了 */ });
    } catch (e) { /* ignore */ }
  }

  function syncFullscreenUI() {
    if (!fsBtn) return;
    // 顺手学一次「浏览器 UI 高度」基线。本函数在初始化 / resize / fullscreenchange
    // 都会被调用，所以基线总是新鲜的；全屏时 ui≈0，不会把基线覆盖成 0。
    const ui = (window.outerHeight || 0) - window.innerHeight;
    if (ui > 4) chromeH = ui;
    const apiOn = !!fullscreenEl();
    const nativeOn = !apiOn && isNativeFullscreen();
    fsBtn.innerHTML = (apiOn || nativeOn) ? COMPRESS_ICON : EXPAND_ICON;
    // F11 状态下按钮退不出全屏，文案里直接写明要按 F11，避免误导
    const label = apiOn ? '退出全屏' : (nativeOn ? '退出全屏（按 F11）' : '全屏阅读');
    fsBtn.title = label;
    if (fsTip) fsTip.textContent = label;
  }

  // 造一个「站点风格按钮 + 悬停提示」的组合
  function makeTooltipButton(iconSvg, label, cls) {
    const host = document.createElement('div');
    host.className = 'wr_tooltip_container wrbg-tip-host';
    host.style.setProperty('--offset', '6px');

    const btn = document.createElement('button');
    btn.className = 'readerControls_item ' + cls;
    btn.type = 'button';
    btn.title = label;
    btn.innerHTML = iconSvg;

    const tip = document.createElement('div');
    tip.className = 'wr_tooltip_item wr_tooltip_item--right';
    tip.textContent = label;
    // 站点自己的 tooltip 靠内联 display:none 隐藏、由站点 JS 在 hover 时显示；
    // 我们的容器站点不认识，所以要自己藏起来，再用 CSS :hover 显示。
    tip.style.display = 'none';

    host.appendChild(btn);
    host.appendChild(tip);
    return { host: host, btn: btn, tip: tip };
  }

  // 把 state 回灌到面板控件（滑杆 / 百分比），供 wrbg.set、reset 复用
  function syncControls() {
    const v = String(Math.round(state.brightness * 100));
    if (rangeEl) rangeEl.value = v;
    if (pctEl) pctEl.textContent = v + '%';
  }

  function buildUI() {
    const wrap = document.createElement('div');
    wrap.className = 'wrbg-wrap';

    const mask = document.createElement('div');
    mask.className = 'wrbg-mask';
    mask.addEventListener('click', () => openPanel(false));

    const theme = makeTooltipButton(THEME_ICON, '背景', 'wrbg-btn');
    theme.host.classList.add('wrbg-theme-host');   // 黑夜下整块隐藏，见 CSS
    theme.btn.addEventListener('click', (e) => {
      e.stopPropagation();
      openPanel(panelEl.dataset.open !== '1');
    });

    const fs = makeTooltipButton(EXPAND_ICON, '全屏阅读', 'wrbg-btn wrbg-fs-btn');
    fs.btn.addEventListener('click', (e) => {
      e.stopPropagation();
      toggleFullscreen();
    });
    fsBtn = fs.btn;
    fsTip = fs.tip;
    syncFullscreenUI();

    const panel = document.createElement('div');
    panel.className = 'wrbg-panel';
    panel.dataset.open = '0';

    const brightness = document.createElement('div');
    brightness.className = 'wrbg-brightness';
    brightness.insertAdjacentHTML('beforeend', SUN_SVG);

    const range = document.createElement('input');
    range.type = 'range';
    range.className = 'wrbg-range';
    range.min = '0';
    range.max = '100';
    range.step = '1';
    range.value = String(Math.round(state.brightness * 100));

    // 亮度百分比读数：便于把同一套设置复现到别的机器
    const pct = document.createElement('span');
    pct.className = 'wrbg-pct';
    pct.textContent = range.value + '%';

    range.addEventListener('input', () => {
      state.brightness = Number(range.value) / 100;
      pct.textContent = range.value + '%';
      apply();
    });
    range.addEventListener('change', saveSettings);
    brightness.appendChild(range);
    brightness.appendChild(pct);

    const secColor = document.createElement('div');
    secColor.innerHTML = '<div class="wrbg-label">颜色</div>';
    const rowColor = document.createElement('div');
    rowColor.className = 'wrbg-row wrbg-row-color';
    secColor.appendChild(rowColor);

    const secBg = document.createElement('div');
    secBg.innerHTML = '<div class="wrbg-label">背景</div>';
    const rowBg = document.createElement('div');
    rowBg.className = 'wrbg-row wrbg-row-bg';
    secBg.appendChild(rowBg);

    const foot = document.createElement('div');
    foot.className = 'wrbg-foot';

    const reset = document.createElement('button');
    reset.className = 'wrbg-reset';
    reset.type = 'button';
    reset.textContent = '恢复默认';
    reset.addEventListener('click', () => {
      state = Object.assign({}, DEFAULTS);
      apply(); saveSettings(); renderSwatches(); syncControls();
    });

    foot.appendChild(reset);

    panel.appendChild(brightness);
    panel.appendChild(secColor);
    panel.appendChild(secBg);
    panel.appendChild(foot);

    wrap.appendChild(mask);
    wrap.appendChild(theme.host);
    wrap.appendChild(fs.host);
    wrap.appendChild(panel);

    wrapEl = wrap;
    panelEl = panel;
    rowColorEl = rowColor;
    rowBgEl = rowBg;
    rangeEl = range;
    pctEl = pct;

    renderSwatches();

    // 点面板内部不要把事件冒泡给站点的「点击正文隐藏工具条」逻辑
    panel.addEventListener('click', (e) => e.stopPropagation());

    return wrap;
  }

  /* ==================== 注入 ==================== */

  function isReaderPage() {
    return /^\/web\/reader\//.test(location.pathname);
  }

  function inject() {
    if (!isReaderPage() || !document.body) return;
    const controls = document.querySelector('.readerControls');
    if (!controls) return;

    ensureStyle();

    let wrap = controls.querySelector('.wrbg-wrap');
    if (!wrap) wrap = buildUI();

    // 始终挂在工具条【末尾】，即所有原生按钮之后（用户明确要求的固定位置）。
    // 这样也彻底避开了「拿站点按钮当 insertBefore 参照节点」那类坑
    // （v1.0.0 按钮不出现的根因就是它：站点把按钮包在 .wr_tooltip_container 里，
    //  拿后代当参照会抛 NotFoundError）。
    try {
      if (controls.lastElementChild !== wrap) controls.appendChild(wrap);
    } catch (e) { /* 放弃本轮，等下次重试 */ }
  }

  /* ==================== 启动 ==================== */

  let scheduled = false;

  function scheduleInject() {
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(() => {
      scheduled = false;
      inject();
    });
  }

  let lastUrl = location.href;
  function onMaybeNavigate() {
    if (location.href === lastUrl) return;
    lastUrl = location.href;
    if (isReaderPage()) activate();     // 首页 → 阅读页（前端路由）也要能激活
  }

  let installed = false;
  let activatedOnce = false;

  // ---- 一次性安装：观察器 / 监听器 ----
  // 这里**不能**按「是不是阅读页」提前 return。否则从首页/书架用前端路由切进阅读页
  //（页面不刷新）时，观察器根本没装上，也就没人会发现 URL 变了 —— 脚本等于没装，
  // 必须手动 F5 才恢复。所以安装无条件做，是否初始化阅读页交给 activate() 判断。
  function install() {
    if (installed || !document.body) return;
    installed = true;

    // 阅读页是 SPA，章节切换/重渲染会把按钮冲掉，用观察器补回；
    // 它同时也是「路由切换」的探测点 —— 路由一变 DOM 必然跟着变
    new MutationObserver(() => {
      onMaybeNavigate();
      if (isReaderPage()) scheduleInject();
    }).observe(document.body, { childList: true, subtree: true });

    // 站点「深色」按钮就是翻 body 上的 wr_whiteTheme（脚本不自己造这个开关，原因见上面 ⚠️ 那段）。
    // 脚本不抢这个状态，只跟着它切换：一进黑夜就摘掉 data-wrbg 整块让位，回白天再接管。
    // 所以那个原生按钮永远有效，两边也永远同步 —— 因为它们改的是同一个类。
    new MutationObserver(apply).observe(document.body, { attributes: true, attributeFilter: ['class'] });

    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') { openPanel(false); return; }

      // 快捷键开/关面板：不带修饰键、且不在输入框/编辑区里才响应，
      // 免得在写想法/评论时打出一个 b 就把面板弹出来。
      if (e.ctrlKey || e.metaKey || e.altKey) return;
      if ((e.key || '').toLowerCase() !== PANEL_HOTKEY) return;
      const t = e.target;
      if (t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName))) return;
      if (!panelEl) return;                       // 还没注入，忽略
      e.preventDefault();
      e.stopPropagation();                        // 捕获阶段吃掉，别让站点也处理
      openPanel(panelEl.dataset.open !== '1');
    }, true);

    // 全屏状态变化时同步按钮图标（按 Esc 退出也要能同步）
    document.addEventListener('fullscreenchange', syncFullscreenUI);
    document.addEventListener('webkitfullscreenchange', syncFullscreenUI);

    // F11 没有事件可监听，只能靠 resize 推断（基线由 syncFullscreenUI 顺手维护）
    let fsResizeTimer = null;
    window.addEventListener('resize', () => {
      clearTimeout(fsResizeTimer);
      fsResizeTimer = setTimeout(syncFullscreenUI, 150);
    });

    // 前端路由不一定触发 popstate，但这一步很便宜，多一层保险
    window.addEventListener('popstate', () => {
      onMaybeNavigate();
      if (isReaderPage()) scheduleInject();
    });
  }

  // ---- 进入阅读页后的初始化（可重复调用）----
  function activate() {
    if (!isReaderPage() || !document.body) return;
    ensureStyle();
    apply();
    syncFullscreenUI();
    scheduleInject();
    if (!activatedOnce) {
      activatedOnce = true;
      // 首屏 DOM 可能晚于 document-idle，再补两次
      setTimeout(scheduleInject, 800);
      setTimeout(scheduleInject, 2500);
    }
  }

  function boot() {
    install();
    activate();

    // 方便在控制台调试：wrbg.set({colorId:'sepia', bgId:'paper', brightness:.9})
    window.wrbg = {
      get state() { return Object.assign({}, state); },
      set(patch) {
        state = Object.assign({}, state, patch || {});
        apply(); saveSettings();
        syncControls();
        renderSwatches();
        return Object.assign({}, state);
      },
      reset() {
        state = Object.assign({}, DEFAULTS);
        apply(); saveSettings(); syncControls(); renderSwatches();
        return Object.assign({}, state);
      },
      colors: COLORS.map((c) => c.id),
      backgrounds: BACKGROUNDS.map((b) => b.id),
      // 当前是不是黑夜（脚本在黑夜下整块让位，只剩两个按钮）
      get dark() { return siteIsDark(); },
      // 全屏诊断：F11 无法直接查询，这里能看到脚本的推断依据
      get fullscreen() {
        return {
          api: !!fullscreenEl(),          // 脚本自己开的全屏（有 API 状态）
          native: isNativeFullscreen(),   // 推断的浏览器原生全屏（F11）
          chromeH: chromeH,               // 学到的浏览器 UI 高度基线
          innerHeight: window.innerHeight,
          screenHeight: (window.screen || {}).height,
          availHeight: (window.screen || {}).availHeight,
          outerHeight: window.outerHeight,
        };
      },
    };
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot, { once: true });
  } else {
    boot();
  }
})();
