/** Node shims for Python stdlib used by diff_engine.cl.jac in the TUI bundle. */

import fs from "node:fs";
import nodeOs from "node:os";
import nodePath from "node:path";

export class Path {
  constructor(p) {
    this._p = nodePath.resolve(String(p));
  }

  static join(base, rel) {
    return new Path(nodePath.join(String(base), String(rel)));
  }

  exists() {
    return fs.existsSync(this._p);
  }

  read_text(_encodingArg, encoding = "utf8") {
    return fs.readFileSync(this._p, encoding);
  }

  write_text(content, _encodingArg, encoding = "utf8") {
    fs.writeFileSync(this._p, content, encoding);
  }

  get parent() {
    const dir = nodePath.dirname(this._p);
    return {
      mkdir(_mode, _bufferSize, _existOk, recursive = true) {
        fs.mkdirSync(dir, { recursive: Boolean(recursive) });
      },
    };
  }
}

export const os = {
  get_terminal_size() {
    const cols = process.stdout.columns ?? 80;
    const rows = process.stdout.rows ?? 24;
    return { columns: cols, rows };
  },
  getcwd() {
    return process.cwd();
  },
  environ: process.env,
  remove(p) {
    fs.unlinkSync(p);
  },
};

export const tempfile = {
  NamedTemporaryFile(_mode, _buf, _encoding, _prefix, suffix = "", ..._rest) {
    const name = nodePath.join(
      nodeOs.tmpdir(),
      `jackal-diff-${process.pid}-${Date.now()}${suffix}`,
    );
    return {
      name,
      write(content) {
        fs.writeFileSync(name, content, "utf8");
      },
      close() {},
    };
  },
};

function matchWithGroups(m) {
  if (!m) return null;
  return {
    group(n) {
      return m[n];
    },
  };
}

export const re = {
  sub(pattern, repl, text) {
    const rx =
      pattern instanceof RegExp
        ? pattern
        : new RegExp(String(pattern).replace(/^r["']|["']$/g, ""), "g");
    return String(text).replace(rx, repl);
  },
  search(pattern, text) {
    const rx = pattern instanceof RegExp ? pattern : new RegExp(pattern);
    return matchWithGroups(rx.exec(String(text)));
  },
  escape(s) {
    return String(s).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  },
};
