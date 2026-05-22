"""jackal-shell — Compile, build, and run the Jackal TUI.

Usage:
    jac run jackal_shell.jac
    jac run jackal_shell.jac -- --install
"""

import json;
import os;
import shutil;
import subprocess;
import sys;
import from pathlib { Path }


def main() {
    base = Path(__file__) if __file__ else Path(".");
    repo_dir = base.parent.parent;
    cwd = os.getcwd();

    # Step 1: Build the TS adapter if dist/ is missing
    dist_dir = repo_dir / "dist";
    if not dist_dir.exists() {
        print("Building adapter...");
        result = subprocess.run(
            ["npx", "tsc", "-p", "tsconfig.json"], cwd=str(repo_dir),
        );
        if result.returncode != 0 {
            print("Build failed.");
            sys.exit(1);
        }
        print("Adapter built.");
    }

    # Step 2: Compile shell.cl.jac via jac-tui
    tui_dir = repo_dir / ".jac" / "tui";
    shell_cl = repo_dir / "templates" / "shell.cl.jac";
    if not shell_cl.exists() {
        print(f"Error: {shell_cl} not found");
        sys.exit(1);
    }

    print("Compiling shell.cl.jac via jac-tui...");
    jac_result = subprocess.run(
        ["jac", "jac2ink", str(shell_cl), "--out", str(tui_dir), "--with_pi"],
        capture_output=True,
        text=True,
    );
    if jac_result.returncode != 0 {
        print(f"jac2ink failed: {jac_result.stderr}");
        sys.exit(1);
    }

    # Step 3: Copy our custom runner that boots the adapter
    runner_src = repo_dir / "templates" / "runner.mjs";
    runner_dst = tui_dir / "runner.mjs";
    shutil.copy2(str(runner_src), str(runner_dst));

    # Step 4: Add our adapter dist to the deps
    pkg_path = tui_dir / "package.json";
    pkg = json.loads(pkg_path.read_text());
    deps = pkg.get("dependencies", {});
    deps["@earendil-works/pi-coding-agent"] = "0.75.4";
    deps["@earendil-works/pi-ai"] = "0.75.4";
    pkg["dependencies"] = deps;
    pkg_path.write_text(json.dumps(pkg, indent=2) + "\n");

    # Step 5: Install if needed
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

    # Step 6: Link adapter dist so runner.mjs can import it
    # runner.mjs does: import from "../dist/index.js"
    # which resolves relative to .jac/tui/runner.mjs → .jac/dist/index.js
    # We need it to resolve to agent-next/dist/index.js
    # Solution: symlink
    link_dst = tui_dir.parent / "dist";
    if not link_dst.exists() {
        link_dst.symlink_to(str(repo_dir / "dist"));
    }

    # Step 7: Run
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
