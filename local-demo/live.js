// ── Live cluster view ───────────────────────────────────────────────────────
// kubectl proxy (started by ui.sh) serves this page AND the Kubernetes API from
// one origin, so the page can GET resource lists with no auth/CORS. A 404 means
// "kind not installed yet", not an error.
var LIVE_SOURCES = [
  { id: 'svc',    path: '/apis/lockhead.cloud/v1alpha1/services' },
  // The Crossplane composite behind each Service claim (graph view only — the
  // cards view does not use it). 404 on older clusters; harmless if absent.
  { id: 'xsvc',   path: '/apis/lockhead.cloud/v1alpha1/xservices' },
  { id: 'argo',   path: '/apis/argoproj.io/v1alpha1/applications' },
  // Downstream registrations are now platform-owned CRDs (were ConfigMaps).
  { id: 'scan',   path: '/apis/platform.lockhead.cloud/v1alpha1/securityscans' },
  { id: 'oncall', path: '/apis/platform.lockhead.cloud/v1alpha1/oncallregistrations' },
  { id: 'report', path: '/apis/platform.lockhead.cloud/v1alpha1/reportingentries' },
  // FinOps is an OPTIONAL extension (./demo/add-finops.sh). 404 until added.
  { id: 'finops', path: '/apis/platform.lockhead.cloud/v1alpha1/finopsallocations' },
  // Observability is an OPTIONAL extension (./demo/add-observability.sh, Go function).
  { id: 'obs',    path: '/apis/platform.lockhead.cloud/v1alpha1/observabilitysetups' },
  // Crossplane composition functions — the pipeline machinery itself. The graph
  // view draws the Go function (function-observability) as a node in the chain
  // between the composite and the records it composes. 404 on older clusters.
  { id: 'fn',     path: '/apis/pkg.crossplane.io/v1/functions' },
  { id: 'deploy', path: '/apis/apps/v1/deployments' }
];

// claim column
var LIVE_CLAIMS = [
  { id: 'svc', kind: 'Service', cls: 'svc', title: 'Service declarations' }
];
// produced column: repos are derived (see liveModel), the rest are real objects
var LIVE_PRODUCED = [
  { id: 'repo',     kind: 'Git repo',      cls: 'repo',     title: 'Git repositories (from repoURL)' },
  { id: 'argo',     kind: 'Argo CD App',   cls: 'argo',     title: 'Argo CD applications → deploy' },
  { id: 'deploy',   kind: 'Deployment',    cls: 'deploy',   title: 'Running workloads' },
  { id: 'security', kind: 'Security scan', cls: 'security', title: 'Security scan registrations' },
  { id: 'sre',      kind: 'SRE on-call',   cls: 'sre',      title: 'SRE on-call registrations' },
  { id: 'report',   kind: 'Reporting',     cls: 'report',   title: 'Reporting / catalog entries' }
];

// Shared one-line detail for a resource, by node class. Used by BOTH the card
// view and the graph view so a node shows the same tier/SLO/budget/etc summary
// in either mode. `spec` is the resource .spec; `extra` carries the few derived
// bits that aren't on the spec (repo path, Argo sync, deployment replicas).
function detailFor(cls, spec, extra) {
  spec = spec || {}; extra = extra || {};
  switch (cls) {
    case 'svc':      return (spec.tier ? 'tier ' + spec.tier : '') +
                            (spec.team ? ' · team ' + spec.team : '');
    case 'repo':     return 'path: ' + (extra.repoPath || 'chart');
    case 'argo':     return extra.sync ? extra.sync.toLowerCase() : '';
    case 'deploy':   return (extra.ready || 0) + '/' + (extra.want || 1) + ' ready';
    case 'security': return 'scan: ' + (spec.scanCadence || '?');
    case 'sre':      return (spec.pagingWindow || '?') + ' · SLO ' + (spec.sloTarget || '?');
    case 'report':   return (spec.tier || '?') + ' · ' + (spec.language || '?');
    case 'finops':   return (spec.costCenter || '?') + ' · $' + (spec.monthlyBudgetUSD || '?') + '/mo';
    case 'obs':      return (spec.tier || '?') + '/' + (spec.language || '?') + ' · ' +
                            ((spec.alerts || []).length) + ' alerts · ' + ((spec.dashboards || []).length) + ' dash';
    default:         return '';
  }
}

function liveReady(item) {
  var cs = (item.status && item.status.conditions) || [];
  var r = cs.filter(function (c) { return c.type === 'Ready'; })[0];
  if (r) return r.status === 'True' ? 'ready' : 'wait';
  // Argo CD Application health
  if (item.status && item.status.health && item.status.health.status) {
    return item.status.health.status === 'Healthy' ? 'ready' : 'wait';
  }
  // Deployment: ready replicas
  if (item.status && item.spec && item.kind === 'Deployment') {
    return (item.status.readyReplicas || 0) >= (item.spec.replicas || 1) ? 'ready' : 'wait';
  }
  return 'none';
}

function shortRepo(url) {
  if (!url) return '';
  return url.replace(/^https?:\/\/[^/]+\//, '').replace(/\.git$/, '')
            .replace(/^.*\/([^/]+\/[^/]+)$/, '$1');
}

// responses keyed by id: { status:200, items:[...] } | { status:404 } | { status:0 }
function liveModel(responses) {
  var model = { claims: [], produced: [], unreachable: false };
  var anyOk = false;
  Object.keys(responses).forEach(function (k) { if (responses[k].status === 200) anyOk = true; });
  model.unreachable = !anyOk;

  var svcItems   = (responses.svc    && responses.svc.status    === 200) ? responses.svc.items    : [];
  var argoItems  = (responses.argo   && responses.argo.status   === 200) ? responses.argo.items   : [];
  var scanItems  = (responses.scan   && responses.scan.status   === 200) ? responses.scan.items   : [];
  var oncallItems= (responses.oncall && responses.oncall.status === 200) ? responses.oncall.items : [];
  var reportItems= (responses.report && responses.report.status === 200) ? responses.report.items : [];
  var finopsItems= (responses.finops && responses.finops.status === 200) ? responses.finops.items : [];
  var obsItems   = (responses.obs    && responses.obs.status    === 200) ? responses.obs.items    : [];
  var deployItems= (responses.deploy && responses.deploy.status === 200) ? responses.deploy.items : [];

  function svcLabel(i) { return (i.metadata.labels || {})['lockhead.cloud/service'] || ''; }

  // ── claims: Service CRs ──
  var claimCards = svcItems.map(function (i) {
    return { key: 'svc/' + i.metadata.name, name: i.metadata.name, ns: i.metadata.namespace || '',
             kind: 'Service', cls: 'svc', state: liveReady(i),
             detail: detailFor('svc', i.spec) };
  }).sort(function (a, b) { return a.key < b.key ? -1 : 1; });
  model.claims = [{ id: 'svc', title: 'Service declarations', cards: claimCards, installed: true }];

  // ── produced: git repos derived from Service.spec.repoURL ──
  var repoCards = svcItems.filter(function (i) { return i.spec && i.spec.repoURL; }).map(function (i) {
    var full = shortRepo(i.spec.repoURL);
    return { key: 'repo/' + i.metadata.name, name: full || i.metadata.name, ns: '',
             kind: 'Git repo', cls: 'repo', state: 'ready',
             detail: detailFor('repo', i.spec, { repoPath: i.spec && i.spec.repoPath }),
             // Only Gitea repos are browsable on localhost:3100 (not CodeCommit on the managed variant).
             href: /gitea/.test(i.spec.repoURL) ? 'http://localhost:3100/lockhead/' + i.metadata.name : '' };
  }).sort(function (a, b) { return a.key < b.key ? -1 : 1; });

  // ── produced: Argo CD apps the platform created ──
  var argoCards = argoItems.filter(function (i) {
    return (['crossplane', 'kro'].indexOf((i.metadata.labels || {})['lockhead.cloud/managed-by']) >= 0);
  }).map(function (i) {
    var sync = (i.status && i.status.sync && i.status.sync.status) || '';
    return { key: 'argo/' + i.metadata.name, name: i.metadata.name, ns: i.metadata.namespace || 'argocd',
             kind: 'Argo CD App', cls: 'argo', state: liveReady(i), detail: detailFor('argo', i.spec, { sync: sync }) };
  }).sort(function (a, b) { return a.key < b.key ? -1 : 1; });
  // Fallback: if the managed-by label isn't on Applications, show all apps that match a Service name
  if (!argoCards.length && argoItems.length) {
    var svcNames = {}; svcItems.forEach(function (s) { svcNames[s.metadata.name] = true; });
    argoCards = argoItems.filter(function (i) { return svcNames[i.metadata.name]; }).map(function (i) {
      var sync = (i.status && i.status.sync && i.status.sync.status) || '';
      return { key: 'argo/' + i.metadata.name, name: i.metadata.name, ns: i.metadata.namespace || 'argocd',
               kind: 'Argo CD App', cls: 'argo', state: liveReady(i), detail: detailFor('argo', i.spec, { sync: sync }) };
    });
  }

  // ── produced: running workloads (deployments in team-* namespaces) ──
  var deployCards = deployItems.filter(function (i) {
    return /^team-/.test(i.metadata.namespace || '');
  }).map(function (i) {
    i.kind = 'Deployment';
    var rr = (i.status && i.status.readyReplicas) || 0, want = (i.spec && i.spec.replicas) || 1;
    return { key: 'deploy/' + i.metadata.namespace + '/' + i.metadata.name, name: i.metadata.name,
             ns: i.metadata.namespace || '', kind: 'Deployment', cls: 'deploy',
             state: liveReady(i), detail: detailFor('deploy', null, { ready: rr, want: want }) };
  }).sort(function (a, b) { return a.key < b.key ? -1 : 1; });

  // ── produced: the 3 downstream registrations (platform-owned CRDs) ──
  // Each is a typed CR with a .spec (was a ConfigMap with .data). We read the
  // relevant .spec fields for the one-line detail.
  function regCards(items, cls, kind, detailFn) {
    return (items || []).map(function (i) {
      var s = i.spec || {};
      return { key: cls + '/' + i.metadata.namespace + '/' + i.metadata.name, name: i.metadata.name,
               ns: i.metadata.namespace || '', kind: kind, cls: cls, state: 'ready', detail: detailFn(s) };
    }).sort(function (a, b) { return a.key < b.key ? -1 : 1; });
  }

  var securityCards = regCards(scanItems,  'security', 'SecurityScan',
    function (s) { return detailFor('security', s); });
  var sreCards = regCards(oncallItems, 'sre', 'OnCallRegistration',
    function (s) { return detailFor('sre', s); });
  var reportCards = regCards(reportItems, 'report', 'ReportingEntry',
    function (s) { return detailFor('report', s); });
  // FinOps — the optional "extend the platform" CRD (./demo/add-finops.sh).
  var finopsCards = regCards(finopsItems, 'finops', 'FinOpsAllocation',
    function (s) { return detailFor('finops', s); });
  // Observability — the optional Go-function extension (./demo/add-observability.sh).
  var obsCards = regCards(obsItems, 'obs', 'ObservabilitySetup',
    function (s) { return detailFor('obs', s); });

  model.produced = [
    { id: 'repo',     title: 'Git repositories',            cards: repoCards,     installed: true },
    { id: 'argo',     title: 'Argo CD applications',        cards: argoCards,     installed: responses.argo && responses.argo.status !== 404 },
    { id: 'deploy',   title: 'Running workloads',           cards: deployCards,   installed: true },
    { id: 'security', title: 'SecurityScan (platform CRD)', cards: securityCards, installed: responses.scan && responses.scan.status !== 404 },
    { id: 'sre',      title: 'OnCallRegistration (platform CRD)', cards: sreCards, installed: responses.oncall && responses.oncall.status !== 404 },
    { id: 'report',   title: 'ReportingEntry (platform CRD)', cards: reportCards, installed: responses.report && responses.report.status !== 404 }
  ];
  // Only show FinOps once the platform has been extended with it (CRD present).
  if (responses.finops && responses.finops.status !== 404) {
    model.produced.push({ id: 'finops', title: 'FinOpsAllocation (added live)', cards: finopsCards, installed: true });
  }
  // Only show Observability once the Go-function extension is installed.
  if (responses.obs && responses.obs.status !== 404) {
    model.produced.push({ id: 'obs', title: 'ObservabilitySetup (Go function, added live)', cards: obsCards, installed: true });
  }
  return model;
}

function liveSigs(model) {
  var out = {};
  model.claims.concat(model.produced).forEach(function (l) { l.cards.forEach(function (c) { out[c.key] = c.detail + '|' + c.state; }); });
  return out;
}
function liveKeys(model) {
  var out = {};
  model.claims.concat(model.produced).forEach(function (l) { l.cards.forEach(function (c) { out[c.key] = true; }); });
  return out;
}

// ── Graph view ───────────────────────────────────────────────────────────────
// Same live data as the cards, drawn as a left-to-right dependency graph:
//   col 0  the Service the developer declared
//   col 1  the Crossplane composite (XService) behind it
//   col 2  everything the Composition produced (repo, Argo app, workload, the
//          downstream registrations, and the optional FinOps / Observability)
// Edges follow "created by": a Service → its produced resources (matched by the
// lockhead.cloud/service label, which the Composition stamps on everything it
// makes) and the claim → its composite. The graph is laid out in bands — one per
// Service — so each service's fan-out stays together and the edges stay short.
// Four columns now: Service → XService → (composition function) → produced.
// Most produced resources attach straight to the composite (col 1 → col 3); the
// Go-function outputs route through their Function node (col 1 → col 2 → col 3)
// so the "the logic moved into Go" story is visible in the graph.
var GRAPH_KINDS = {
  'Service':            { col: 0, cls: 'svc',      label: 'Service' },
  'XService':           { col: 1, cls: 'comp',     label: 'XService' },
  'Function':           { col: 2, cls: 'fn',       label: 'Composition function' },
  'Git repo':           { col: 3, cls: 'repo',     label: 'Git repo' },
  'Argo CD App':        { col: 3, cls: 'argo',     label: 'Argo CD App' },
  'Deployment':         { col: 3, cls: 'deploy',   label: 'Deployment' },
  'SecurityScan':       { col: 3, cls: 'security', label: 'SecurityScan' },
  'OnCallRegistration': { col: 3, cls: 'sre',      label: 'OnCallRegistration' },
  'ReportingEntry':     { col: 3, cls: 'report',   label: 'ReportingEntry' },
  'FinOpsAllocation':   { col: 3, cls: 'finops',   label: 'FinOpsAllocation' },
  'ObservabilitySetup': { col: 3, cls: 'obs',      label: 'ObservabilitySetup' }
};
var GRAPH_COLUMN_TITLES = ['You declare', 'Crossplane composite', 'Composition function (Go)', 'Produced by the Composition'];

// Which produced kinds are composed by a Go composition function, and by which
// Function object. Only these route through a Function node; everything else
// (patch-and-transform output) attaches straight to the composite. Extend this
// map when a new Go function is added to the pipeline.
var GRAPH_FN_OUTPUTS = {
  'ObservabilitySetup': 'function-observability'
};

// Colours mirror the card palette (lockhead.cloud brand): [fill, stroke, text].
var GRAPH_COLORS = {
  svc:      ['#6083E9', '#7B50B4', '#ffffff'],   // the Service hero (flat brand blue; gradients don't render per-node cleanly)
  comp:     ['#facc15', '#a16207', '#422006'],
  fn:       ['#00ADD8', '#0b7285', '#042b32'],   // Go cyan — the composition function node
  repo:     ['#1e293b', '#6083E9', '#dbe4ff'],
  argo:     ['#3a4fb0', '#6083E9', '#ffffff'],
  deploy:   ['#1e293b', '#80a0ff', '#dbe4ff'],
  security: ['#5b3a86', '#9e6fe0', '#ffffff'],
  sre:      ['#7B50B4', '#9e6fe0', '#ffffff'],
  report:   ['#1e293b', '#9e6fe0', '#ece0ff'],
  finops:   ['#13322a', '#4ade80', '#d6ffe8'],
  obs:      ['#2a2540', '#a78bfa', '#ece6ff']
};

function graphNodeId(kind, ns, name) { return kind + '/' + (ns || '') + '/' + name; }
function graphReady(item) {
  var cs = (item.status && item.status.conditions) || [];
  var r = cs.filter(function (c) { return c.type === 'Ready'; })[0];
  if (r) return r.status === 'True' ? 'ready' : 'wait';
  if (item.status && item.status.health && item.status.health.status)
    return item.status.health.status === 'Healthy' ? 'ready' : 'wait';
  if (item.kind === 'Deployment' && item.status && item.spec)
    return (item.status.readyReplicas || 0) >= (item.spec.replicas || 1) ? 'ready' : 'wait';
  return 'none';
}
function graphSvcLabel(it) { return (it.metadata.labels || {})['lockhead.cloud/service'] || ''; }
// A Crossplane Function is "ready" when its Healthy condition is True.
function healthyFn(it) {
  var cs = (it.status && it.status.conditions) || [];
  var h = cs.filter(function (c) { return c.type === 'Healthy'; })[0];
  return !!(h && h.status === 'True');
}

// responses -> { nodes, edges }. nodes keyed by graphNodeId; edges {from,to,type}.
function graphModel(responses) {
  function ok(id) { var r = responses[id]; return (r && r.status === 200) ? r.items : []; }
  var nodes = {};
  function addNode(kind, it, extra) {
    var spec = GRAPH_KINDS[kind]; if (!spec) return null;
    var ns = (it.metadata && it.metadata.namespace) || '', name = it.metadata.name;
    var id = graphNodeId(kind, ns, name);
    nodes[id] = { id: id, kind: kind, name: name, ns: ns, col: spec.col, cls: spec.cls, label: spec.label,
                  state: extra && extra.state ? extra.state : graphReady(it),
                  svc: extra && extra.svc != null ? extra.svc : graphSvcLabel(it),
                  spec: it.spec || {}, owners: (it.metadata && it.metadata.ownerReferences) || [],
                  detail: detailFor(spec.cls, it.spec, (extra && extra.detailExtra) || {}) };
    return id;
  }

  var svcItems = ok('svc');
  // The service name a Service claim represents is just its own name here.
  svcItems.forEach(function (it) { addNode('Service', it, { svc: it.metadata.name, state: graphReady(it) }); });
  // An XService (the Crossplane composite) is named "<claim>-<random>", e.g.
  // dry1-x2t96 — NOT the claim name. Its link back to the Service is spec.claimRef
  // (fallback: the crossplane.io/claim-name label). Record that as the node's svc
  // so it lands in the right band and the edges below can find it.
  ok('xsvc').forEach(function (it) {
    var cr = (it.spec && it.spec.claimRef) || {};
    var claim = cr.name || (it.metadata.labels || {})['crossplane.io/claim-name'] || '';
    addNode('XService', it, { svc: claim });
  });

  // Produced resources. For each we record which Service it belongs to so the
  // band layout and the edges can group them. The label is the primary signal;
  // Argo apps / deployments fall back to a name match.
  var svcNames = {}; svcItems.forEach(function (s) { svcNames[s.metadata.name] = true; });

  // Git repos are synthetic nodes derived from Service.spec.repoURL.
  svcItems.forEach(function (it) {
    if (!(it.spec && it.spec.repoURL)) return;
    var full = shortRepo(it.spec.repoURL) || it.metadata.name;
    var id = graphNodeId('Git repo', '', full);
    nodes[id] = { id: id, kind: 'Git repo', name: full, ns: '', col: GRAPH_KINDS['Git repo'].col, cls: 'repo', label: 'Git repo',
                  state: 'ready', svc: it.metadata.name, spec: {}, owners: [],
                  detail: detailFor('repo', null, { repoPath: it.spec && it.spec.repoPath }) };
  });

  ok('argo').filter(function (i) {
    return (['crossplane', 'kro'].indexOf((i.metadata.labels || {})['lockhead.cloud/managed-by']) >= 0) || svcNames[i.metadata.name];
  }).forEach(function (it) {
    var sv = graphSvcLabel(it) || (svcNames[it.metadata.name] ? it.metadata.name : '');
    var sync = (it.status && it.status.sync && it.status.sync.status) || '';
    addNode('Argo CD App', it, { svc: sv, detailExtra: { sync: sync } });
  });

  // Deployments don't carry the lockhead.cloud/service label and their name is
  // the REPO/app name (e.g. legacy-orders), not the claim name (exdry1). Map the
  // repo name (tail of each Service's repoURL, or spec.name) back to the claim so
  // the workload lands in the right band. Fall back to label / name match.
  var repoToClaim = {};
  svcItems.forEach(function (s) {
    var claim = s.metadata.name;
    if (s.spec && s.spec.repoURL) { var r = shortRepo(s.spec.repoURL).split('/').pop(); if (r) repoToClaim[r] = claim; }
    if (s.spec && s.spec.name) repoToClaim[s.spec.name] = claim;
    repoToClaim[claim] = claim;
  });
  ok('deploy').filter(function (i) { return /^team-/.test(i.metadata.namespace || ''); })
    .forEach(function (it) {
      it.kind = 'Deployment';
      var app = (it.metadata.labels || {})['app'] || it.metadata.name;
      var claim = graphSvcLabel(it) || repoToClaim[app] || repoToClaim[it.metadata.name] || it.metadata.name;
      addNode('Deployment', it, { svc: claim, detailExtra: {
        ready: (it.status && it.status.readyReplicas) || 0, want: (it.spec && it.spec.replicas) || 1 } });
    });

  ok('scan').forEach(function (it) { addNode('SecurityScan', it, {}); });
  ok('oncall').forEach(function (it) { addNode('OnCallRegistration', it, {}); });
  ok('report').forEach(function (it) { addNode('ReportingEntry', it, {}); });
  ok('finops').forEach(function (it) { addNode('FinOpsAllocation', it, {}); });
  ok('obs').forEach(function (it) { addNode('ObservabilitySetup', it, {}); });

  // ── composition-function nodes (the pipeline machinery) ──
  // We only draw a Function node for a Go function that (a) exists as a live
  // Crossplane Function object and (b) actually produced a record for this
  // service — so the node appears exactly when the extension is live and
  // composing, matching how the produced records themselves appear. The node is
  // synthetic-per-service (id carries the service) so it sits inside the band
  // between the composite and the record, keeping edges short.
  var fnObjByName = {};
  ok('fn').forEach(function (it) { fnObjByName[it.metadata.name] = it; });
  // Which (fnName, service) pairs have a produced output present right now?
  var fnServicePairs = {};
  Object.keys(nodes).forEach(function (id) {
    var n = nodes[id];
    var fnName = GRAPH_FN_OUTPUTS[n.kind];
    if (fnName && n.svc) fnServicePairs[fnName + '\n' + n.svc] = true;
  });
  Object.keys(fnServicePairs).forEach(function (pair) {
    var parts = pair.split('\n'), fnName = parts[0], svc = parts[1];
    var fnObj = fnObjByName[fnName];
    // Health of the Function object itself (Healthy condition) drives the dot.
    var state = 'none';
    if (fnObj) state = graphReady(fnObj) === 'wait' ? 'wait' : (healthyFn(fnObj) ? 'ready' : 'wait');
    var id = graphNodeId('Function', '', fnName + '/' + svc);
    nodes[id] = { id: id, kind: 'Function', name: fnName, ns: '', col: 2, cls: 'fn',
                  label: 'Composition function (Go)', state: state, svc: svc,
                  spec: (fnObj && fnObj.spec) || {}, owners: [], detail: '' };
  });

  // ── edges ──
  var edges = [], seen = {};
  function add(from, to, type) {
    if (!nodes[from] || !nodes[to] || from === to) return;
    var k = from + '>' + to + ':' + type; if (seen[k]) return; seen[k] = 1;
    edges.push({ from: from, to: to, type: type });
  }
  // index Service / XService nodes by the CLAIM (service) name they represent.
  // Both use n.svc for this: Service.svc is its own name, XService.svc is its
  // claimRef name (set above) — so the composite's random suffix never matters.
  var svcNode = {}, xsvcNode = {}, fnNode = {};
  Object.keys(nodes).forEach(function (id) {
    var n = nodes[id];
    if (n.kind === 'Service') svcNode[n.svc || n.name] = id;
    if (n.kind === 'XService' && n.svc) xsvcNode[n.svc] = id;
    // index Function nodes by "<fnName>\n<service>" so a produced record can
    // find the function node that composed it, within its own band.
    if (n.kind === 'Function' && n.svc) fnNode[n.name + '\n' + n.svc] = id;
  });

  Object.keys(nodes).forEach(function (id) {
    var n = nodes[id];
    if (n.kind === 'Service') {
      // claim → its composite
      var x = xsvcNode[n.svc || n.name]; if (x) add(id, x, 'owns');
      return;
    }
    if (n.kind === 'XService') return;   // produced nodes attach to the composite / Service below
    if (n.kind === 'Function') {
      // composite → Go function (the pipeline step that runs in the Composition)
      var xf = xsvcNode[n.svc]; if (xf) add(xf, id, 'owns');
      return;
    }
    // produced resource: the composite is what actually created it, so the real
    // chain is Service → XService → produced. If this kind is composed by a Go
    // function AND that function node exists in this band, route the edge through
    // the function (XService → Function → produced) so the Go step is visible.
    // Otherwise attach straight to the composite; fall back to the Service so the
    // node is never orphaned.
    var x = xsvcNode[n.svc], s = svcNode[n.svc];
    var fnName = GRAPH_FN_OUTPUTS[n.kind];
    var fid = fnName ? fnNode[fnName + '\n' + n.svc] : null;
    if (fid) add(fid, id, 'owns');           // Function → produced (composite→Function added above)
    else if (x) add(x, id, 'owns');
    else if (s) add(s, id, 'feeds');
  });
  return { nodes: nodes, edges: edges };
}

// Layout: fixed columns, rows grouped into per-Service bands. Pure/deterministic.
var GRAPH_COL_W = 264, GRAPH_NODE_W = 210, GRAPH_NODE_H = 48, GRAPH_ROW_GAP = 6, GRAPH_PAD = 16, GRAPH_TOP = 30;

function graphLayout(model) {
  var ids = Object.keys(model.nodes);
  var cols = [[], [], [], []];
  ids.forEach(function (id) { cols[model.nodes[id].col].push(id); });

  // The composition-function column (col 2) only has nodes once a Go-function
  // extension is live. When empty, collapse it so the 3-column demo keeps its
  // tight layout and no blank gap opens between the composite and its output.
  var fnColUsed = cols[2].length > 0;
  // Pixel X of each logical column. Produced (col 3) shifts left by one column
  // width when the function column is collapsed.
  var colX = [
    GRAPH_PAD,
    GRAPH_PAD + GRAPH_COL_W,
    GRAPH_PAD + 2 * GRAPH_COL_W,
    GRAPH_PAD + (fnColUsed ? 3 : 2) * GRAPH_COL_W
  ];

  // Which Service (claim) each node belongs to — its horizontal band. Every node
  // carries the claim name in n.svc now (Service = own name, XService = claimRef
  // name, produced = service label), so one rule groups the whole chain together.
  function bandOf(id) {
    var n = model.nodes[id];
    return n.svc || (n.kind === 'Service' ? n.name : '');
  }
  // produced-kind ordering within a band (stable, reads top-to-bottom like the story)
  var kindRank = {};
  ['Git repo', 'Argo CD App', 'Deployment', 'SecurityScan', 'OnCallRegistration',
   'ReportingEntry', 'FinOpsAllocation', 'ObservabilitySetup'].forEach(function (k, i) { kindRank[k] = i; });

  // bands = sorted unique service names that have any node
  var bandNames = [];
  ids.forEach(function (id) { var b = bandOf(id); if (b && bandNames.indexOf(b) < 0) bandNames.push(b); });
  bandNames.sort();

  var rowH = GRAPH_NODE_H + GRAPH_ROW_GAP, pos = {}, y = GRAPH_TOP + GRAPH_PAD;
  bandNames.forEach(function (bk, bi) {
    var produced = cols[3].filter(function (id) { return bandOf(id) === bk; })
      .sort(function (a, b) {
        return (kindRank[model.nodes[a].kind] || 0) - (kindRank[model.nodes[b].kind] || 0)
            || model.nodes[a].name.localeCompare(model.nodes[b].name);
      });
    var fns = cols[2].filter(function (id) { return bandOf(id) === bk; });
    // The band is as tall as its widest column (produced vs function nodes).
    var rows = Math.max(produced.length, fns.length, 1);
    var bandMid = y + (rows - 1) * rowH / 2;
    // col 0 + col 1 sit centred on the band
    var svcId = cols[0].filter(function (id) { return bandOf(id) === bk; })[0];
    var xId   = cols[1].filter(function (id) { return bandOf(id) === bk; })[0];
    if (svcId) pos[svcId] = { x: colX[0], y: bandMid };
    if (xId)   pos[xId]   = { x: colX[1], y: bandMid };
    // Function node(s) centred on the band (usually one per band).
    fns.forEach(function (id, i) {
      var fy = fns.length === 1 ? bandMid : y + i * rowH;
      pos[id] = { x: colX[2], y: fy };
    });
    produced.forEach(function (id, i) { pos[id] = { x: colX[3], y: y + i * rowH }; });
    y += rows * rowH + (bi < bandNames.length - 1 ? 12 : 0);   // a little air between services
  });

  var bottom = 0; Object.keys(pos).forEach(function (id) { bottom = Math.max(bottom, pos[id].y + GRAPH_NODE_H); });
  return { pos: pos, colX: colX,
           width: colX[3] + GRAPH_NODE_W + GRAPH_PAD,
           height: Math.max(GRAPH_TOP + GRAPH_PAD * 2 + rowH, bottom + GRAPH_PAD) };
}

// The chain through a node: everything it was made from and everything made from it.
function graphChain(model, startId) {
  var inc = {}, out = {};
  model.edges.forEach(function (e) { (out[e.from] = out[e.from] || []).push(e.to); (inc[e.to] = inc[e.to] || []).push(e.from); });
  var keep = {}; keep[startId] = 1;
  (function up(id) { (inc[id] || []).forEach(function (p) { if (!keep[p]) { keep[p] = 1; up(p); } }); })(startId);
  (function down(id) { (out[id] || []).forEach(function (c) { if (!keep[c]) { keep[c] = 1; down(c); } }); })(startId);
  return keep;
}

// ── Graph view: DOM / SVG ─────────────────────────────────────────────────
var graphOn = false, graphFocus = null, graphLast = null, graphPrev = null, graphGlow = {};
var SVGNS = 'http://www.w3.org/2000/svg';
function gEl(tag, attrs, text) {
  var e = document.createElementNS(SVGNS, tag);
  for (var k in attrs) e.setAttribute(k, attrs[k]);
  if (text != null) e.textContent = text;
  return e;
}
function graphShort(s, n) { return s.length > n ? s.slice(0, n - 1) + '…' : s; }

function graphRender() {
  var host = document.getElementById('graph-svg');
  if (!host || !graphLast) return;
  var model = graphLast, L = graphLayout(model);
  var keep = graphFocus && model.nodes[graphFocus] ? graphChain(model, graphFocus) : null;
  var now = Date.now();
  host.textContent = '';
  var svg = gEl('svg', { viewBox: '0 0 ' + L.width + ' ' + L.height, width: '100%', role: 'img',
                          'aria-label': 'How one Service declaration becomes the resources the platform produces',
                          style: 'max-height:' + L.height + 'px' });
  var defs = gEl('defs', {});
  [['own', '#64748b'], ['feed', '#6083E9']].forEach(function (m) {
    var mk = gEl('marker', { id: 'arrow-' + m[0], viewBox: '0 0 10 10', refX: '9', refY: '5', markerWidth: '7', markerHeight: '7', orient: 'auto-start-reverse' });
    mk.appendChild(gEl('path', { d: 'M0 0 L10 5 L0 10 z', fill: m[1] })); defs.appendChild(mk);
  });
  svg.appendChild(defs);

  GRAPH_COLUMN_TITLES.forEach(function (t, c) {
    if (!Object.keys(model.nodes).some(function (id) { return model.nodes[id].col === c; })) return;
    svg.appendChild(gEl('text', { x: L.colX[c], y: GRAPH_PAD + 6, class: 'g-colhead' }, t.toUpperCase()));
  });

  // edges first so nodes sit on top
  model.edges.forEach(function (e) {
    var a = L.pos[e.from], b = L.pos[e.to]; if (!a || !b) return;
    var x1 = a.x + GRAPH_NODE_W, y1 = a.y + GRAPH_NODE_H / 2, x2 = b.x, y2 = b.y + GRAPH_NODE_H / 2;
    var dx = Math.max(24, (x2 - x1) / 2);
    var onChain = !keep || (keep[e.from] && keep[e.to]);
    var feeds = e.type === 'feeds';
    svg.appendChild(gEl('path', {
      d: 'M' + x1 + ' ' + y1 + ' C' + (x1 + dx) + ' ' + y1 + ',' + (x2 - dx) + ' ' + y2 + ',' + x2 + ' ' + y2,
      class: 'g-edge' + (feeds ? ' g-feeds' : '') + (onChain ? '' : ' g-dim'),
      'marker-end': 'url(#arrow-' + (feeds ? 'feed' : 'own') + ')'
    }));
  });

  // nodes
  Object.keys(model.nodes).forEach(function (id) {
    var n = model.nodes[id], p = L.pos[id]; if (!p) return;
    var col = GRAPH_COLORS[n.cls] || GRAPH_COLORS.deploy;
    var dim = keep && !keep[id];
    var fresh = graphGlow[id] && graphGlow[id] > now;
    var g = gEl('g', { class: 'g-node' + (n.cls === 'svc' ? ' g-svc' : '') + (dim ? ' g-dim' : '') + (id === graphFocus ? ' g-focus' : '') + (fresh ? ' g-new' : ''),
                       transform: 'translate(' + p.x + ',' + p.y + ')', tabindex: '0', role: 'button',
                       'aria-label': n.label + ' ' + n.name + (n.ns ? ' in ' + n.ns : '') });
    g.setAttribute('data-id', id);
    g.appendChild(gEl('rect', { width: GRAPH_NODE_W, height: GRAPH_NODE_H, rx: 6, fill: col[0], stroke: col[1], 'stroke-width': 2 }));
    g.appendChild(gEl('text', { x: 9, y: 13, class: 'g-kind', fill: col[2] }, n.label));
    var compName = componentOf(n.cls);
    if (compName) g.appendChild(gEl('text', { x: GRAPH_NODE_W - (n.state !== 'none' ? 22 : 9), y: 13, class: 'g-comp', fill: col[2], 'text-anchor': 'end' }, compName.toUpperCase()));
    g.appendChild(gEl('text', { x: 9, y: 27, class: 'g-name', fill: col[2] }, graphShort(n.name, 28)));
    if (n.detail) g.appendChild(gEl('text', { x: 9, y: 41, class: 'g-detail', fill: col[2] }, graphShort(n.detail, 34)));
    if (n.state !== 'none') g.appendChild(gEl('circle', { cx: GRAPH_NODE_W - 11, cy: 11, r: 4, class: 'g-dot g-' + n.state }));
    g.appendChild(gEl('title', {}, (compName ? '[' + compName + '] ' : '') + n.label + ' ' + n.name + (n.ns ? '  (' + n.ns + ')' : '') + (n.detail ? '  · ' + n.detail : '') + (n.state === 'ready' ? '  · Ready' : n.state === 'wait' ? '  · Reconciling' : '')));
    g.addEventListener('click', function () { graphSetFocus(id === graphFocus ? null : id); });
    g.addEventListener('keydown', function (ev) { if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); graphSetFocus(id === graphFocus ? null : id); } });
    svg.appendChild(g);
  });

  if (!Object.keys(model.nodes).length) {
    svg.appendChild(gEl('text', { x: L.width / 2, y: L.height / 2, class: 'g-empty', 'text-anchor': 'middle' },
      'Nothing onboarded yet. Run ./demo/onboard-service.sh checkout storefront.'));
  }
  host.appendChild(svg);
  var hint = document.getElementById('graph-hint');
  if (hint) hint.textContent = graphFocus && model.nodes[graphFocus]
    ? 'Showing the chain through ' + model.nodes[graphFocus].label + ' ' + model.nodes[graphFocus].name + '. Click it again, or the background, to show everything.'
    : 'Click a node to follow its chain: what it was made from and what it made.';
}

function graphSetFocus(id) { graphFocus = id; graphRender(); }

// A node's "signature": what it shows. Changing any of it (e.g. tier → re-derived
// SLO/scan/budget, or a reconcile flipping state) counts as a change worth glowing.
function graphNodeSig(n) { return (n.detail || '') + '|' + n.state; }

// called from liveTick/liveRefresh with the fresh API responses
function graphUpdate(responses) {
  var m = graphModel(responses), now = Date.now();
  // Glow a node when it's brand new OR its signature changed since the last poll —
  // mirrors the card view, so a tier/SLO/budget change lights up in the graph too.
  if (graphPrev) Object.keys(m.nodes).forEach(function (id) {
    var prev = graphPrev.nodes[id];
    if (!prev || graphNodeSig(prev) !== graphNodeSig(m.nodes[id])) graphGlow[id] = now + LIVE_GLOW_MS;
  });
  graphPrev = m; graphLast = m;
  if (graphFocus && !m.nodes[graphFocus]) graphFocus = null;
  if (graphOn) graphRender();
}

function graphToggle(on) {
  graphOn = on;
  try { localStorage.setItem('liveView', on ? 'graph' : 'cards'); } catch (e) {}
  document.getElementById('live-cols').style.display = on ? 'none' : '';
  document.getElementById('graph-wrap').style.display = on ? 'block' : 'none';
  document.getElementById('view-cards').classList.toggle('on', !on);
  document.getElementById('view-graph').classList.toggle('on', on);
  if (on) graphRender();
}

// ── DOM ──
var LIVE_BASE = location.protocol === 'file:' ? null : '';
var liveTimer = null, livePrev = null, livePaused = false;
var liveGlow = {}, LIVE_GLOW_MS = 6000;

function liveEl(tag, cls, text) {
  var e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}
// Which platform component owns each kind of resource (shown as a small tag).
var COMPONENT_BY_CLS = {
  svc: 'Crossplane', comp: 'Crossplane', fn: 'Crossplane',
  repo: 'Gitea', argo: 'Argo CD', deploy: 'Kubernetes',
  security: 'Platform API', sre: 'Platform API', report: 'Platform API',
  finops: 'Platform API', obs: 'Platform API'
};
function componentOf(cls) { return COMPONENT_BY_CLS[cls] || ''; }

function liveCard(c, isNew) {
  var d = liveEl('div', 'lcard ' + c.cls + (c.state === 'ready' ? ' ready' : c.state === 'bad' ? ' bad' : '') + (isNew ? ' new' : ''));
  var comp = componentOf(c.cls);
  if (comp) d.appendChild(liveEl('span', 'comp-tag', comp));
  d.appendChild(liveEl('span', 'k', c.kind));
  if (c.href) {
    var n = liveEl('span', 'n'); var a = document.createElement('a');
    a.href = c.href; a.target = '_blank'; a.textContent = c.name; n.appendChild(a); d.appendChild(n);
  } else {
    d.appendChild(liveEl('span', 'n', c.name));
  }
  if (c.detail) d.appendChild(liveEl('span', 'd', c.detail));
  if (c.state !== 'none') {
    var st = liveEl('span', 'st');
    st.appendChild(document.createElement('i'));
    st.appendChild(document.createTextNode(c.state === 'ready' ? 'Ready' : c.state === 'bad' ? 'Not synced' : 'Reconciling'));
    d.appendChild(st);
  }
  return d;
}
function liveRenderColumn(host, layers, isNew, ghosts) {
  host.textContent = '';
  var any = false;
  layers.forEach(function (l) {
    if (!l.cards.length && !(ghosts[l.id] || []).length) return;
    any = true;
    var box = liveEl('div', 'live-layer');
    var t = liveEl('div', 'live-layer-title');
    t.appendChild(document.createTextNode(l.title));
    var nss = {}; l.cards.forEach(function (c) { if (c.ns) nss[c.ns] = true; });
    if (Object.keys(nss).length) t.appendChild(liveEl('span', 'ns', Object.keys(nss).sort().join(' · ')));
    box.appendChild(t);
    var cards = liveEl('div', 'live-cards');
    l.cards.forEach(function (c) { cards.appendChild(liveCard(c, isNew(c.key))); });
    (ghosts[l.id] || []).forEach(function (c) { var g = liveCard(c, false); g.classList.add('gone'); cards.appendChild(g); });
    box.appendChild(cards);
    host.appendChild(box);
  });
  if (!any) host.appendChild(liveEl('div', 'live-empty', 'nothing yet — run ./demo/onboard-service.sh checkout storefront'));
}
function liveRender(model) {
  var status = document.getElementById('live-status');
  if (model.unreachable) {
    status.className = 'live-pill off';
    status.textContent = 'cluster not reachable';
    return;
  }
  status.className = 'live-pill ok';
  status.innerHTML = '<span class="dot dot-green"></span>cluster connected';

  var prevKeys = livePrev ? livePrev.keys : null;
  var keys = liveKeys(model);
  var sigs = liveSigs(model);
  var now = Date.now();
  if (livePrev) {
    Object.keys(keys).forEach(function (k) {
      if (!prevKeys[k] || livePrev.sigs[k] !== sigs[k]) liveGlow[k] = now + LIVE_GLOW_MS;
    });
  }
  var isNew = function (k) { return !!liveGlow[k] && liveGlow[k] > now; };
  var ghosts = {};
  if (livePrev) {
    livePrev.model.claims.concat(livePrev.model.produced).forEach(function (l) {
      l.cards.forEach(function (c) { if (!keys[c.key]) (ghosts[l.id] = ghosts[l.id] || []).push(c); });
    });
  }
  liveRenderColumn(document.getElementById('live-claims'), model.claims, isNew, ghosts);
  liveRenderColumn(document.getElementById('live-produced'), model.produced, isNew, ghosts);

  var claimN = 0, prodN = 0;
  model.claims.forEach(function (l) { claimN += l.cards.length; });
  model.produced.forEach(function (l) { prodN += l.cards.length; });
  var fading = Object.keys(ghosts).reduce(function (a, k) { return a + ghosts[k].length; }, 0);
  document.getElementById('live-count').textContent =
    claimN + ' service' + (claimN === 1 ? '' : 's') + ' → ' + prodN + ' produced resources' + (fading ? '  (' + fading + ' being removed)' : '');
  document.getElementById('live-note').textContent = claimN === 0
    ? 'No services onboarded yet. Use the Backstage portal, or run ./demo/onboard-service.sh checkout storefront.'
    : '';
  livePrev = { model: model, keys: keys, sigs: sigs };
}
function liveFetchAll() {
  return Promise.all(LIVE_SOURCES.map(function (s) {
    return fetch(LIVE_BASE + s.path).then(function (r) {
      if (r.status !== 200) return { id: s.id, status: r.status, items: [] };
      return r.json().then(function (j) { return { id: s.id, status: 200, items: j.items || [] }; });
    }).catch(function () { return { id: s.id, status: 0, items: [] }; });
  })).then(function (list) {
    var out = {}; list.forEach(function (r) { out[r.id] = r; }); return out;
  });
}
function liveTick(force) {
  if (livePaused && !force) return;
  if (LIVE_BASE === null) return;
  liveFetchAll().then(function (r) { liveRender(liveModel(r)); try { graphUpdate(r); } catch (e) { /* the graph must never take the cards down */ } });
}
function liveRefresh() {
  var b = document.getElementById('live-refresh');
  b.textContent = '↻ Refreshing…';
  liveFetchAll().then(function (r) {
    if (LIVE_BASE !== null) { liveRender(liveModel(r)); try { graphUpdate(r); } catch (e) {} }
    b.textContent = '↻ Refresh';
  });
}
function liveTogglePause() {
  livePaused = !livePaused;
  document.getElementById('live-pause').textContent = livePaused ? '▶ Resume' : '⏸ Pause';
}
function liveInit() {
  if (LIVE_BASE === null) {
    document.getElementById('live-status').className = 'live-pill off';
    document.getElementById('live-status').textContent = 'live view needs the proxy';
    document.getElementById('live-note').textContent =
      'Open the dashboard through ./ui.sh (it serves this page at http://localhost:8011/ui/dashboard.html). From file:// the page cannot reach the cluster.';
    return;
  }
  liveTick();
  liveTimer = setInterval(liveTick, 2000);
}

function updateToggleLabel() {
  var t = document.documentElement.getAttribute('data-theme');
  document.getElementById('theme-toggle').textContent = t === 'light' ? '🌙 Dark' : '☀️ Light';
}
function toggleTheme() {
  var next = document.documentElement.getAttribute('data-theme') === 'light' ? 'dark' : 'light';
  document.documentElement.setAttribute('data-theme', next);
  localStorage.setItem('theme', next);
  updateToggleLabel();
}
updateToggleLabel();
liveInit();
// Restore the remembered Cards/Graph choice once everything is initialised.
try { if (localStorage.getItem('liveView') === 'graph') graphToggle(true); } catch (e) {}
