#!/usr/bin/env python3
"""Turn `scroll-bench --offline --sweep` output into an HTML page of small
multiples: per recorded path, the stutter metrics against the resampling
latency, with the trace's p75–p95 lateness band, its p90, and the knee the
bench found — so the knee can be *seen*, not just read off a table.

    .build/release/scroll-bench --offline --sweep --trials 8 \
        --latencies 0,1,2,...,20,22,24 --replay bench/captures/*.csv > sweep.txt
    bench/plot-sweep.py sweep.txt -o bench/captures/latency-sweep.html

Reads stdin when no file is given. The page is self-contained (data inline,
no network), hover gives every metric at a latency, a table view holds the
same numbers, and it follows the OS light/dark setting.
"""
import argparse
import json
import re
import sys

HEADER = re.compile(
    r"^== (\S+) pad (\d+): (\d+) runs, (\d+) frames; lateness p50 ([\d.]+)\s+p75 ([\d.]+)"
    r"\s+p90 ([\d.]+)\s+p95 ([\d.]+)\s+max ([\d.]+)",
    re.M,
)
ROW = re.compile(
    r"^\s+(\d+) ms\s+([\d.]+)%\s+([\d.]+)%\s+([\d.]+)%\s+([\d.]+) ms\s+([\d.]+) px\s+([\d.]+) px",
    re.M,
)
KNEE = re.compile(r"knee: (\d+) ms")

PATH_NAMES = {
    "usb-host_wired-split": ("USB host", "wired split"),
    "usb-host_ble-split": ("USB host", "BLE split"),
    "ble-host_wired-split": ("BLE host", "wired split"),
    "ble-host_ble-split": ("BLE host", "BLE split"),
    "ble-host_ble-split_3txbuf": ("BLE host", "BLE split, 3 TX bufs"),
}


def parse(text):
    paths = []
    for block in re.split(r"\n(?===)", text):
        m = HEADER.match(block)
        if not m or "skipped" in block:
            continue
        stem = m[1].replace(".csv", "")
        host, split = PATH_NAMES.get(stem, (stem, ""))
        pad = int(m[2])
        rows = [
            dict(latency=int(r[1]), zero=float(r[2]), multi=float(r[3]), cv=float(r[4]),
                 shown=float(r[5]), maxErr=float(r[6]), landing=float(r[7]))
            for r in ROW.finditer(block)
        ]
        knee = KNEE.search(block)
        paths.append(dict(
            file=m[1], pad=pad,
            title=f"{host} · {split}",
            subtitle=f"{'local' if pad == 0 else 'relayed'} pad {pad} · {m[3]} runs, {m[4]} frames",
            p50=float(m[5]), p75=float(m[6]), p90=float(m[7]), p95=float(m[8]), max=float(m[9]),
            knee=int(knee[1]) if knee else None, rows=rows,
        ))
    return paths


TEMPLATE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Scroll stutter vs resampling latency</title>
<style>
  :root { color-scheme: light dark; }
  .viz-root {
    color-scheme: light;
    --page: #f9f9f7; --surface: #fcfcfb;
    --ink: #0b0b0b; --ink-2: #52514e; --muted: #898781;
    --grid: #e1e0d9; --axis: #c3c2b7; --border: rgba(11,11,11,0.10);
    --series-1: #2a78d6; --series-2: #eb6834;
    --band: rgba(137,135,129,0.12);
  }
  @media (prefers-color-scheme: dark) {
    :root:where(:not([data-theme="light"])) .viz-root {
      color-scheme: dark;
      --page: #0d0d0d; --surface: #1a1a19;
      --ink: #ffffff; --ink-2: #c3c2b7; --muted: #898781;
      --grid: #2c2c2a; --axis: #383835; --border: rgba(255,255,255,0.10);
      --series-1: #3987e5; --series-2: #d95926;
      --band: rgba(137,135,129,0.18);
    }
  }
  :root[data-theme="dark"] .viz-root {
    color-scheme: dark;
    --page: #0d0d0d; --surface: #1a1a19;
    --ink: #ffffff; --ink-2: #c3c2b7; --muted: #898781;
    --grid: #2c2c2a; --axis: #383835; --border: rgba(255,255,255,0.10);
    --series-1: #3987e5; --series-2: #d95926;
    --band: rgba(137,135,129,0.18);
  }
  html, body { margin: 0; }
  .viz-root {
    font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
    background: var(--page); color: var(--ink);
    min-height: 100vh; padding: 28px 32px 40px;
  }
  h1 { font-size: 20px; font-weight: 600; margin: 0 0 4px; }
  .lede { color: var(--ink-2); font-size: 14px; max-width: 78ch; margin: 0 0 16px; line-height: 1.45; }
  .controls { display: flex; flex-wrap: wrap; align-items: center; gap: 18px; margin: 0 0 18px; font-size: 13px; color: var(--ink-2); }
  .controls label { display: inline-flex; align-items: center; gap: 6px; cursor: pointer; }
  .controls button { font: inherit; color: var(--ink-2); background: var(--surface); border: 1px solid var(--border); border-radius: 6px; padding: 4px 10px; cursor: pointer; }
  .legend { display: inline-flex; gap: 16px; align-items: center; }
  .legend span { display: inline-flex; align-items: center; gap: 6px; }
  .key { display: inline-block; width: 18px; height: 2px; border-radius: 1px; }
  .swatch-band { display: inline-block; width: 14px; height: 10px; background: var(--band); border: 1px solid var(--grid); }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 16px; }
  .panel { background: var(--surface); border: 1px solid var(--border); border-radius: 10px; padding: 12px 12px 6px; }
  .panel h2 { font-size: 14px; font-weight: 600; margin: 0; }
  .panel .sub { font-size: 12px; color: var(--ink-2); margin: 2px 0 6px; }
  .panel .sub strong { color: var(--ink); font-weight: 600; }
  svg { display: block; width: 100%; height: auto; overflow: visible; }
  svg text { font-family: inherit; font-size: 11px; fill: var(--muted); font-variant-numeric: tabular-nums; }
  svg text.label { fill: var(--ink-2); }
  svg text.strong { fill: var(--ink); font-weight: 600; }
  .plot-hit { fill: transparent; cursor: crosshair; outline: none; }
  .plot-hit:focus-visible { stroke: var(--series-1); stroke-width: 1; }
  .tooltip {
    position: fixed; pointer-events: none; z-index: 10; display: none;
    background: var(--surface); color: var(--ink); border: 1px solid var(--border);
    border-radius: 8px; padding: 8px 10px; font-size: 12px; box-shadow: 0 4px 16px rgba(0,0,0,0.12);
    font-variant-numeric: tabular-nums; min-width: 180px;
  }
  .tooltip .t { font-weight: 600; margin-bottom: 4px; }
  .tooltip .row { display: flex; justify-content: space-between; gap: 14px; }
  .tooltip .row .v { font-weight: 600; }
  .tooltip .row .n { color: var(--ink-2); display: inline-flex; align-items: center; gap: 6px; }
  table { border-collapse: collapse; font-size: 12px; margin-top: 18px; font-variant-numeric: tabular-nums; background: var(--surface); }
  th, td { padding: 4px 10px; text-align: right; border-bottom: 1px solid var(--grid); }
  th { color: var(--ink-2); font-weight: 600; }
  td:first-child, th:first-child { text-align: left; }
  .hidden { display: none; }
  .note { font-size: 12px; color: var(--muted); margin-top: 18px; max-width: 90ch; line-height: 1.45; }
</style>
</head>
<body>
<div class="viz-root" id="root">
  <h1>Scroll stutter against resampling latency, per recorded path</h1>
  <p class="lede">Each panel replays one recording's real frame delivery through RawTouch's pipeline
  at every latency on the x axis. The lines are the steady-drag stutter metrics: the spread of the
  per-display-frame delta (CV) and the share of display frames that got no motion. The band is
  where the recording's arrival lateness sits (p75 to p95), the hairline its p90 — what the
  adaptive estimator adopts — and the dot the knee: the smallest latency with no empty frames and
  CV within two points of the sweep's best.</p>
  <div class="controls">
    <span class="legend">
      <span><i class="key" style="background: var(--series-1)"></i>Delta spread, CV %</span>
      <span><i class="key" style="background: var(--series-2)"></i>Empty display frames %</span>
      <span><i class="swatch-band"></i>Lateness p75–p95</span>
    </span>
    <label><input type="checkbox" id="shared"> Same y scale on every panel</label>
    <button type="button" id="table-toggle" aria-expanded="false">Show table</button>
    <button type="button" id="theme-toggle">Dark mode</button>
  </div>
  <div class="grid" id="grid"></div>
  <p class="note">Hover or focus a panel and use ← → to read every metric at a latency (mean sample-to-display time, worst position error and landing offset are in the readout and the table). The bench: <code>scroll-bench --offline --sweep --replay &lt;capture&gt;</code>; steady drag of 2,400 counts/s, 100 Hz frames, simulated 120 Hz vsync.</p>
  <div id="table-wrap" class="hidden"></div>
  <div class="tooltip" id="tooltip" role="status" aria-live="polite"></div>
</div>
<script>
const DATA = __DATA__;
const SVG = "http://www.w3.org/2000/svg";
const W = 320, H = 200, M = { l: 34, r: 14, t: 14, b: 26 };
const XMAX = Math.max(...DATA.flatMap(p => p.rows.map(r => r.latency)));
const METRICS = [
  { key: "cv", name: "Delta spread, CV", unit: "%", color: "var(--series-1)" },
  { key: "zero", name: "Empty display frames", unit: "%", color: "var(--series-2)" },
];
const EXTRA = [
  { key: "shown", name: "Shown after", unit: " ms" },
  { key: "maxErr", name: "Worst position error", unit: " px" },
  { key: "landing", name: "Landing past the stop", unit: " px" },
];
const el = (tag, attrs = {}, parent) => {
  const node = document.createElementNS(SVG, tag);
  for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
  if (parent) parent.appendChild(node);
  return node;
};
const text = (parent, x, y, s, attrs = {}) => {
  const t = el("text", { x, y, ...attrs }, parent);
  t.textContent = s;
  return t;
};
const nice = v => { if (v <= 10) return 10; if (v <= 20) return 20; if (v <= 40) return 40; if (v <= 60) return 60; if (v <= 80) return 80; return 100; };
const globalMax = nice(Math.max(...DATA.flatMap(p => p.rows.flatMap(r => [r.cv, r.zero]))));
const tooltip = document.getElementById("tooltip");
const fmt = (v, unit) => (unit === "%" ? v.toFixed(1) + "%" : v.toFixed(unit.trim() === "ms" ? 1 : 2) + unit);

function render() {
  const shared = document.getElementById("shared").checked;
  const grid = document.getElementById("grid");
  grid.replaceChildren();
  for (const path of DATA) {
    const panel = document.createElement("section");
    panel.className = "panel";
    const h = document.createElement("h2"); h.textContent = path.title; panel.appendChild(h);
    const sub = document.createElement("p"); sub.className = "sub";
    sub.append(path.subtitle + " · p90 ");
    const s1 = document.createElement("strong"); s1.textContent = path.p90.toFixed(1) + " ms"; sub.appendChild(s1);
    sub.append(" · knee ");
    const s2 = document.createElement("strong"); s2.textContent = path.knee == null ? "beyond the sweep" : path.knee + " ms"; sub.appendChild(s2);
    panel.appendChild(sub);
    panel.appendChild(chart(path, shared ? globalMax : nice(Math.max(...path.rows.flatMap(r => [r.cv, r.zero])))));
    grid.appendChild(panel);
  }
}

function chart(path, ymax) {
  const svg = el("svg", { viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": `${path.title}: stutter against latency` });
  const pw = W - M.l - M.r, ph = H - M.t - M.b;
  const x = v => M.l + (v / XMAX) * pw;
  const y = v => M.t + ph - (Math.min(v, ymax) / ymax) * ph;

  // Lateness band (p75–p95) and the p90 hairline, behind everything.
  el("rect", { x: x(path.p75), y: M.t, width: Math.max(1, x(path.p95) - x(path.p75)), height: ph, fill: "var(--band)" }, svg);
  el("line", { x1: x(path.p90), x2: x(path.p90), y1: M.t, y2: M.t + ph, stroke: "var(--axis)", "stroke-width": 1 }, svg);
  text(svg, x(path.p90) + 3, M.t + 9, "p90", { class: "label" });

  // Grid + axes: hairline, recessive.
  for (let i = 0; i <= 4; i++) {
    const v = (ymax / 4) * i;
    el("line", { x1: M.l, x2: W - M.r, y1: y(v), y2: y(v), stroke: i === 0 ? "var(--axis)" : "var(--grid)", "stroke-width": 1 }, svg);
    text(svg, M.l - 5, y(v) + 4, (Number.isInteger(v) ? v : v.toFixed(1)) + "%", { "text-anchor": "end" });
  }
  for (let v = 0; v <= XMAX; v += 5) text(svg, x(v), H - 8, v + (v === 0 ? " ms" : ""), { "text-anchor": v === 0 ? "start" : "middle" });

  // Series lines.
  for (const m of METRICS) {
    const d = path.rows.map((r, i) => `${i ? "L" : "M"}${x(r.latency).toFixed(1)},${y(r[m.key]).toFixed(1)}`).join(" ");
    el("path", { d, fill: "none", stroke: m.color, "stroke-width": 2, "stroke-linejoin": "round", "stroke-linecap": "round" }, svg);
  }

  // The knee: a marker on the CV line with a surface ring and a label.
  if (path.knee != null) {
    const row = path.rows.find(r => r.latency === path.knee);
    if (row) {
      el("circle", { cx: x(row.latency), cy: y(row.cv), r: 6, fill: "var(--surface)" }, svg);
      el("circle", { cx: x(row.latency), cy: y(row.cv), r: 4, fill: "var(--series-1)" }, svg);
      // To the right of the dot, where the curve has already flattened
      // below the label; only a knee near the right edge goes left.
      const left = row.latency > XMAX - 5;
      text(svg, x(row.latency) + (left ? -9 : 9), y(row.cv) - 9, `knee ${row.latency} ms`, { class: "strong", "text-anchor": left ? "end" : "start" });
    }
  }

  // Hover layer: crosshair snapping to the nearest latency, dots on both
  // series, one readout with every metric.
  const cross = el("line", { y1: M.t, y2: M.t + ph, stroke: "var(--ink-2)", "stroke-width": 1, visibility: "hidden" }, svg);
  const dots = METRICS.map(m => el("circle", { r: 4, fill: m.color, stroke: "var(--surface)", "stroke-width": 2, visibility: "hidden" }, svg));
  const hit = el("rect", { class: "plot-hit", x: M.l, y: M.t, width: pw, height: ph, tabindex: 0 }, svg);
  let index = -1;
  const show = (i, clientX, clientY) => {
    index = i;
    const r = path.rows[i];
    cross.setAttribute("x1", x(r.latency)); cross.setAttribute("x2", x(r.latency)); cross.setAttribute("visibility", "visible");
    METRICS.forEach((m, k) => { dots[k].setAttribute("cx", x(r.latency)); dots[k].setAttribute("cy", y(r[m.key])); dots[k].setAttribute("visibility", "visible"); });
    tooltip.replaceChildren();
    const t = document.createElement("div"); t.className = "t"; t.textContent = `${path.title} · ${r.latency} ms latency`; tooltip.appendChild(t);
    for (const m of [...METRICS, ...EXTRA]) {
      const line = document.createElement("div"); line.className = "row";
      const n = document.createElement("span"); n.className = "n";
      if (m.color) { const k = document.createElement("i"); k.className = "key"; k.style.background = m.color; n.appendChild(k); }
      n.append(m.name);
      const v = document.createElement("span"); v.className = "v"; v.textContent = fmt(r[m.key], m.unit);
      line.append(n, v); tooltip.appendChild(line);
    }
    tooltip.style.display = "block";
    const tw = tooltip.offsetWidth, th = tooltip.offsetHeight;
    tooltip.style.left = Math.min(clientX + 14, window.innerWidth - tw - 8) + "px";
    tooltip.style.top = Math.min(clientY + 14, window.innerHeight - th - 8) + "px";
  };
  const hide = () => { cross.setAttribute("visibility", "hidden"); dots.forEach(d => d.setAttribute("visibility", "hidden")); tooltip.style.display = "none"; index = -1; };
  hit.addEventListener("pointermove", e => {
    const box = svg.getBoundingClientRect();
    const lat = ((e.clientX - box.left) / box.width * W - M.l) / pw * XMAX;
    let best = 0;
    path.rows.forEach((r, i) => { if (Math.abs(r.latency - lat) < Math.abs(path.rows[best].latency - lat)) best = i; });
    show(best, e.clientX, e.clientY);
  });
  hit.addEventListener("pointerleave", hide);
  hit.addEventListener("focus", () => { const box = hit.getBoundingClientRect(); show(Math.max(index, 0), box.left + 20, box.top + 20); });
  hit.addEventListener("blur", hide);
  hit.addEventListener("keydown", e => {
    if (e.key !== "ArrowLeft" && e.key !== "ArrowRight") return;
    e.preventDefault();
    const box = hit.getBoundingClientRect();
    show(Math.max(0, Math.min(path.rows.length - 1, (index < 0 ? 0 : index) + (e.key === "ArrowRight" ? 1 : -1))), box.left + 20, box.top + 20);
  });
  return svg;
}

function table() {
  const wrap = document.getElementById("table-wrap");
  const t = document.createElement("table");
  const head = t.createTHead().insertRow();
  for (const s of ["Path", "Pad", "Latency", "CV %", "Empty %", "2+ deltas %", "Shown after (ms)", "Worst error (px)", "Landing (px)", "p75", "p90", "p95", "Knee"]) {
    const th = document.createElement("th"); th.textContent = s; head.appendChild(th);
  }
  const body = t.createTBody();
  for (const p of DATA) for (const r of p.rows) {
    const tr = body.insertRow();
    for (const v of [p.title, p.pad, r.latency, r.cv.toFixed(1), r.zero.toFixed(1), r.multi.toFixed(1), r.shown.toFixed(1), r.maxErr.toFixed(2), r.landing.toFixed(2), p.p75.toFixed(1), p.p90.toFixed(1), p.p95.toFixed(1), p.knee ?? "–"]) {
      tr.insertCell().textContent = String(v);
    }
  }
  wrap.replaceChildren(t);
}

document.getElementById("shared").addEventListener("change", render);
document.getElementById("table-toggle").addEventListener("click", e => {
  const wrap = document.getElementById("table-wrap");
  const open = wrap.classList.toggle("hidden") === false;
  e.currentTarget.textContent = open ? "Hide table" : "Show table";
  e.currentTarget.setAttribute("aria-expanded", String(open));
});
document.getElementById("theme-toggle").addEventListener("click", e => {
  const root = document.documentElement;
  const dark = root.getAttribute("data-theme") !== "dark"
    && !(root.getAttribute("data-theme") == null && matchMedia("(prefers-color-scheme: dark)").matches);
  root.setAttribute("data-theme", dark ? "dark" : "light");
  e.currentTarget.textContent = dark ? "Light mode" : "Dark mode";
});
render();
table();
</script>
</div>
</body>
</html>
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("sweep", nargs="?", help="scroll-bench --sweep output (default: stdin)")
    parser.add_argument("-o", "--output", default="latency-sweep.html")
    args = parser.parse_args()
    text = open(args.sweep).read() if args.sweep else sys.stdin.read()
    paths = parse(text)
    if not paths:
        sys.exit("no sweep blocks found in the input")
    html = TEMPLATE.replace("__DATA__", json.dumps(paths))
    with open(args.output, "w") as f:
        f.write(html)
    print(f"wrote {args.output}: {len(paths)} path(s), {sum(len(p['rows']) for p in paths)} rows")


if __name__ == "__main__":
    main()
