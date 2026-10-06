"""Regroupe les rapports JSON de trivy (reports/*.json) en un seul rapport HTML lisible.

Usage : python3 scripts/trivy-report.py [reports/] [-o reports/rapport-trivy.html]
Sections : synthèse par image, paquets à mettre à jour (toutes images confondues),
puis le détail de chaque image et les vulnérabilités sans correctif. Fichier autonome.
"""

from __future__ import annotations

import argparse
import collections
import html
import json
from datetime import datetime
from pathlib import Path

SEVERITIES = ("CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN")
LABELS = {"CRITICAL": "Critique", "HIGH": "Haute", "MEDIUM": "Moyenne", "LOW": "Basse", "UNKNOWN": "Inconnue"}
ORIGIN = {"python-pkg": "Python", "rustbinary": "binaire Rust", "cargo": "Rust (cargo)", "gobinary": "binaire Go"}


def origin(result_type: str, os_family: str) -> str:
    if result_type == os_family:
        return f"système ({os_family})"
    return ORIGIN.get(result_type, result_type)


def load(directory: Path) -> list[dict]:
    images = []
    for path in sorted(directory.glob("*.json")):
        data = json.loads(path.read_text())
        os_family = data.get("Metadata", {}).get("OS", {}).get("Family", "?")
        vulns = []
        for result in data.get("Results", []):
            for v in result.get("Vulnerabilities") or []:
                vulns.append({
                    "id": v["VulnerabilityID"],
                    "severity": v.get("Severity", "UNKNOWN"),
                    "pkg": v.get("PkgName", "?"),
                    "installed": v.get("InstalledVersion", ""),
                    "fixed": v.get("FixedVersion", ""),
                    "title": v.get("Title") or (v.get("Description") or "")[:140],
                    "url": v.get("PrimaryURL", ""),
                    "origin": origin(result.get("Type", "?"), os_family),
                    "target": result.get("Target", ""),
                })
        vulns.sort(key=lambda v: (SEVERITIES.index(v["severity"]), v["pkg"], v["id"]))
        images.append({
            "name": path.stem,
            "image": data.get("ArtifactName", path.stem),
            "os": f'{os_family} {data.get("Metadata", {}).get("OS", {}).get("Name", "")}'.strip(),
            "created": data.get("CreatedAt", ""),
            "vulns": vulns,
        })
    return images


def badge(sev: str) -> str:
    return f'<span class="sev {sev.lower()}">{LABELS[sev]}</span>'


def counts_cells(vulns: list[dict]) -> str:
    total = collections.Counter(v["severity"] for v in vulns)
    fixable = collections.Counter(v["severity"] for v in vulns if v["fixed"])
    cells = []
    for sev in SEVERITIES[:4]:
        n = total[sev]
        cells.append(f'<td class="num {"zero" if not n else sev.lower()}">{n}'
                     + (f' <small>({fixable[sev]})</small>' if n else "") + "</td>")
    return "".join(cells)


def render(images: list[dict]) -> str:
    esc = html.escape
    all_vulns = [v | {"image": img["name"]} for img in images for v in img["vulns"]]
    scan_dates = sorted({img["created"][:10] for img in images if img["created"]})

    summary_rows = "".join(
        f'<tr><td><a href="#{esc(img["name"])}">{esc(img["name"])}</a></td>{counts_cells(img["vulns"])}'
        f'<td class="num">{len(img["vulns"])}</td></tr>'
        for img in images)

    # Paquets à mettre à jour : une ligne par (paquet, origine), toutes images confondues.
    by_pkg: dict[tuple[str, str], dict] = {}
    for v in all_vulns:
        entry = by_pkg.setdefault((v["pkg"], v["origin"]), {
            "installed": set(), "fixed": set(), "cves": set(), "images": set(), "worst": "UNKNOWN"})
        entry["installed"].add(v["installed"])
        entry["cves"].add(v["id"])
        entry["images"].add(v["image"])
        if v["fixed"]:
            entry["fixed"].add(v["fixed"])
        if SEVERITIES.index(v["severity"]) < SEVERITIES.index(entry["worst"]):
            entry["worst"] = v["severity"]
    pkg_rows = "".join(
        f'<tr><td>{badge(e["worst"])}</td><td><code>{esc(pkg)}</code></td><td>{esc(orig)}</td>'
        f'<td><code>{esc(", ".join(sorted(e["installed"])))}</code></td>'
        f'<td><code>{esc(", ".join(sorted(e["fixed"])) or "aucun correctif")}</code></td>'
        f'<td class="num">{len(e["cves"])}</td><td>{esc(", ".join(sorted(e["images"])))}</td></tr>'
        for (pkg, orig), e in sorted(by_pkg.items(),
                                     key=lambda kv: (SEVERITIES.index(kv[1]["worst"]), kv[0])))

    sections = []
    for img in images:
        if img["vulns"]:
            rows = "".join(
                f'<tr><td>{badge(v["severity"])}</td>'
                f'<td><a href="{esc(v["url"])}">{esc(v["id"])}</a></td>'
                f'<td><code>{esc(v["pkg"])}</code><br><small>{esc(v["origin"])}</small></td>'
                f'<td><code>{esc(v["installed"])}</code></td>'
                f'<td><code>{esc(v["fixed"] or "—")}</code></td><td>{esc(v["title"])}</td></tr>'
                for v in img["vulns"])
            body = ('<table><thead><tr><th>Gravité</th><th>CVE</th><th>Paquet</th><th>Installé</th>'
                    f'<th>Corrigé en</th><th>Description</th></tr></thead><tbody>{rows}</tbody></table>')
        else:
            body = '<p class="clean">Aucune vulnérabilité détectée.</p>'
        sections.append(f'<section id="{esc(img["name"])}"><h3>{esc(img["name"])}</h3>'
                        f'<p class="meta"><code>{esc(img["image"])}</code> · {esc(img["os"])}</p>{body}</section>')

    total = collections.Counter(v["severity"] for v in all_vulns)
    fixable = collections.Counter(v["severity"] for v in all_vulns if v["fixed"])
    clean = sum(1 for img in images if not img["vulns"])

    def tile(sev: str, color: str, label: str) -> str:
        return (f'<div class="tile"><b style="color:var(--{color})">{total[sev]} '
                f'<small>({fixable[sev]})</small></b>{label}</div>')

    # Vulnérabilités sans correctif : une ligne par (CVE, paquet), toutes images confondues.
    unfixed: dict[tuple[str, str], dict] = {}
    for v in all_vulns:
        if not v["fixed"]:
            unfixed.setdefault((v["id"], v["pkg"]), v | {"images": set()})["images"].add(v["image"])
    unfixed_rows = "".join(
        f'<tr><td>{badge(v["severity"])}</td><td><a href="{esc(v["url"])}">{esc(v["id"])}</a></td>'
        f'<td><code>{esc(v["pkg"])}</code><br><small>{esc(v["origin"])}</small></td>'
        f'<td><code>{esc(v["installed"])}</code></td><td>{esc(", ".join(sorted(v["images"])))}</td>'
        f'<td>{esc(v["title"])}</td></tr>'
        for v in sorted(unfixed.values(), key=lambda v: (SEVERITIES.index(v["severity"]), v["pkg"], v["id"])))
    unfixed_body = (
        '<div class="wrap"><table><thead><tr><th>Gravité</th><th>CVE</th><th>Paquet</th><th>Installé</th>'
        f'<th>Images</th><th>Description</th></tr></thead><tbody>{unfixed_rows}</tbody></table></div>'
        if unfixed_rows else '<p class="clean">Toutes les vulnérabilités ont un correctif.</p>')
    return f"""<!doctype html>
<html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Rapport trivy</title>
<style>
:root {{ --bg:#fafaf9; --fg:#1c1917; --muted:#78716c; --line:#e7e5e4;
  --darkred:#7f1d1d; --red:#dc2626; --orange:#ea580c; --green:#16a34a; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg:#1c1917; --fg:#f5f5f4; --muted:#a8a29e;
  --line:#44403c; --darkred:#b91c1c; --red:#ef4444; --orange:#f97316; --green:#22c55e; }} }}
body {{ background:var(--bg); color:var(--fg); font:15px/1.5 system-ui,sans-serif; margin:0 auto; max-width:1200px; padding:24px 16px; }}
h1 {{ margin:0 0 4px; }} h2 {{ margin-top:40px; border-bottom:1px solid var(--line); padding-bottom:6px; }}
.meta, small {{ color:var(--muted); }}
table {{ border-collapse:collapse; width:100%; margin:8px 0 24px; }}
th, td {{ border-bottom:1px solid var(--line); padding:6px 10px; text-align:left; vertical-align:top; }}
th {{ font-size:13px; color:var(--muted); }}
td.num {{ text-align:right; font-variant-numeric:tabular-nums; white-space:nowrap; }}
/* Code couleur : rouge foncé = critique, rouge = haute, orange = moyenne, vert = basse et aucune CVE. */
td.zero {{ color:var(--muted); }}
td.critical {{ color:var(--darkred); font-weight:700; }} td.high {{ color:var(--red); font-weight:600; }} td.medium {{ color:var(--orange); font-weight:600; }}
td.low {{ color:var(--green); }}
.sev {{ font-size:12px; font-weight:600; padding:2px 8px; border-radius:10px; color:#fff; white-space:nowrap; }}
.sev.critical {{ background:var(--darkred); }} .sev.high {{ background:var(--red); }} .sev.medium {{ background:var(--orange); }}
.sev.low, .sev.unknown {{ background:var(--green); }}
.clean {{ color:var(--green); font-weight:600; }}
.tiles {{ display:flex; gap:12px; flex-wrap:wrap; margin:16px 0; }}
.tile {{ border:1px solid var(--line); border-radius:8px; padding:10px 16px; min-width:120px; }}
.tile b {{ display:block; font-size:24px; }}
/* Certains navigateurs donnent un fond sombre à <code> : neutralisé. */
code {{ font-size:13px; background:none; color:inherit; padding:0; }} a {{ color:inherit; }}
:root {{ color-scheme:light dark; }}
/* Impression et PDF : thème clair, couleurs des pastilles conservées, lignes non coupées. */
@media print {{
  :root {{ --bg:#fff; --fg:#1c1917; --muted:#57534e; --line:#d6d3d1; color-scheme:light; }}
  body {{ max-width:none; padding:0; font-size:11px; }}
  .sev, .tile b {{ -webkit-print-color-adjust:exact; print-color-adjust:exact; }}
  tr {{ break-inside:avoid; }} h2, h3 {{ break-after:avoid; }}
  @page {{ size:A4 landscape; margin:12mm; }}
}}
.wrap {{ overflow-x:auto; }}
</style></head><body>
<h1>Rapport trivy — images durcies Fred</h1>
<p class="meta">{len(images)} images · scan du {esc(", ".join(scan_dates))} · généré le {datetime.now():%d/%m/%Y %H:%M}
 · entre parenthèses : vulnérabilités qui ont un correctif</p>
<div class="tiles">
{tile("CRITICAL", "darkred", "critiques")}
{tile("HIGH", "red", "hautes")}
{tile("MEDIUM", "orange", "moyennes")}
{tile("LOW", "green", "basses")}
<div class="tile"><b style="color:var(--green)">{clean}/{len(images)}</b>images sans CVE</div>
</div>
<h2>Synthèse par image</h2>
<div class="wrap"><table><thead><tr><th>Image</th><th>Critique</th><th>Haute</th><th>Moyenne</th><th>Basse</th><th>Total</th></tr></thead>
<tbody>{summary_rows}</tbody></table></div>
<h2>Paquets à mettre à jour</h2>
<p class="meta">Une ligne par paquet, toutes images confondues ; gravité = la plus haute de ses CVE.</p>
<div class="wrap"><table><thead><tr><th>Gravité</th><th>Paquet</th><th>Origine</th><th>Installé</th><th>Corrigé en</th><th>CVE</th><th>Images</th></tr></thead>
<tbody>{pkg_rows}</tbody></table></div>
<h2>Détail par image</h2>
<div class="wrap">{"".join(sections)}</div>
<h2>Vulnérabilités sans correctif</h2>
<p class="meta">Aucune version corrigée n'est publiée : à suivre, ou à couvrir par une autre mesure.</p>
{unfixed_body}
</body></html>
"""


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("directory", nargs="?", default="reports", type=Path)
    parser.add_argument("-o", "--output", type=Path)
    args = parser.parse_args()
    output = args.output or args.directory / "rapport-trivy.html"
    output.write_text(render(load(args.directory)))
    print(f"Écrit : {output}")


if __name__ == "__main__":
    main()
