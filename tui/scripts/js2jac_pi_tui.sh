#!/usr/bin/env bash
# Re-run js2jac floor conversion for pi-tui reference sources.
set -euo pipefail

JAC_REPO="${JAC_LLM_JAC:-/home/jac/repos/jac_llm_data/jaseci/jac}"
PI_TUI="${PI_TUI_SRC:-/home/jac/repos/notes/reference/pi/packages/tui}"
JACKAL_TUI="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$JACKAL_TUI/pi_jac_floor"
DRIVER="$JACKAL_TUI/scripts/holeconvert.mjs"
[[ -f "$DRIVER" ]] || DRIVER="$JAC_REPO/../scripts/js2jac_dataset/source/holeconvert.mjs"
[[ -f "$DRIVER" ]] || DRIVER="/home/jac/repos/jac_llm_data/scripts/js2jac_dataset/source/holeconvert.mjs"

export PATH="$HOME/.local/bin:$PATH"
command -v jac >/dev/null || { echo "jac not on PATH"; exit 1; }
command -v bun >/dev/null || { echo "bun required for holeconvert.mjs"; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"

python3 - "$PI_TUI" "$OUT" "$DRIVER" "$JAC_REPO" <<'PY'
import json, subprocess, sys
from pathlib import Path

pi_tui, out, driver, jac_repo = map(Path, sys.argv[1:5])
src = pi_tui / "src"
summary = []

for fp in sorted(src.rglob("*.ts")):
    rel = fp.relative_to(pi_tui)
    js = fp.read_text(errors="replace")
    p = subprocess.run(
        ["bun", str(driver)],
        input=json.dumps({"js": js, "path": str(rel)}),
        capture_output=True, text=True, timeout=120,
    )
    try:
        res = json.loads(p.stdout)
    except Exception as e:
        summary.append({"path": str(rel), "status": "driver_error", "error": str(e)})
        continue
    if not res.get("ok"):
        summary.append({"path": str(rel), "status": "reject"})
        continue
    jac = res.get("jac", "")
    out_path = out / rel.with_suffix(".jac")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(jac)
    holes = jac.count("JS2JAC-HOLE")
    cp = subprocess.run(
        ["jac", "check", str(out_path)],
        capture_output=True, text=True, timeout=90, cwd=str(jac_repo),
    )
    check_ok = cp.returncode == 0 and "FAILED" not in (cp.stdout + cp.stderr)
    summary.append({
        "path": str(rel),
        "status": "floor",
        "bytes": len(jac),
        "holes": holes,
        "jac_check": check_ok,
    })

# Project-mode check: whole floor tree, cross-file imports resolve.
cp = subprocess.run(
    ["jac", "check", str(out)],
    capture_output=True, text=True, timeout=180, cwd=str(jac_repo),
)
project_ok = cp.returncode == 0 and "FAILED" not in (cp.stdout + cp.stderr)
(out.parent / "pi_jac_floor_project_check.txt").write_text(cp.stdout + cp.stderr)

(out.parent / "pi_jac_floor_summary.json").write_text(json.dumps(summary, indent=2))
floor = [s for s in summary if s.get("status") == "floor"]
print(f"floor={len(floor)} reject={len(summary)-len(floor)} check_pass={sum(1 for s in floor if s.get('jac_check'))} project_check={'PASS' if project_ok else 'FAIL'}")
PY

echo "Wrote $OUT"
