/* ============================================================================
 * 微信读书网页版 · 排版引擎探针 v1
 * ----------------------------------------------------------------------------
 * 用法：
 *   1. 浏览器打开任意一章阅读页（已登录）：https://weread.qq.com/web/reader/...
 *   2. F12 → Console → 把本文件全部内容粘贴进去 → 回车
 *   3. 等约 20 秒，脚本会自动把报告复制到剪贴板，同时在控制台打印
 *      （如果没复制成功，手动执行  copy(JSON.stringify(window.__wrbg_probe, null, 2))  ）
 *   4. 把报告整段发回给我
 *
 * 说明：探针只读取 DOM 与计算样式；唯一会「改动」的是临时改一个 CSS 变量和
 *      切换一次「双栏阅读」按钮，两项都会在结束前还原。
 * ========================================================================== */
(async function () {
  'use strict';

  const S = (ms) => new Promise((r) => setTimeout(r, ms));
  const q = (s, r) => (r || document).querySelector(s);
  const qa = (s, r) => Array.from((r || document).querySelectorAll(s));
  const round = (n) => (typeof n === 'number' ? Math.round(n * 100) / 100 : n);

  const report = { url: location.href, time: new Date().toISOString(), steps: {} };
  const log = (...a) => console.log('%c[探针]', 'color:#c8a06a;font-weight:bold', ...a);

  /* ---------- 工具：给正文拍一张「指纹」，用来判断有没有重排 ---------- */
  function charSig() {
    const els = qa('.readerChapterContent [data-wr-role="text"]');
    if (!els.length) return null;
    const pick = (i) => {
      const el = els[i];
      const m = /translate\((-?[\d.]+)px,\s*(-?[\d.]+)px\)/.exec(el.getAttribute('style') || '');
      const r = el.getBoundingClientRect();
      return {
        t: (el.textContent || '').slice(0, 1),
        x: m ? round(+m[1]) : null,
        y: m ? round(+m[2]) : null,
        rx: round(r.x),
        ry: round(r.y),
      };
    };
    return {
      count: els.length,
      cls: (els[0].className || '').match(/ccn-[a-z0-9]+/)?.[0] || null,
      first: pick(0),
      mid: pick(Math.floor(els.length / 2)),
      last: pick(els.length - 1),
    };
  }

  const sameSig = (a, b) =>
    !!a && !!b && a.count === b.count && a.cls === b.cls &&
    a.first.x === b.first.x && a.first.y === b.first.y && a.last.y === b.last.y;

  const VARNAME = '--wr-reader-render-canvasXAround';
  const readVar = () => ({
    inline: document.documentElement.style.getPropertyValue(VARNAME) || null,
    computed: (getComputedStyle(document.documentElement).getPropertyValue(VARNAME) || '').trim() || null,
  });

  /* ======================================================================
   * 步骤 1：环境与引擎状态
   * ==================================================================== */
  try {
    const rootStyle = document.documentElement.getAttribute('style') || '';
    report.steps.env = {
      bodyClass: document.body.className,
      htmlClass: document.documentElement.className,
      rootInlineVars: rootStyle.match(/--wr-[a-z\-]+:[^;]+/gi) || [],
      // 所有 --wr-* 自定义属性（含样式表里定义的）
      rootComputedVars: (() => {
        const cs = getComputedStyle(document.documentElement);
        const out = {};
        for (const name of Array.from(cs)) {
          if (name.startsWith('--wr-')) out[name] = cs.getPropertyValue(name).trim();
        }
        return out;
      })(),
      // 页面里所有 <style>，用来找引擎每次渲染生成的那条
      styleTags: qa('style').map((s, i) => ({
        i,
        len: (s.textContent || '').length,
        head: (s.textContent || '').replace(/\s+/g, ' ').slice(0, 120),
      })).filter((s) => s.len > 0).slice(0, 40),
      // weread 自己的本地存储（只看可疑的键）
      storage: (() => {
        const out = {};
        try {
          for (let i = 0; i < localStorage.length; i++) {
            const k = localStorage.key(i);
            if (!/read|font|theme|setting|wr|shelf|book/i.test(k)) continue;
            const v = localStorage.getItem(k) || '';
            out[k] = v.length > 300 ? '<len ' + v.length + '>' : v;
          }
        } catch (e) { out.error = String(e); }
        return out;
      })(),
      // window 上可疑的全局对象（可能是引擎实例）
      globals: (() => {
        const out = [];
        for (const k of Object.keys(window)) {
          if (!/reader|render|weread|^wr|indent|lineheight|lineheight/i.test(k)) continue;
          let t = typeof window[k];
          if (t === 'object' && window[k]) t += '(' + (window[k].constructor?.name || '?') + ')';
          out.push(k + ' = ' + t);
        }
        return out.slice(0, 60);
      })(),
      // Vue 实例的 data 键名（引擎设置常挂在这里）
      vue: (() => {
        const cands = ['#app', '.app', 'body > div', '#routerView'];
        const out = {};
        for (const sel of cands) {
          const el = q(sel);
          const vm = el && (el.__vue__ || el.__vue_app__);
          if (!vm) continue;
          out[sel] = vm.$data ? Object.keys(vm.$data).slice(0, 60)
            : (vm._instance && vm._instance.proxy ? Object.keys(vm._instance.proxy.$data || {}).slice(0, 60) : '<no $data>');
        }
        return out;
      })(),
      viewport: { w: innerWidth, h: innerHeight, dpr: devicePixelRatio },
    };
    log('步骤 1 环境完成');
  } catch (e) {
    report.steps.env = { error: String(e) };
  }

  /* ======================================================================
   * 步骤 2：正文与段落结构切片
   *      —— 判断「自己重排」是否可行的核心数据
   * ==================================================================== */
  try {
    const wrappers = qa('.passage-wrapper');
    const content = q('.readerChapterContent');
    const allSpans = qa('.readerChapterContent [data-wr-role="text"]');

    // 统计所有字符的宽度分布 + 按行聚类
    const widths = {};
    const lines = {};
    allSpans.forEach((el) => {
      const st = el.getAttribute('style') || '';
      const mT = /translate\((-?[\d.]+)px,\s*(-?[\d.]+)px\)/.exec(st);
      const mW = /width:([\d.]+)px/.exec(st);
      const w = mW ? round(+mW[1]) : null;
      if (w !== null) widths[w] = (widths[w] || 0) + 1;
      if (mT) {
        const y = mT[2];
        (lines[y] = lines[y] || []).push({ x: round(+mT[1]), w: w, t: (el.textContent || '').slice(0, 1) });
      }
    });

    const lineList = Object.keys(lines)
      .map((y) => ({
        y: round(+y),
        n: lines[y].length,
        minX: round(Math.min(...lines[y].map((c) => c.x))),
        widthSet: Array.from(new Set(lines[y].map((c) => c.w))).slice(0, 5),
        head: lines[y].sort((a, b) => a.x - b.x).slice(0, 14).map((c) => c.t).join(''),
      }))
      .sort((a, b) => a.y - b.y);

    const linePitch = [];
    for (let i = 1; i < lineList.length; i++) linePitch.push(round(lineList[i].y - lineList[i - 1].y));

    // 只深挖前 2 个段落，避免报告过大
    const sampleParas = wrappers.slice(0, 2).map((w) => {
      const spans = qa('[data-wr-role="text"]', w);
      const byY = {};
      spans.forEach((el) => {
        const st = el.getAttribute('style') || '';
        const mT = /translate\((-?[\d.]+)px,\s*(-?[\d.]+)px\)/.exec(st);
        const mW = /width:([\d.]+)px/.exec(st);
        if (!mT) return;
        (byY[mT[2]] = byY[mT[2]] || []).push({ x: round(+mT[1]), w: mW ? round(+mW[1]) : null, t: (el.textContent || '').slice(0, 1) });
      });
      const ys = Object.keys(byY).map(Number).sort((a, b) => a - b);
      return {
        wrapperChildren: Array.from(w.children).map((c) => c.tagName + '.' + (c.className || '')),
        spanCount: spans.length,
        lineCount: ys.length,
        text: spans.map((s) => s.textContent).join('').slice(0, 60),
        firstLine: (byY[ys[0]] || []).sort((a, b) => a.x - b.x).map((c) => {
          return { t: c.t, x: c.x, w: c.w };
        }).slice(0, 20),
        lineYs: ys.map(round),
      };
    });

    // 正文里除字符外的其它节点（图片、批注、分隔线…）
    const others = content
      ? Array.from(content.querySelectorAll('*'))
          .filter((el) => !el.hasAttribute('data-wr-role') && !/^(SPAN|DIV)$/.test(el.tagName))
          .map((el) => el.tagName + '.' + (el.className || ''))
          .slice(0, 20)
      : [];

    report.steps.layout = {
      passageWrappers: wrappers.length,
      textSpans: allSpans.length,
      widthDistribution: widths,
      distinctLines: lineList.length,
      linePitch: linePitch.slice(0, 30),
      linesSample: lineList.slice(0, 12),
      sampleParas: sampleParas,
      otherNodeKinds: Array.from(new Set(others)),
      // 容器尺寸：判断重排后要不要自己撑高
      container: content ? {
        rect: (() => { const r = content.getBoundingClientRect(); return { x: round(r.x), w: round(r.width), h: round(r.height) }; })(),
        cssHeight: getComputedStyle(content).height,
        cssMarginLeft: getComputedStyle(content).marginLeft,
        cssMarginRight: getComputedStyle(content).marginRight,
        scrollHeight: content.scrollHeight,
        offsetHeight: content.offsetHeight,
      } : null,
      scrollHost: (() => {
        const se = document.scrollingElement;
        return se ? { tag: se.tagName, scrollHeight: se.scrollHeight, clientHeight: se.clientHeight } : null;
      })(),
      // 引擎的渲染容器在哪
      renderTargets: qa('[class*="renderTarget"]').map((el) => {
        const r = el.getBoundingClientRect();
        const cs = getComputedStyle(el);
        return { cls: el.className, x: round(r.x), y: round(r.y), w: round(r.width), h: round(r.height), display: cs.display, visibility: cs.visibility, transform: cs.transform.slice(0, 40) };
      }),
    };
    log('步骤 2 结构完成');
  } catch (e) {
    report.steps.layout = { error: String(e) };
  }

  /* ======================================================================
   * 步骤 3：canvas 变量是「输入」还是「输出」？
   *      这是 Tier 1（边距/字号走引擎参数）能否成立的关键
   * ==================================================================== */
  try {
    const root = document.documentElement;
    const original = root.style.getPropertyValue(VARNAME);
    const out = { originalInline: original || null, initial: readVar(), sigBefore: charSig() };

    // 3a 直接改变量，看正文有没有动
    root.style.setProperty(VARNAME, '220px');
    await S(400);
    out.afterSetVar = { vars: readVar(), sig: charSig() };
    out.afterSetVar.moved = !sameSig(out.sigBefore, out.afterSetVar.sig);

    // 3b 触发重排：resize
    window.dispatchEvent(new Event('resize'));
    await S(1500);
    out.afterResize = { vars: readVar(), sig: charSig() };
    out.afterResize.moved = !sameSig(out.sigBefore, out.afterResize.sig);
    out.afterResize.varKept = readVar().computed === '220px';

    // 3c 触发重排：切一次「双栏阅读」再切回来
    const dual = q('.readerControls_item.isNormalReader');
    if (dual) {
      const sigA = charSig();
      dual.click();
      await S(1500);
      out.afterDualToggle = { vars: readVar(), sig: charSig() };
      out.afterDualToggle.moved = !sameSig(sigA, out.afterDualToggle.sig);
      out.afterDualToggle.varKept = readVar().computed === '220px';
      dual.click(); // 还原
      await S(1200);
      out.afterDualRestore = { vars: readVar(), sig: charSig() };
    } else {
      out.afterDualToggle = { error: '未找到 .isNormalReader 按钮' };
    }

    // 还原变量
    if (original) root.style.setProperty(VARNAME, original);
    else root.style.removeProperty(VARNAME);
    await S(300);
    out.restored = { vars: readVar(), sig: charSig() };
    out.conclusion = {
      变量被引擎写回: out.afterResize.varKept === false,
      改变量能改变排版: out.afterSetVar.moved === true,
    };
    report.steps.canvasVar = out;
    log('步骤 3 canvas 变量完成', out.conclusion);
  } catch (e) {
    report.steps.canvasVar = { error: String(e) };
  }

  /* ======================================================================
   * 步骤 4：原生「字号」面板里到底有什么
   *      —— 看网页版已有哪些排版能力，也方便我照着它的样式做面板
   * ==================================================================== */
  try {
    const btn = q('.readerControls_item.fontSizeButton');
    const panel = q('.font-panel-content');
    const stateBefore = {
      panelDisplay: panel ? getComputedStyle(panel).display : null,
      panelHtmlLen: panel ? panel.innerHTML.length : 0,
    };
    let panelHtml = null;
    let controls = [];
    if (btn && panel) {
      btn.click();
      await S(800);
      panelHtml = panel.innerHTML.replace(/\s+/g, ' ').slice(0, 4000);
      // 列出面板里所有可点控件及其文案/类名/尺寸
      controls = qa('button, [role="button"], .wr_font_panel_item, [class*="font"]', panel)
        .slice(0, 40)
        .map((el) => {
          const r = el.getBoundingClientRect();
          return {
            tag: el.tagName,
            cls: (el.className || '').toString().slice(0, 80),
            text: (el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 30),
            w: round(r.width),
            h: round(r.height),
          };
        });
      // 关掉面板
      if (btn) btn.click();
      await S(300);
    }
    report.steps.nativeFontPanel = { stateBefore, panelHtml, controls };
    log('步骤 4 原生字号面板完成');
  } catch (e) {
    report.steps.nativeFontPanel = { error: String(e) };
  }

  /* ======================================================================
   * 步骤 5：引擎是否在监听我们的改动（判断重放策略）
   * ==================================================================== */
  try {
    let regenerated = 0;
    const mo = new MutationObserver((muts) => {
      muts.forEach((m) => {
        if (m.type === 'childList' || m.type === 'characterData') regenerated++;
      });
    });
    mo.observe(document.head || document.documentElement, { childList: true, subtree: true, characterData: true });
    await S(2500);
    mo.disconnect();
    report.steps.headMutations = { countDuring2500msIdle: regenerated };
    log('步骤 5 完成');
  } catch (e) {
    report.steps.headMutations = { error: String(e) };
  }

  /* ---------- 输出 ---------- */
  window.__wrbg_probe = report;
  const text = JSON.stringify(report, null, 2);
  console.log('%c===== 探针报告（请整段复制发回）=====', 'color:#c8a06a;font-weight:bold');
  console.log(text);
  try {
    copy(text);
    console.log('%c✅ 报告已复制到剪贴板，直接粘贴发回即可', 'color:#4caf50;font-weight:bold');
  } catch (e) {
    console.log('%c⚠️ 自动复制失败，请手动执行：copy(JSON.stringify(window.__wrbg_probe, null, 2))', 'color:#e57373;font-weight:bold');
  }
})();
