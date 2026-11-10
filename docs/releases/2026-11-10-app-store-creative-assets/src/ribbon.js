// Shared drawing helpers for the creative assets.
if (location.hash === '#debug') document.body.classList.add('debug');

const SVGNS = 'http://www.w3.org/2000/svg';
const STRIPES = ['#c9687f', '#d18a65', '#d2c76f', '#709778', '#688fa8'];
const GLOW = ['#ff7fa0', '#ffa36f', '#f6e27a', '#86d39a', '#7fb8ff'];

// First path length at which pred(point) holds.
function lengthWhere(path, pred, step = 1, from = 0) {
  const L = path.getTotalLength();
  for (let s = from; s <= L; s += step) if (pred(path.getPointAtLength(s))) return s;
  return L;
}

// Samples a path between two lengths with unit normals, for true parallel offsets.
function sample(path, from, to, step = 1.5) {
  const L = path.getTotalLength();
  to = Math.min(to, L);
  const pts = [];
  for (let s = from; s <= to + 1e-6; s += step) {
    const a = path.getPointAtLength(Math.max(0, s - 1));
    const b = path.getPointAtLength(Math.min(L, s + 1));
    const p = path.getPointAtLength(s);
    const tx = b.x - a.x, ty = b.y - a.y, n = Math.hypot(tx, ty) || 1;
    pts.push({ x: p.x, y: p.y, nx: -ty / n, ny: tx / n });
  }
  return pts;
}

function band(pts, a, b) {
  const f = pts.map(p => `${(p.x + p.nx * a).toFixed(2)},${(p.y + p.ny * a).toFixed(2)}`);
  const r = pts.slice().reverse().map(p => `${(p.x + p.nx * b).toFixed(2)},${(p.y + p.ny * b).toFixed(2)}`);
  return `M${f.join('L')}L${r.join('L')}Z`;
}

function add(parent, d, fill) {
  const el = document.createElementNS(SVGNS, 'path');
  el.setAttribute('d', d);
  el.setAttribute('fill', fill);
  parent.appendChild(el);
  return el;
}

// Five-stripe prism tape along a path. parts: [[groupSelector, fromLen, toLen], ...]
function drawRainbow(path, { width, glow, parts, shade }) {
  const w = width / STRIPES.length;
  if (shade) { // soft shadow cast by the stretch of tape that crosses over itself
    const [sel, from, to] = shade;
    add(document.querySelector(sel), band(sample(path, from, to, 2).map(p => ({ ...p, y: p.y + 14 })), -width / 2, width / 2), '#0b0812');
  }
  if (glow) {
    const g = document.querySelector(glow);
    const pts = sample(path, 0, Infinity, 3);
    STRIPES.forEach((_, i) => add(g, band(pts, -width / 2 + w * i - 3, -width / 2 + w * (i + 1) + 3), GLOW[i]));
  }
  for (const [sel, from, to] of parts) {
    const g = document.querySelector(sel);
    const pts = sample(path, from, to);
    STRIPES.forEach((c, i) => add(g, band(pts, -width / 2 + w * i - .6, -width / 2 + w * (i + 1) + .6), c));
    // a thin gloss along the top edge reads as tape, not paint
    add(g, band(pts, -width / 2, -width / 2 + 2.5), 'rgba(255,255,255,.35)');
  }
}

// Sets a textPath's startOffset so its text (text-anchor=end) stops `pad` px
// before the path first enters the given element's box (in that element's own coordinates).
function endWordsAtCassette(pathId, textPathId, bodyId, pad) {
  const path = document.getElementById(pathId);
  const body = document.getElementById(bodyId);
  const inv = body.getCTM().inverse();
  const svg = body.ownerSVGElement;
  const bb = body.getBBox();
  const pathCTM = path.getCTM();
  const inside = p => {
    let q = svg.createSVGPoint(); q.x = p.x; q.y = p.y;
    q = q.matrixTransform(pathCTM).matrixTransform(inv);
    return q.x >= bb.x && q.x <= bb.x + bb.width && q.y >= bb.y && q.y <= bb.y + bb.height;
  };
  const enter = lengthWhere(path, inside);
  document.getElementById(textPathId).setAttribute('startOffset', enter - pad);
}
