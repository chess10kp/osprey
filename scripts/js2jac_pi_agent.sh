#!/usr/bin/env bash
# Re-run js2jac floor conversion for pi-agent-core (+ optional sibling packages).
# Mirrors tui/scripts/js2jac_pi_tui.sh — emit floor under app/pi_agent_floor/.
set -euo pipefail

PI_ROOT="${PI_AGENT_SRC:-/home/jac/repos/notes/reference/pi/packages}"
# Space-separated package dirs under PI_ROOT (agent = pi-agent-core).
PACKAGES="${PI_PACKAGES:-agent}"
JACKAL="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${PI_AGENT_OUT:-$JACKAL/app/pi_agent_floor}"
DRIVER="$JACKAL/tui/scripts/holeconvert.mjs"
[[ -f "$DRIVER" ]] || { echo "missing holeconvert: $DRIVER"; exit 1; }

export PATH="$HOME/.local/bin:$PATH"
command -v jac >/dev/null || { echo "jac not on PATH"; exit 1; }
command -v bun >/dev/null || { echo "bun required for holeconvert.mjs"; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"

python3 - "$PI_ROOT" "$OUT" "$DRIVER" "$PACKAGES" <<'PY'
import json, re, subprocess, sys
from pathlib import Path

pi_root, out, driver = map(Path, sys.argv[1:4])
packages_s = sys.argv[4]
packages = [p for p in packages_s.split() if p]
summary = []

def snake_seg(seg):
    if seg in (".", ".."):
        return seg
    out_seg = re.sub(r"[^A-Za-z0-9_]+", "_", seg)
    if re.match(r"^[0-9]", out_seg):
        out_seg = "_" + out_seg
    return out_seg or "_"

def jac_out_rel(pkg: str, rel: Path) -> Path:
    # Keep package name as top segment so multi-package floors don't collide.
    stem_parts = (Path(pkg) / rel.with_suffix("")).parts
    return Path(*(snake_seg(p) for p in stem_parts)).with_suffix(".jac")

seen_out_paths = {}

for pkg in packages:
    src = pi_root / pkg / "src"
    if not src.is_dir():
        summary.append({"path": f"{pkg}/src", "status": "missing_src"})
        continue
    for fp in sorted(src.rglob("*.ts")):
        if fp.name.endswith(".d.ts"):
            continue
        rel = fp.relative_to(pi_root / pkg)
        js = fp.read_text(errors="replace")
        p = subprocess.run(
            ["bun", str(driver)],
            input=json.dumps({"js": js, "path": f"{pkg}/{rel}"}),
            capture_output=True, text=True, timeout=120,
        )
        try:
            res = json.loads(p.stdout)
        except Exception as e:
            summary.append({"path": f"{pkg}/{rel}", "status": "driver_error", "error": str(e), "stderr": p.stderr[-500:]})
            continue
        if not res.get("ok"):
            summary.append({
                "path": f"{pkg}/{rel}",
                "status": "reject",
                "codes": res.get("codes", []),
                "error": res.get("error"),
            })
            continue
        jac = res.get("jac", "")
        out_rel = jac_out_rel(pkg, rel)
        out_key = str(out_rel)
        if out_key in seen_out_paths:
            print(
                f"COLLISION: {pkg}/{rel} and {seen_out_paths[out_key]} both snake_case to {out_key}",
                file=sys.stderr,
            )
            summary.append({"path": f"{pkg}/{rel}", "status": "collision", "conflicts_with": seen_out_paths[out_key]})
            continue
        seen_out_paths[out_key] = f"{pkg}/{rel}"
        out_path = out / out_rel
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(jac)
        holes = jac.count("JS2JAC-HOLE")
        cp = subprocess.run(
            ["jac", "check", str(out_path)],
            capture_output=True, text=True, timeout=90,
        )
        check_ok = cp.returncode == 0 and "FAILED" not in (cp.stdout + cp.stderr)
        summary.append({
            "path": f"{pkg}/{rel}",
            "out": out_key,
            "status": "floor",
            "bytes": len(jac),
            "holes": holes,
            "jac_check": check_ok,
        })

cp = subprocess.run(
    ["jac", "check", str(out)],
    capture_output=True, text=True, timeout=300,
)
project_ok = cp.returncode == 0 and "FAILED" not in (cp.stdout + cp.stderr)
(out.parent / "pi_agent_floor_project_check.txt").write_text(cp.stdout + cp.stderr)
(out.parent / "pi_agent_floor_summary.json").write_text(json.dumps(summary, indent=2))

floor = [s for s in summary if s.get("status") == "floor"]
reject = [s for s in summary if s.get("status") == "reject"]
zero_hole = [s for s in floor if s.get("holes", 0) == 0]
check_pass = [s for s in floor if s.get("jac_check")]
print(
    f"packages={packages} floor={len(floor)} reject={len(reject)} "
    f"zero_hole={len(zero_hole)} check_pass={len(check_pass)} "
    f"project_check={'PASS' if project_ok else 'FAIL'}"
)
if reject:
    for r in reject:
        print(f"  REJECT {r['path']} codes={r.get('codes')} err={r.get('error')}")
PY

echo "Wrote $OUT"
echo "Summary: $JACKAL/app/pi_agent_floor_summary.json"
