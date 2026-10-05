/* ============================================================================
 * 夹具预清理（由 工具/回归验证.ps1 与 工具/像素验证.ps1 在注入脚本前内联执行）
 * ----------------------------------------------------------------------------
 * 为什么需要：
 *   如果页面快照是在**脚本已经运行的状态下**保存的（SingleFile 会把当时隐藏的元素
 *   打上 sf-hidden），那么快照的 DOM 里就带着上一次注入的产物：
 *   `.wrbg-wrap` / `data-wrbg` / `--wrbg-*` 内联变量。
 *
 *   而脚本的注入逻辑是：
 *       let wrap = controls.querySelector('.wrbg-wrap');
 *       if (!wrap) wrap = buildUI();        // ← 看到残留的 wrap 就**不建 UI**
 *   于是 buildUI() 里的 panelEl / rowColorEl 等赋值全部没发生 →
 *   点「背景」按钮没反应、面板是那个空壳，**而且一个异常都不抛**（最难查的一类）。
 *
 *   所以注入前必须把夹具清回「原生」状态。它同时把清理数量写进 window.__wrbgPreclean，
 *   让报告里能看出「这份夹具本来是脏的」—— 夹具状态要对人可见，不要默默容忍。
 * ========================================================================== */
(function () {
  var removed = 0;
  try {
    Array.prototype.slice.call(document.querySelectorAll('[class*="wrbg-"]')).forEach(function (n) {
      removed++;
      if (n.parentNode) n.parentNode.removeChild(n);
    });
    Array.prototype.slice.call(document.querySelectorAll('style')).forEach(function (s) {
      if ((s.textContent || '').indexOf('--wrbg-') >= 0) {
        removed++;
        if (s.parentNode) s.parentNode.removeChild(s);
      }
    });
    var r = document.documentElement;
    if (r.hasAttribute('data-wrbg')) { r.removeAttribute('data-wrbg'); removed++; }
    if (r.hasAttribute('data-wrbg-bg')) { r.removeAttribute('data-wrbg-bg'); removed++; }
    Array.prototype.slice.call(r.style).forEach(function (k) {
      if (k.indexOf('--wrbg-') === 0) { r.style.removeProperty(k); removed++; }
    });
  } catch (e) { /* 清理失败不该让整轮验证崩掉，但数量会体现在报告里 */ }
  window.__wrbgPreclean = removed;
})();
