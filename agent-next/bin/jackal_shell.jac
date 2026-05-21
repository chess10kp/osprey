"""jackal-shell — Scaffold and run the Jackal Ink TUI shell.

Usage:
    jac run jackal_shell.jac                           # run in current directory
    jac run jackal_shell.jac -- /path/to/project       # run in specific project
    jac run jackal_shell.jac -- --scaffold-only         # just scaffold, don't run
    jac run jackal_shell.jac -- --help
"""

import json;
import os;
import subprocess;
import sys;
import from pathlib { Path }


glob PI_SDK_VERSION = "0.75.4";
glob INK_VERSION = "^7.0.3";
glob REACT_VERSION = "^19.2.4";

glob PKG_DEPS: dict[str, str] = {
         "ink": INK_VERSION,
         "react": REACT_VERSION,
         "@earendil-works/pi-coding-agent": PI_SDK_VERSION,

     };


"""Create the shell scaffold in target_dir/.jac/jackal-shell/."""
def scaffold(target_dir: str) -> str {
    out_dir = str(Path(target_dir) / ".jac" / "jackal-shell");
    Path(out_dir).mkdir(parents=True, exist_ok=True);

    base = Path(__file__) if __file__ else Path(".");
    this_dir = str(base.parent);
    template_path = str(Path(this_dir) / "shell.cl.jac");

    if not Path(template_path).exists() {
        print(f"Error: shell template not found at {template_path}");
        sys.exit(1);
    }

    # Copy the template
    dest_shell = str(Path(out_dir) / "shell.cl.jac");
    content = Path(template_path).read_text();
    Path(dest_shell).write_text(content);

    # Write package.json
    pkg = {
        "name": "jackal-shell",
        "private": True,
        "type": "module",
        "scripts": {"start": "node shell.mjs"},
        "dependencies": PKG_DEPS,

    };
    pkg_path = str(Path(out_dir) / "package.json");
    Path(pkg_path).write_text(json.dumps(pkg, indent=2) + "\n");

    return out_dir;
}


"""Run npm install in out_dir. Returns True on success."""
def install_deps(out_dir: str) -> bool {
    print("📦 Installing dependencies...");
    try {
        subprocess.run(
            ["npm", "install", "--ignore-scripts"],
            cwd=out_dir,
            check=True,
            timeout=120,
        );
        return True;
    } except Exception {
        print("❌ npm install failed. Try running manually:");
        print(f"   cd {out_dir} && npm install --ignore-scripts");
        return False;
    }
}


"""Spawn the shell as a child process."""
def run_shell(out_dir: str) {
    print("🐺 Starting Jackal...\n");
    try {
        child = subprocess.run(["node", "shell.mjs"], cwd=out_dir,);
        sys.exit(child.returncode);
    } except KeyboardInterrupt {
        sys.exit(0);
    }
}


def main() {
    args = sys.argv[1:];
    scaffold_only = False;
    target_dir = os.getcwd();

    for arg in args {
        if arg == "--scaffold-only" {
            scaffold_only = True;
        } elif arg == "--help" or arg == "-h" {
            print("jackal-shell — Run the Jackal Ink TUI coding agent\n");
            print("Usage:");
            print("  jac run jackal_shell.jac [options] [directory]\n");
            print("Options:");
            print("  --scaffold-only   Create the scaffold without running");
            print("  --help, -h        Show this help");
            sys.exit(0);
        } elif not arg.startswith("-") {
            target_dir = str(Path(arg).resolve());
        }
    }

    out_dir = scaffold(target_dir);
    print(f"✅ Shell scaffolded in {out_dir}");

    if scaffold_only {
        print(
            f"\nTo run:\n  cd {out_dir}\n  npm install --ignore-scripts\n  npm start"
        );
        sys.exit(0);
    }

    if not Path(str(Path(out_dir) / "node_modules")).exists() {
        if not install_deps(out_dir) {
            sys.exit(1);
        }
    }

    run_shell(out_dir);
}


with entry {
    main();
}
