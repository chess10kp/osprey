"""jackal-shell — launch Jackal via the canonical jackal.sh launcher."""

import subprocess;
import sys;
import from pathlib { Path }


def main() {
    base = Path(__file__) if __file__ else Path(".");
    repo_root = base.parent.parent;
    launcher = repo_root / "jackal.sh";
    if not launcher.exists() {
        print(f"Error: {launcher} not found");
        sys.exit(1);
    }

    # Forward CLI args (--check, run, --mode, etc.) to jackal.sh.
    args = [str(launcher), *list(sys.argv[1:])];
    try {
        child = subprocess.run(args, cwd=str(repo_root));
        sys.exit(child.returncode);
    } except KeyboardInterrupt {
        sys.exit(130);
    }
}

with entry {
    main();
}
