"""jackal-shell — Compile and run the minimal Jackal TUI (no Pi interop)."""

import json;
import shutil;
import subprocess;
import sys;
import from pathlib { Path }


def main() {
    base = Path(__file__) if __file__ else Path(".");
    repo_dir = base.parent.parent;

    tui_dir = repo_dir / ".jac" / "tui";
    shell_cl = repo_dir / "templates" / "shell.cl.jac";
    if not shell_cl.exists() {
        print(f"Error: {shell_cl} not found");
        sys.exit(1);
    }

    print("Compiling shell.cl.jac via jac-tui...");
    jac_result = subprocess.run(
        ["jac", "jac2ink", str(shell_cl), "--out", str(tui_dir), "--no_pi"],
        capture_output=True,
        text=True,
    );
    if jac_result.returncode != 0 {
        print(f"jac2ink failed: {jac_result.stderr}");
        sys.exit(1);
    }

    runner_src = repo_dir / "templates" / "runner.mjs";
    runner_dst = tui_dir / "runner.mjs";
    shutil.copy2(str(runner_src), str(runner_dst));

    pkg_path = tui_dir / "package.json";
    pkg = json.loads(pkg_path.read_text());
    deps = pkg.get("dependencies", {});
    pkg["dependencies"] = deps;
    pkg_path.write_text(json.dumps(pkg, indent=2) + "\n");

    if not (tui_dir / "node_modules").exists() {
        print("Installing dependencies...");
        result = subprocess.run(
            ["npm", "install", "--ignore-scripts"], cwd=str(tui_dir), timeout=120,
        );
        if result.returncode != 0 {
            print("npm install failed.");
            sys.exit(1);
        }
    }

    print("Starting Jackal...");
    try {
        child = subprocess.run(["node", "runner.mjs"], cwd=str(tui_dir),);
        sys.exit(child.returncode);
    } except KeyboardInterrupt {
        sys.exit(0);
    }
}


with entry {
    main();
}
