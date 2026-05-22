"""jackal-shell — run the minimal Jackal TUI."""

import subprocess;
import sys;
import from pathlib { Path }


def main() {
    base = Path(__file__) if __file__ else Path(".");
    agent_next_dir = base.parent.parent;

    shell_js = agent_next_dir / "templates" / "shell.mjs";
    if not shell_js.exists() {
        print(f"Error: {shell_js} not found");
        sys.exit(1);
    }

    print("Building agent-next adapter...");
    build = subprocess.run(["npm", "run", "-s", "build:agent"], cwd=str(agent_next_dir.parent));
    if build.returncode != 0 {
        print("Build failed.");
        sys.exit(1);
    }

    print("Starting Jackal...");
    try {
        child = subprocess.run(["node", str(shell_js)], cwd=str(agent_next_dir.parent));
        sys.exit(child.returncode);
    } except KeyboardInterrupt {
        sys.exit(0);
    }
}

with entry {
    main();
}
