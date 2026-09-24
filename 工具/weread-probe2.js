/* ============================================================================
 * 微信读书网页版 · 探针 2：正文到底是 DOM 还是 Canvas？
 * ----------------------------------------------------------------------------
 * 背景：探针 1 发现 live 页面上 [data-wr-role="text"] 数量为 0，怀疑正文被画在
 *       <canvas> 上。这直接决定「改 CSS 颜色」和「自己重排行距/缩进」是否可行。
 *
 * 用法：
 *   1. 打开阅读页（已登录），F12 → Console
 *   2. 粘贴全部内容，回车，等约 15 秒
 *   3. 报告会自动复制到剪贴板（失败就手动 copy(JSON.stringify(window.__wrbg_p2,null,2))）
 *   4. 【重要】请跑两次，把两份报告都发我：
 *        第一次：窗口保持现在的大小（≈578px 宽）
 *        第二次：把浏览器窗口拉到全屏 / 尽量宽（>1200px），刷新页面后再跑
 *
 * 安全性：只读 DOM 与计算样式。唯一改动是临时把 --wr-reader-render-canvasXAround
 *        改成 220px（结束前还原）、以及一次全选正文后立刻清除选区。
 * ========================================================================== */
(async function () {
  'use strict';

  const S = (ms) => new Promise((r) => setTimeout(r, ms));
  const q = (s, r) => (r || document).querySelector(s);
  const qa = (s, r) => Array.from((r || document).querySelectorAll(s));
  const R2 = (n) => (typeof n === 'number' ? Math.round(n * 100) / 100 : n);

  const report = { probe: 2, url: location.href, time: new Date().toISOString() };
  const log = (...a) => console.log('%c[探针2]', 'color:#c8a06a;font-weight:bold', ...a);

  function chainOf(el, max) {
    const out = [];
    let n = el;
    while (n && n.nodeType === 1 && n !== document.documentElement && out.length < (max || 8)) {
      out.push(n.tagName + (n.id ? '#' + n.id : '') + (n.className ? '.' + String(n.className).slice(0, 70) : ''));
      n = n.parentElement;
    }
    return out;
  }

  function rectOf(el) {
    if (!el) return null;
    const r = el.getBoundingClientRect();
    return { x: R2(r.x), y: R2(r.y), w: R2(r.width), h: R2(r.height) };
  }

  /* ======================================================================
   * A. 阅读区中心点上，到底是谁在画？
   * ==================================================================== */
  try {
    const pts = [];
    for (const [nx, ny] of [[0.5, 0.3], [0.5, 0.45], [0.5, 0.6], [0.3, 0.5], [0.7, 0.5]]) {
      const x = Math.round(innerWidth * nx);
      const y = Math.round(innerHeight * ny);
      const el = document.elementFromPoint(x, y);
      pts.push({
        at: [x, y],
        tag: el ? el.tagName : null,
        chain: el ? chainOf(el, 6) : null,
      });
    }
    report.topElement = pts;
    log('A 命中最上层元素完成');
  } catch (e) { report.topElement = { error: String(e) }; }

  /* ======================================================================
   * B. canvas 普查 + 像素指纹
   *     指纹 = 采样若干像素点的校验和；正文若重排/重绘，指纹必然变化
   * ==================================================================== */
  function canvasFingerprint(c) {
    try {
      const ctx = c.getContext('2d');
      if (!ctx) return null;
      const W = c.width, H = c.height;
      if (!W || !H) return null;
      let sum = 0, nonBlank = 0, n = 0;
      // 在画布上撒 12×12 个采样点
      for (let i = 1; i <= 12; i++) {
        for (let j = 1; j <= 12; j++) {
          const x = Math.floor((W * i) / 13);
          const y = Math.floor((H * j) / 13);
          const d = ctx.getImageData(x, y, 1, 1).data;
          sum = (sum * 31 + d[0] * 7 + d[1] * 13 + d[2] * 17 + d[3]) % 2147483647;
          if (d[3] > 0 && !(d[0] > 250 && d[1] > 250 && d[2] > 250)) nonBlank++;
          n++;
        }
      }
      return { hash: sum, inkRatio: R2(nonBlank / n) };
    } catch (e) {
      return { error: String(e) };
    }
  }

  function census() {
    return {
      width: innerWidth,
      canvasCount: qa('canvas').length,
      canvases: qa('canvas').map((c, i) => {
        const cs = getComputedStyle(c);
        return {
          i,
          attr: { w: c.width, h: c.height },
          rect: rectOf(c),
          cls: (c.className || '').toString().slice(0, 60),
          display: cs.display,
          visibility: cs.visibility,
          opacity: cs.opacity,
          filter: cs.filter,
          zIndex: cs.zIndex,
          parent: chainOf(c.parentElement, 3),
          fp: canvasFingerprint(c),
        };
      }),
      charSpans: {
        dataWrRoleText: qa('[data-wr-role="text"]').length,
        wrAbsolute: qa('.wr_absolute').length,
        spanWithWrId: qa('span[data-wr-id]').length,
      },
      rc: (() => {
        const rc = q('.readerChapterContent');
        return rc ? {
          rect: rectOf(rc),
          childSummary: Array.from(rc.children).map((c) => c.tagName + '.' + String(c.className || '').slice(0, 50)),
          descendantTagCounts: (() => {
            const t = {};
            rc.querySelectorAll('*').forEach((e) => { t[e.tagName] = (t[e.tagName] || 0) + 1; });
            return t;
          })(),
          outerHTMLHead: rc.outerHTML.replace(/\s+/g, ' ').slice(0, 700),
        } : null;
      })(),
      renderTargets: qa('[class*="renderTarget"]').map((el) => ({
        cls: String(el.className).slice(0, 50),
        rect: rectOf(el),
        childTags: Array.from(el.children).map((c) => c.tagName).slice(0, 8),
      })),
    };
  }

  try {
    report.census = census();
    log('B canvas 普查完成，canvas 数量 =', report.census.canvasCount);
  } catch (e) { report.census = { error: String(e) }; }

  /* ======================================================================
   * C. 正文能不能被「选中」——canvas 画的字选不中
   * ==================================================================== */
  try {
    const rc = q('.readerChapterContent') || q('.renderTargetContent') || document.body;
    const sel = window.getSelection();
    sel.removeAllRanges();
    const rng = document.createRange();
    rng.selectNodeContents(rc);
    sel.addRange(rng);
    await S(150);
    const txt = sel.toString();
    const out = {
      selectedLength: txt.length,
      sample: txt.replace(/\s+/g, ' ').slice(0, 80),
      // 同时看看有没有别的容器能选中
    };
    sel.removeAllRanges(); // 立刻清除，别触发站点的划线菜单
    report.selection = out;
    log('C 选区测试完成，可选长度 =', out.selectedLength);
  } catch (e) { report.selection = { error: String(e) }; }

  /* ======================================================================
   * D. 页面里最长的文本节点在哪 —— 文字到底存在不存在于 DOM
   * ==================================================================== */
  try {
    let best = null;
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    let n;
    while ((n = walker.nextNode())) {
      const t = (n.nodeValue || '').trim();
      if (t.length > (best ? best.len : 30)) {
        best = { len: t.length, sample: t.slice(0, 70), chain: chainOf(n.parentElement, 6) };
      }
    }
    report.longestTextNode = best;
    log('D 最长文本节点完成');
  } catch (e) { report.longestTextNode = { error: String(e) }; }

  /* ======================================================================
   * E. 重做 canvas 变量测试（这次用几何 + 指纹，不再依赖字符 span）
   * ==================================================================== */
  try {
    const VAR = '--wr-reader-render-canvasXAround';
    const root = document.documentElement;
    const original = root.style.getPropertyValue(VAR);
    const canvasEl = q('canvas');
    const rtc = q('.renderTargetContent');
    const rc = q('.readerChapterContent');

    const measure = () => ({
      varComputed: (getComputedStyle(root).getPropertyValue(VAR) || '').trim(),
      canvasRect: rectOf(canvasEl),
      canvasFp: canvasEl ? canvasFingerprint(canvasEl) : null,
      renderTargetRect: rectOf(rtc),
      rcRect: rectOf(rc),
      rcMarginLeft: rc ? getComputedStyle(rc).marginLeft : null,
      // 全局滚动高度也能反映排版是否变化
      scrollHeight: document.scrollingElement ? document.scrollingElement.scrollHeight : null,
    });

    const out = { originalInline: original || null };
    out.before = measure();

    // E1 只改变量
    root.style.setProperty(VAR, '220px');
    await S(400);
    out.afterSetVar = measure();

    // E2 触发 resize
    window.dispatchEvent(new Event('resize'));
    await S(1500);
    out.afterResize = measure();

    // E3 切双栏再切回
    const dual = q('.readerControls_item.isNormalReader');
    if (dual) {
      dual.click(); await S(1500);
      out.afterDual = measure();
      dual.click(); await S(1200);
      out.afterDualRestore = measure();
    } else {
      out.afterDual = { error: '未找到 .isNormalReader' };
    }

    // 还原
    if (original) root.style.setProperty(VAR, original); else root.style.removeProperty(VAR);
    await S(500);
    out.restored = measure();

    // 判定：任一几何量或指纹发生变化，就说明「引擎读了我们的变量」
    const diff = (a, b) => {
      if (!a || !b) return null;
      const keys = ['canvasRect', 'renderTargetRect', 'rcRect', 'scrollHeight'];
      const d = {};
      for (const k of keys) {
        const A = a[k], B = b[k];
        if (A && B && typeof A === 'object') {
          d[k] = { x: R2(B.x - A.x), w: R2(B.w - A.w), h: R2(B.h - A.h) };
        } else if (typeof A === 'number' && typeof B === 'number') {
          d[k] = R2(B - A);
        }
      }
      d.canvasFpChanged = !!(a.canvasFp && b.canvasFp && a.canvasFp.hash !== b.canvasFp.hash);
      return d;
    };
    out.diff = {
      setVar: diff(out.before, out.afterSetVar),
      afterResize: diff(out.before, out.afterResize),
      afterDual: diff(out.before, out.afterDual),
    };
    out.varSurvivedResize = out.afterResize.varComputed === '220px';
    out.varSurvivedDual = out.afterDual && out.afterDual.varComputed === '220px';

    report.canvasVarTest = out;
    log('E 变量测试完成', { survivedResize: out.varSurvivedResize, diffResize: out.diff.afterResize });
  } catch (e) { report.canvasVarTest = { error: String(e) }; }

  /* ======================================================================
   * F. 引擎设置与 body 属性
   * ==================================================================== */
  try {
    const attrs = {};
    for (const a of document.body.attributes) attrs[a.name] = a.value;
    report.settings = {
      bodyAttrs: attrs,
      wrLocalSetting: localStorage.getItem('wrLocalSetting'),
      // 字号档位数 / 当前档位
      fontLevelDots: qa('.reader_font_control_slider_track_level_dot').length,
      // 有没有用过「深色」：看 body 上有没有 wr_whiteTheme
      hasWhiteTheme: document.body.classList.contains('wr_whiteTheme'),
      // 站点原生字号面板里出现的所有中文选项文案（找边距/行距的蛛丝马迹）
      panelText: (() => {
        const p = q('.font-panel-content');
        return p ? (p.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 300) : null;
      })(),
    };
    log('F 设置完成');
  } catch (e) { report.settings = { error: String(e) }; }

  /* ---------- 输出 ---------- */
  window.__wrbg_p2 = report;
  const text = JSON.stringify(report, null, 2);
  console.log('%c===== 探针2 报告（请整段复制发回）=====', 'color:#c8a06a;font-weight:bold');
  console.log(text);
  try {
    copy(text);
    console.log('%c✅ 已复制到剪贴板。记得把窗口拉宽后再跑一次！', 'color:#4caf50;font-weight:bold');
  } catch (e) {
    console.log('%c⚠️ 请手动执行：copy(JSON.stringify(window.__wrbg_p2, null, 2))', 'color:#e57373;font-weight:bold');
  }
})();
