#!/usr/bin/env python3
"""Render the 1.5 TiB ingest comparison (cumulative GiB written over time) as light + dark SVG.
Input: fio write bandwidth logs (time ms, KiB/s averaged over 10 s). Palette: validated categorical slots 1-3."""
import sys

RUNS = [  # (file, label, light colour, dark colour, label offset)
    ("plain.log", "Plain members", "#2a78d6", "#3987e5"),
    ("cached.log", "Cached, NAS threshold 512 MiB", "#eb6834", "#d95926"),
    ("cached1024.log", "Cached, NAS default (1 MiB)", "#1baf7a", "#199e70"),
]
THEMES = {
    "light": {"bg": "#fcfcfb", "ink": "#0b0b0b", "ink2": "#52514e", "grid": "#e6e5e1", "axis": "#9a9893"},
    "dark": {"bg": "#1a1a19", "ink": "#ffffff", "ink2": "#c3c2b7", "grid": "#33332f", "axis": "#6f6e69"},
}
W, H = 920, 500
L, R, T, B = 74, 250, 78, 58          # plot margins (right margin holds the direct labels)
XMAX, YMAX = 6.0, 1600.0               # hours, GiB


def series(path):
    pts, cum = [(0.0, 0.0)], 0.0
    for line in open(path):
        p = [x.strip() for x in line.split(",")]
        if len(p) < 2:
            continue
        t_ms, kib_s = int(p[0]), int(p[1])
        cum += kib_s * 10 / 2**20      # 10-s average -> GiB
        pts.append((t_ms / 3.6e6, cum))
    return pts


def sx(h): return L + (W - L - R) * h / XMAX
def sy(g): return T + (H - T - B) * (1 - g / YMAX)


def render(theme, data, out):
    c = THEMES[theme]
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="system-ui,-apple-system,Segoe UI,Helvetica,Arial,sans-serif">',
         f'<rect width="{W}" height="{H}" fill="{c["bg"]}"/>',
         f'<text x="{L}" y="32" font-size="18" font-weight="600" fill="{c["ink"]}">Writing 1.5 TiB of new data into the HC680 pool</text>',
         f'<text x="{L}" y="54" font-size="13" fill="{c["ink2"]}">Cumulative data written over time (fio, 1 MiB sequential, encrypted md RAID5 on 3 × dm-zoned). Steeper = faster.</text>']
    for g in range(0, 1601, 400):          # recessive grid + y labels
        y = sy(g)
        o.append(f'<line x1="{L}" y1="{y:.1f}" x2="{W - R}" y2="{y:.1f}" stroke="{c["grid"]}" stroke-width="1"/>')
        o.append(f'<text x="{L - 10}" y="{y + 4:.1f}" font-size="12" fill="{c["ink2"]}" text-anchor="end">{g}</text>')
    for h in range(0, 7):
        x = sx(h)
        o.append(f'<text x="{x:.1f}" y="{H - B + 20}" font-size="12" fill="{c["ink2"]}" text-anchor="middle">{h} h</text>')
    o.append(f'<line x1="{L}" y1="{sy(0):.1f}" x2="{W - R}" y2="{sy(0):.1f}" stroke="{c["axis"]}" stroke-width="1"/>')
    o.append(f'<text x="{L - 54}" y="{(T + H - B) / 2:.0f}" font-size="12" fill="{c["ink2"]}" transform="rotate(-90 {L - 54} {(T + H - B) / 2:.0f})" text-anchor="middle">GiB written</text>')
    # annotation: plain buffers full at ~500 GiB
    ya = sy(500)
    o.append(f'<line x1="{L}" y1="{ya:.1f}" x2="{W - R}" y2="{ya:.1f}" stroke="{c["axis"]}" stroke-width="1" stroke-dasharray="4 4"/>')
    o.append(f'<text x="{sx(2.35):.1f}" y="{ya - 8:.1f}" font-size="12" fill="{c["ink2"]}">~500 GiB: the plain members\' drive buffers are full</text>')
    labels = []
    for (f, name, lc, dc), pts in zip(RUNS, data):
        col = lc if theme == "light" else dc
        d = " ".join(f'{"M" if i == 0 else "L"}{sx(h):.1f},{sy(g):.1f}' for i, (h, g) in enumerate(pts))
        o.append(f'<path d="{d}" fill="none" stroke="{col}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>')
        h, g = pts[-1]
        o.append(f'<circle cx="{sx(h):.1f}" cy="{sy(g):.1f}" r="4.5" fill="{col}" stroke="{c["bg"]}" stroke-width="2"/>')
        labels.append((sy(g), name, col, h, g, f))
    # direct labels in the right margin, de-overlapped
    labels.sort()
    last = -1e9
    for y, name, col, h, g, f in labels:
        y = max(y, last + 34)
        last = y
        stop = "stopped" if f != "cached1024.log" else "finished"
        o.append(f'<rect x="{W - R + 16}" y="{y - 13:.1f}" width="10" height="10" rx="2" fill="{col}"/>')
        o.append(f'<text x="{W - R + 32}" y="{y - 4:.1f}" font-size="13" fill="{c["ink"]}">{name}</text>')
        o.append(f'<text x="{W - R + 32}" y="{y + 12:.1f}" font-size="12" fill="{c["ink2"]}">{g:.0f} GiB in {h:.1f} h ({stop})</text>')
    o.append(f'<text x="{L}" y="{H - 10}" font-size="11" fill="{c["ink2"]}">Plain and 512 MiB runs were stopped once their steady phase was clear. One system: DS3622xs+ + DX1222 + 3 × HC680 27 TB, guest kernel 7.2.6.</text>')
    o.append("</svg>")
    open(out, "w").write("\n".join(o) + "\n")


data = [series(sys.argv[1] + "/" + f) for f, *_ in RUNS]
for f, d in zip(RUNS, data):
    print(f[1], "points", len(d), "final %.0f GiB at %.2f h" % (d[-1][1], d[-1][0]))
render("light", data, sys.argv[2] + "/ingest-1.5tib-light.svg")
render("dark", data, sys.argv[2] + "/ingest-1.5tib-dark.svg")
