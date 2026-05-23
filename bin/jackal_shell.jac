"""jackal-shell — launch Jackal via jac-ink."""

import subprocess;
import sys;
import from pathlib { Path }


def main() {
    base = Path(__file__) if __file__ else Path(".");
    repo_root = base.parent.parent;
    shell_jac = repo_root / "templates" / "shell.cl.jac";
    if not shell_jac.exists() {
        print(f"Error: {shell_jac} not found");
        sys.exit(1);
    }

    print("Building Jackal adapter...");
    build = subprocess.run(["npm", "run", "-s", "build:agent"], cwd=str(repo_root));
    if build.returncode != 0 {
        print("Build failed.");
        sys.exit(1);
    }

    print("Starting Jackal...");
    try {
        child = subprocess.run(
            [
                "jac", "tui", str(shell_jac),
                "--install", "--run",
            ],
            cwd=str(repo_root),
        );
        sys.exit(child.returncode);
    } except KeyboardInterrupt {
        sys.exit(0);
    }
}

with entry {
    main();
}
