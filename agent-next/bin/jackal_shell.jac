"""jackal-shell — launch Jackal via jac-ink."""

import subprocess;
import sys;
import from pathlib { Path }


def main() {
    base = Path(__file__) if __file__ else Path(".");
    agent_next_dir = base.parent.parent;
    repo_root = agent_next_dir.parent;

    shell_jac = agent_next_dir / "templates" / "shell.cl.jac";
    if not shell_jac.exists() {
        print(f"Error: {shell_jac} not found");
        sys.exit(1);
    }

    print("Building agent-next adapter...");
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
                "--with_pi", "--install", "--run",
            ],
            cwd=str(agent_next_dir),
        );
        sys.exit(child.returncode);
    } except KeyboardInterrupt {
        sys.exit(0);
    }
}

with entry {
    main();
}
