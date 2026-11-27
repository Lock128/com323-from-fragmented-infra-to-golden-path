// ── Cluster picker ──────────────────────────────────────────────────────────
// Shows which demo target this page runs against (local kind, EKS self-managed,
// EKS managed) and switches to another one. Each target has its own kubeconfig
// file and its own ports (see target.sh), so "switching" means: open the other
// target's dashboard, and start its UIs first if they are not running. This page
// and its cluster keep running.
//
// Data: targets.json (written next to this file by the ui.sh scripts, from
// `target.sh json`) and each target's action backend /health, which reports the
// target it serves. Starting a target goes through THIS page's backend
// (action "start-target", which runs ./target.sh start <target> --no-open).
(function () {
  var targets = [], current = null, states = {}, busy = false;

  function el(tag, attrs, text) {
    var e = document.createElement(tag);
    for (var k in (attrs || {})) e.setAttribute(k, attrs[k]);
    if (text != null) e.textContent = text;
    return e;
  }
  function health(port) {
    var ctl = typeof AbortController === 'function' ? new AbortController() : null;
    var timer = ctl ? setTimeout(function () { ctl.abort(); }, 1500) : null;
    return fetch('http://localhost:' + port + '/health', ctl ? { signal: ctl.signal } : {})
      .then(function (r) { return r.ok ? r.json() : null; })
      .catch(function () { return null; })
      .then(function (j) { if (timer) clearTimeout(timer); return j; });
  }
  function stateOf(t, j) {
    if (!j) return 'stopped';
    return j.target === t.id ? 'running' : 'other';
  }
  function targetUrl(t) { return 'http://localhost:' + t.dash + location.pathname; }

  var css = [
    '.tb-bar{display:flex;align-items:center;justify-content:flex-end;gap:8px;flex-wrap:wrap;margin:0 110px 10px 0;font-size:12px;color:var(--muted)}',
    '.tb-bar select,.tb-bar button{background:var(--surface);color:var(--text);border:1px solid var(--border);border-radius:16px;padding:4px 10px;font:inherit;font-size:12px;cursor:pointer}',
    '.tb-bar button:hover:not(:disabled),.tb-bar select:hover{border-color:var(--accent)}',
    '.tb-bar button:disabled{opacity:.45;cursor:not-allowed}',
    '.tb-ctx{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:11px;max-width:420px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}',
    '.tb-panel{margin:0 0 12px;border:1px solid var(--border);border-radius:8px;background:var(--surface);padding:8px 10px}',
    '.tb-panel pre{max-height:260px;overflow:auto;font-size:11px;white-space:pre-wrap;margin:6px 0 0;color:var(--text)}',
    '.tb-panel .tb-head{display:flex;gap:8px;align-items:center;font-size:12px;color:var(--text)}',
    '.tb-panel .tb-head button{margin-left:auto}'
  ].join('\n');

  var bar, sel, btn, stateEl, ctxEl, panel, panelHead, out;

  function build() {
    document.head.appendChild(el('style', {}, css));
    bar = el('div', { class: 'tb-bar', id: 'target-bar' });
    bar.appendChild(el('span', {}, 'Cluster'));
    sel = el('select', { id: 'target-select', 'aria-label': 'Demo target' });
    btn = el('button', { id: 'target-go', type: 'button' }, 'Open');
    stateEl = el('span', { id: 'target-state' });
    ctxEl = el('span', { class: 'tb-ctx', id: 'target-ctx' });
    bar.appendChild(sel); bar.appendChild(btn); bar.appendChild(stateEl); bar.appendChild(ctxEl);
    panel = el('div', { class: 'tb-panel', id: 'target-panel', style: 'display:none' });
    panelHead = el('div', { class: 'tb-head' });
    var close = el('button', { type: 'button', class: 'ctl-btn ctl-ghost' }, 'Close');
    close.onclick = function () { if (!busy) panel.style.display = 'none'; };
    panelHead.appendChild(el('span', { id: 'target-panel-title' }));
    panelHead.appendChild(close);
    out = el('pre', { id: 'target-out' });
    panel.appendChild(panelHead); panel.appendChild(out);
    var first = document.body.firstElementChild;
    // Keep the fixed theme toggle first; insert the bar right after it.
    if (first && first.classList.contains('theme-toggle')) first = first.nextElementSibling;
    document.body.insertBefore(panel, first);
    document.body.insertBefore(bar, panel);
    sel.onchange = render;
    btn.onclick = go;
  }

  function label(t) {
    var s = states[t.id];
    if (t === current) return t.label + '  (this page)';
    if (!t.available) return t.label + '  (not in this checkout)';
    if (s === 'running') return t.label + '  · running';
    if (s === 'other') return t.label + '  · ports in use by another program';
    return t.label + '  · not running';
  }

  function render() {
    var keep = sel.value;
    sel.textContent = '';
    targets.forEach(function (t) {
      var o = el('option', { value: t.id }, label(t));
      sel.appendChild(o);
    });
    sel.value = keep || (current && current.id) || (targets[0] && targets[0].id) || '';
    var t = byId(sel.value);
    if (!t || t === current) { btn.textContent = 'Open'; btn.disabled = true; }
    else if (!t.available) { btn.textContent = 'Open'; btn.disabled = true; }
    else if (states[t.id] === 'running') { btn.textContent = 'Open ↗'; btn.disabled = busy; }
    else { btn.textContent = 'Start & open ▶'; btn.disabled = busy; }
    stateEl.textContent = current ? '' : 'this page is not one of the known targets';
  }

  function byId(id) { for (var i = 0; i < targets.length; i++) if (targets[i].id === id) return targets[i]; return null; }

  function refresh() {
    return Promise.all(targets.map(function (t) {
      return health(t.ctl).then(function (j) {
        states[t.id] = stateOf(t, j);
        if (t === current) ctxEl.textContent = j && j.context ? j.context : '(action backend not running)';
      });
    })).then(render);
  }

  function showPanel(title) {
    document.getElementById('target-panel-title').textContent = title;
    out.textContent = '';
    panel.style.display = 'block';
  }

  function waitUp(t, tries) {
    return health(t.ctl).then(function (j) {
      if (stateOf(t, j) === 'running') return true;
      if (tries <= 0) return false;
      return new Promise(function (res) { setTimeout(res, 1000); }).then(function () { return waitUp(t, tries - 1); });
    });
  }

  function go() {
    var t = byId(sel.value);
    if (!t || t === current || busy) return;
    if (states[t.id] === 'running') { location.href = targetUrl(t); return; }
    if (!current || states[current.id] !== 'running') {
      showPanel('Cannot start ' + t.id + ' from here');
      out.textContent = 'This page\'s action backend is not running. In a terminal, run:\n\n  ./local-demo/target.sh start ' + t.id +
        '\n\nthen open ' + targetUrl(t);
      return;
    }
    var msg = 'Start the "' + t.label + '" UIs?\n\nRuns ./target.sh start ' + t.id + ' --no-open with its own kubeconfig (' +
      t.kubeconfig + ') and ports. This page keeps running.';
    if (states[t.id] === 'other') msg += '\n\nIts ports are in use by another program (another copy of the demo?). Starting stops that program.';
    if (!confirm(msg)) return;
    busy = true; render();
    showPanel('Starting ' + t.label + '…');
    fetch('http://localhost:' + current.ctl + '/run', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'start-target', params: { target: t.id } })
    }).then(function (resp) {
      if (resp.status !== 200) return resp.json().then(function (j) { throw new Error((j && j.error) || ('HTTP ' + resp.status)); });
      var reader = resp.body.getReader(), dec = new TextDecoder();
      function pump() {
        return reader.read().then(function (r) {
          if (r.done) return;
          out.textContent += dec.decode(r.value, { stream: true });
          out.scrollTop = out.scrollHeight;
          return pump();
        });
      }
      return pump();
    }).then(function () {
      out.textContent += '\nWaiting for the ' + t.id + ' dashboard…\n';
      return waitUp(t, 30);
    }).then(function (up) {
      busy = false;
      if (up) { states[t.id] = 'running'; location.href = targetUrl(t); return; }
      out.textContent += 'The ' + t.id + ' action backend did not come up. Check the output above.\n';
      refresh();
    }).catch(function (e) {
      busy = false;
      out.textContent += '\nerror: ' + e.message + '\n';
      refresh();
    });
  }

  function init() {
    fetch('targets.json').then(function (r) { return r.ok ? r.json() : []; }).catch(function () { return []; })
      .then(function (list) {
        targets = Array.isArray(list) ? list : [];
        if (!targets.length) return;
        var port = Number(location.port);
        current = targets.filter(function (t) { return t.dash === port; })[0] || null;
        build();
        render();
        refresh();
        setInterval(function () { if (!busy) refresh(); }, 15000);
      });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
})();
