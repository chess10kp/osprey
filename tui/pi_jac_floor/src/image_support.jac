"""Jac-native runtime adapter for the ported pi-tui terminal-image byte helpers.

The js2jac conversion of `terminal-image.ts` left Node-runtime globals in
place: the `Buffer` class (base64/utf8 decode, `readUInt32BE`/`readUInt16BE`/
`readUInt16LE`/`readUInt32LE`, `.toString("ascii"|"base64")`), `Math.random()`,
and `child_process.execSync` (used only to probe tmux client features). None
exist under the Jac (CPython) runtime, so this module reproduces the surface
the converted `terminal_image.jac` depends on, backed by the stdlib.

Contract reproduced for the converted consumers:
  - buffer_from_base64(s)      -> bytes   (Buffer.from(str, "base64"))
  - buffer_from_utf8(s)        -> bytes   (Buffer.from(str))
  - to_base64(data)            -> str     (Buffer.from(x).toString("base64"))
  - read_uint32_be/read_uint16_be/read_uint16_le/read_uint32_le(buf, offset)
                                -> int     (buffer.readUInt*BE/LE(offset))
  - ascii_decode(buf, start, end) -> str  (buffer.slice(a, b).toString("ascii"))
  - random_float()             -> float   (Math.random(), [0, 1))
  - probe_tmux_client_termfeatures() -> str | None
        Faithful to `execSync("tmux display-message -p '#{client_termfeatures}'",
        {timeout: 250, ...})`: runs the real tmux binary with a short timeout
        and returns its stdout, or None on any failure (missing binary, no
        tmux server, timeout, non-zero exit) -- mirroring the try/except that
        wrapped the original execSync call.
"""

import base64;
import random;
import subprocess;

def buffer_from_base64(s: str) -> bytes {
    return base64.b64decode(s);
}

def buffer_from_utf8(s: str) -> bytes {
    return s.encode("utf-8");
}

def to_base64(data: bytes) -> str {
    return base64.b64encode(data).decode("ascii");
}

def read_uint32_be(buf: bytes, offset: int) -> int {
    return int.from_bytes(buf[offset:(offset + 4)], "big");
}

def read_uint16_be(buf: bytes, offset: int) -> int {
    return int.from_bytes(buf[offset:(offset + 2)], "big");
}

def read_uint16_le(buf: bytes, offset: int) -> int {
    return int.from_bytes(buf[offset:(offset + 2)], "little");
}

def read_uint32_le(buf: bytes, offset: int) -> int {
    return int.from_bytes(buf[offset:(offset + 4)], "little");
}

def ascii_decode(buf: bytes, start: int, end: int) -> str {
    return buf[start:end].decode("ascii", errors="replace");
}

def random_float() -> float {
    return random.random();
}

def probe_tmux_client_termfeatures() -> str | None {
    try {
        result = subprocess.run(
            ["tmux", "display-message", "-p", "#{client_termfeatures}"],
            capture_output=True,
            text=True,
            timeout=0.25
        );
        if result.returncode != 0 {
            return None;
        }
        return result.stdout;
    } except Exception {
        return None;
    }
}
