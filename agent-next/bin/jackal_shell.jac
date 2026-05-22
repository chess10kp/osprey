"""jackal-shell — Run the Jackal TUI coding agent.

Builds the adapter if needed, then runs the shell.

Usage:
    jac run jackal_shell.jac
"""

import subprocess;
import sys;
import from pathlib { Path }


def main() {
    # Resolve paths relative to this file
    base = Path(__file__) if __file__ else Path(".");
    repo_dir = base.parent.parent;
    shell_path = repo_dir / "templates" / "shell.mjs";

    if not shell_path.exists() {
        print(f"Error: shell not found at {shell_path}");
        sys.exit(1);
    }

    # Build adapter if dist/ is missing
    dist_dir = repo_dir / "dist";
    if not dist_dir.exists() {
        print("🔨 Building adapter...");
        result = subprocess.run(
            ["npx", "tsc", "-p", "tsconfig.json"],
            cwd=str(repo_dir),
        );
        if result.returncode != 0 {
            print("❌ Build failed.");
            sys.exit(1);
        }
        print("✅ Build complete.");
    }

    # Run the shell
    print("🐺 Starting Jackal...\n");
    try {
        child = subprocess.run(
            ["node", str(shell_path)],
            cwd=str(repo_dir),
        );
        sys.exit(child.returncode);
    } except KeyboardInterrupt {
        sys.exit(0);
    }
}


with entry {
    main();
}
