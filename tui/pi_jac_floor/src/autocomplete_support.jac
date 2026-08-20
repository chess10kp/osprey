"""Jac-native runtime adapter for the ported pi-tui autocomplete boundary.

`autocomplete.ts` shells out to Node's `child_process.spawn` to run the `fd`
file finder, and touches `fs.readdirSync`/`fs.statSync`, `os.homedir()`, and
`path.basename/dirname/join` for local completion. None of that exists under
the Jac (CPython) runtime, so this module reproduces the surface the converted
`autocomplete.jac` depends on, backed by the stdlib:

  - readdirSync(dir, {"withFileTypes": True}) -> list[DirEntry]
        DirEntry.name / .isDirectory() / .isSymbolicLink() mirror Node's
        fs.Dirent (lstat-based, symlinks NOT followed for isDirectory()).
  - statSync(path) -> StatResult   (follows symlinks; raises like fs.statSync
        when the path is missing -- callers already wrap this in try/except).
  - homedir() -> str
  - basename(path) / dirname(path) / join(*parts) -> str  (posixpath-backed)
  - run_fd(fd_path, args, timeout_s) -> dict {"ok": bool, "stdout": str}
        Runs the `fd` binary synchronously via subprocess.run, bounded by a
        timeout. Any failure (binary missing, non-zero exit, timeout) reports
        ok=False so the caller falls back to an empty result list -- this
        replaces the original spawn()/Promise/AbortSignal dance since a
        headless `jac run` has no ambient event loop to drive it async.
"""

import os;
import subprocess;

obj:pub StatResult {
    has _isdir: bool = False;

    def isDirectory() -> bool { return self._isdir; }
}

def:pub statSync(p: str) -> StatResult {
    if not os.path.exists(p) {
        raise OSError(f"ENOENT: no such file or directory, stat '{p}'");
    }
    return StatResult(_isdir=os.path.isdir(p));
}

obj:pub DirEntry {
    has name: str = "";
    has _is_dir: bool = False;
    has _is_symlink: bool = False;

    def isDirectory() -> bool { return self._is_dir; }
    def isSymbolicLink() -> bool { return self._is_symlink; }
}

def:pub readdirSync(dir_path: str, options: any = None) -> list[DirEntry] {
    entries: list[DirEntry] = [];
    with os.scandir(dir_path) as it {
        for e in it {
            entries.append(DirEntry(name=e.name, _is_dir=e.is_dir(follow_symlinks=False), _is_symlink=e.is_symlink()));
        }
    }
    return entries;
}

def:pub homedir() -> str {
    return os.path.expanduser("~");
}

def:pub basename(p: str) -> str {
    return os.path.basename(p);
}

def:pub dirname(p: str) -> str {
    return os.path.dirname(p);
}

def:pub join(*parts: any) -> str {
    return os.path.join(*parts);
}

def:pub run_fd(fd_path: str, args: list[str], timeout_s: float = 2.0) -> dict[str, bool | str] {
    try {
        result = subprocess.run([fd_path, *args], capture_output=True, text=True, timeout=timeout_s);
        if result.returncode != 0 {
            return {"ok": False, "stdout": ""};
        }
        return {"ok": True, "stdout": result.stdout};
    } except Exception {
        return {"ok": False, "stdout": ""};
    }
}
