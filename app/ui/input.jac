"""Byte → host-event normalization and coalescing.

Raw terminal bytes never become UiEvent walkers. This module:
  1. Buffers incomplete escape sequences until they are complete (or flushed).
  2. Lifts bracketed paste blocks into a single PasteEvent.
  3. Maps common key sequences to KeyEvent identities.
  4. Coalesces resize storms, mouse-motion floods, and stream chunks so the
     host loop can select one semantic event per turn (OSPUI §13.1 / §14).

Does not import ui.events — walker construction stays with the host loop.
"""

import re;


glob ESC = "\x1b";
glob BRACKETED_PASTE_START = "\x1b[200~";
glob BRACKETED_PASTE_END = "\x1b[201~";


obj HostEvent {
    has kind: str = "";
}


obj TextEvent(HostEvent) {
    has text: str = "";

    def init(text: str = "") {
        self.kind = "text";
        self.text = text;
    }
}


obj KeyEvent(HostEvent) {
    has key: str = "";

    def init(key: str = "") {
        self.kind = "key";
        self.key = key;
    }
}


obj PasteEvent(HostEvent) {
    has text: str = "";

    def init(text: str = "") {
        self.kind = "paste";
        self.text = text;
    }
}


obj ResizeEvent(HostEvent) {
    has width: int = 0,
        height: int = 0;

    def init(width: int = 0, height: int = 0) {
        self.kind = "resize";
        self.width = width;
        self.height = height;
    }
}


obj MouseEvent(HostEvent) {
    has button: int = 0,
        x: int = 0,
        y: int = 0,
        pressed: bool = False,
        motion: bool = False;

    def init(
        button: int = 0,
        x: int = 0,
        y: int = 0,
        pressed: bool = False,
        motion: bool = False,
    ) {
        self.kind = "mouse";
        self.button = button;
        self.x = x;
        self.y = y;
        self.pressed = pressed;
        self.motion = motion;
    }
}


obj StreamChunkEvent(HostEvent) {
    has text: str = "";

    def init(text: str = "") {
        self.kind = "stream";
        self.text = text;
    }
}


def _is_complete_csi(data: str) -> str {
    if not data.startswith(ESC + "[") {
        return "complete";
    }
    if len(data) < 3 {
        return "incomplete";
    }
    payload = data[2:];
    last = payload[len(payload) - 1];
    code = ord(last);
    if code >= 64 and code <= 126 {
        if payload.startswith("<") {
            # SGR mouse: ESC [ < btn ; x ; y M/m
            if re.match(r"^<\d+;\d+;\d+[Mm]$", payload) is not None {
                return "complete";
            }
            if last == "M" or last == "m" {
                return "incomplete";
            }
            return "incomplete";
        }
        return "complete";
    }
    return "incomplete";
}


def _is_complete_osc(data: str) -> str {
    if not data.startswith(ESC + "]") {
        return "complete";
    }
    if data.endswith(ESC + "\\") or data.endswith("\x07") {
        return "complete";
    }
    return "incomplete";
}


def sequence_status(data: str) -> str {
    if not data.startswith(ESC) {
        return "not-escape";
    }
    if len(data) == 1 {
        return "incomplete";
    }
    after = data[1:];
    if after.startswith("[") {
        if after.startswith("[M") {
            return "complete" if len(data) >= 6 else "incomplete";
        }
        return _is_complete_csi(data);
    }
    if after.startswith("]") {
        return _is_complete_osc(data);
    }
    if after.startswith("P") or after.startswith("_") {
        if data.endswith(ESC + "\\") or data.endswith("\x07") {
            return "complete";
        }
        return "incomplete";
    }
    if after.startswith("O") {
        return "complete" if len(after) >= 2 else "incomplete";
    }
    if len(after) == 1 {
        return "complete";
    }
    return "complete";
}


"""Split a buffer into complete sequences and an incomplete remainder."""
def extract_sequences(buffer: str) -> dict[str, list[str] | str] {
    sequences: list[str] = [];
    pos = 0;
    while pos < len(buffer) {
        remaining = buffer[pos:];
        if remaining.startswith(ESC) {
            seq_end = 1;
            while seq_end <= len(remaining) {
                candidate = remaining[0:seq_end];
                status = sequence_status(candidate);
                if status == "complete" {
                    sequences.append(candidate);
                    pos += seq_end;
                    break;
                } elif status == "incomplete" {
                    seq_end += 1;
                } else {
                    sequences.append(candidate);
                    pos += seq_end;
                    break;
                }
            }
            if seq_end > len(remaining) {
                return {"sequences": sequences, "remainder": remaining};
            }
        } else {
            sequences.append(remaining[0]);
            pos += 1;
        }
    }
    return {"sequences": sequences, "remainder": ""};
}


glob LEGACY_KEYS: dict[str, str] = {
    "\x1b[A": "up",
    "\x1bOA": "up",
    "\x1b[B": "down",
    "\x1bOB": "down",
    "\x1b[C": "right",
    "\x1bOC": "right",
    "\x1b[D": "left",
    "\x1bOD": "left",
    "\x1b[H": "home",
    "\x1bOH": "home",
    "\x1b[F": "end",
    "\x1bOF": "end",
    "\x1b[3~": "delete",
    "\x1b[2~": "insert",
    "\x1b[5~": "page_up",
    "\x1b[6~": "page_down",
    "\x1bOP": "f1",
    "\x1bOQ": "f2",
    "\x1bOR": "f3",
    "\x1bOS": "f4",
    "\x1b[15~": "f5",
    "\x1b[17~": "f6",
    "\x1b[18~": "f7",
    "\x1b[19~": "f8",
    "\x1b[20~": "f9",
    "\x1b[21~": "f10",
    "\x1b[23~": "f11",
    "\x1b[24~": "f12",
};


def _parse_sgr_mouse(seq: str) -> MouseEvent | None {
    m = re.match(r"^\x1b\[<(\d+);(\d+);(\d+)([Mm])$", seq);
    if m is None {
        return None;
    }
    button = int(m.group(1));
    x = int(m.group(2));
    y = int(m.group(3));
    pressed = m.group(4) == "M";
    motion = (button & 32) != 0;
    return MouseEvent(
        button=button & ~32,
        x=x,
        y=y,
        pressed=pressed,
        motion=motion,
    );
}


glob MODIFIER_NAMES: dict[int, str] = {
    2: "shift",
    3: "alt",
    4: "alt+shift",
    5: "ctrl",
    6: "ctrl+shift",
};


def _modified_key(modifier: int, base: str) -> str | None {
    prefix = MODIFIER_NAMES.get(modifier);
    if prefix is None {
        return None;
    }
    return prefix + "+" + base;
}


glob CSI_LETTER_KEYS: dict[str, str] = {
    "A": "up",
    "B": "down",
    "C": "right",
    "D": "left",
    "H": "home",
    "F": "end",
};


"""Decode modified CSI keys: ESC [ 1 ; <mod> <ABCDHF> and ESC [ <n> ; <mod> ~."""
def _parse_modified_csi(seq: str) -> KeyEvent | None {
    m = re.match(r"^\x1b\[1?;(\d+)([ABCDHF])$", seq);
    if m is not None {
        base = CSI_LETTER_KEYS[m.group(2)];
        key_name = _modified_key(int(m.group(1)), base);
        if key_name is not None {
            return KeyEvent(key=key_name);
        }
        return None;
    }
    t = re.match(r"^\x1b\[(\d+);(\d+)~$", seq);
    if t is not None {
        plain = "\x1b[" + t.group(1) + "~";
        if plain in LEGACY_KEYS {
            key_name = _modified_key(int(t.group(2)), LEGACY_KEYS[plain]);
            if key_name is not None {
                return KeyEvent(key=key_name);
            }
        }
    }
    return None;
}


def decode_sequence(seq: str) -> HostEvent {
    if not seq {
        return TextEvent(text="");
    }
    if seq in LEGACY_KEYS {
        return KeyEvent(key=LEGACY_KEYS[seq]);
    }
    mouse = _parse_sgr_mouse(seq);
    if mouse is not None {
        return mouse;
    }
    modified = _parse_modified_csi(seq);
    if modified is not None {
        return modified;
    }
    if seq == "\r" or seq == "\n" {
        return KeyEvent(key="enter");
    }
    if seq == "\t" {
        return KeyEvent(key="tab");
    }
    if seq == "\x1b[Z" {
        return KeyEvent(key="shift+tab");
    }
    if seq == "\x7f" or seq == "\b" {
        return KeyEvent(key="backspace");
    }
    if seq == "\x1b" {
        return KeyEvent(key="escape");
    }
    if seq == "\x03" {
        return KeyEvent(key="ctrl+c");
    }
    if seq == "\x04" {
        return KeyEvent(key="ctrl+d");
    }
    if seq == "\x01" {
        return KeyEvent(key="ctrl+a");
    }
    if seq == "\x05" {
        return KeyEvent(key="ctrl+e");
    }
    if seq == "\x15" {
        return KeyEvent(key="ctrl+u");
    }
    if seq == "\x0b" {
        return KeyEvent(key="ctrl+k");
    }
    if seq == "\x17" {
        return KeyEvent(key="ctrl+w");
    }
    # Alt+key often arrives as ESC + char.
    if len(seq) == 2 and seq[0] == ESC and seq[1] != "[" and seq[1] != "O" {
        return KeyEvent(key="alt+" + seq[1]);
    }
    if len(seq) == 1 and ord(seq[0]) >= 32 {
        return TextEvent(text=seq);
    }
    # Unrecognized escape: expose as key with raw identity for debugging.
    if seq.startswith(ESC) {
        return KeyEvent(key="unknown:" + repr(seq));
    }
    return TextEvent(text=seq);
}


obj EofEvent(HostEvent) {
    def init() {
        self.kind = "eof";
    }
}


obj InterruptEvent(HostEvent) {
    def init() {
        self.kind = "interrupt";
    }
}


"""Stateful stdin normalizer with paste mode and incomplete-escape buffering.

Lone ESC stays incomplete until a follow-up byte arrives or
`flush_esc_timeout(now_ms)` fires after `esc_timeout_ms` (default 50ms).
"""
obj InputNormalizer {
    has buffer: str = "",
        paste_mode: bool = False,
        paste_buffer: str = "",
        pending_resize: ResizeEvent | None = None,
        pending_mouse: MouseEvent | None = None,
        pending_stream: str = "",
        esc_timeout_ms: int = 50,
        esc_armed_at_ms: float = -1.0;

    def feed(data: str) -> list[HostEvent] {
        if not data and not self.buffer {
            return [];
        }
        out: list[HostEvent] = [];
        self.buffer += data;
        if self.paste_mode {
            self.paste_buffer += self.buffer;
            self.buffer = "";
            end_idx = (
                -1
                if BRACKETED_PASTE_END not in self.paste_buffer
                else self.paste_buffer.index(BRACKETED_PASTE_END)
            );
            if end_idx != -1 {
                pasted = self.paste_buffer[0:end_idx];
                remaining = self.paste_buffer[end_idx + len(BRACKETED_PASTE_END):];
                self.paste_mode = False;
                self.paste_buffer = "";
                out.append(PasteEvent(text=pasted));
                if remaining {
                    out.extend(self.feed(remaining));
                }
            }
            return out;
        }
        start_idx = (
            -1
            if BRACKETED_PASTE_START not in self.buffer
            else self.buffer.index(BRACKETED_PASTE_START)
        );
        if start_idx != -1 {
            if start_idx > 0 {
                before = self.buffer[0:start_idx];
                extracted = extract_sequences(before);
                for seq in extracted["sequences"] {
                    out.append(decode_sequence(str(seq)));
                }
            }
            self.buffer = self.buffer[start_idx + len(BRACKETED_PASTE_START):];
            self.paste_mode = True;
            self.paste_buffer = self.buffer;
            self.buffer = "";
            end_idx = (
                -1
                if BRACKETED_PASTE_END not in self.paste_buffer
                else self.paste_buffer.index(BRACKETED_PASTE_END)
            );
            if end_idx != -1 {
                pasted = self.paste_buffer[0:end_idx];
                remaining = self.paste_buffer[end_idx + len(BRACKETED_PASTE_END):];
                self.paste_mode = False;
                self.paste_buffer = "";
                out.append(PasteEvent(text=pasted));
                if remaining {
                    out.extend(self.feed(remaining));
                }
            }
            return out;
        }
        extracted = extract_sequences(self.buffer);
        self.buffer = str(extracted["remainder"]);
        for seq in extracted["sequences"] {
            event = decode_sequence(str(seq));
            if isinstance(event, MouseEvent) and event.motion {
                self.pending_mouse = event;
            } else {
                out.append(event);
            }
        }
        # Arm ESC timeout only while a lone ESC remains incomplete.
        if self.buffer == ESC {
            if self.esc_armed_at_ms < 0.0 {
                self.esc_armed_at_ms = 0.0;
            }
        } else {
            self.esc_armed_at_ms = -1.0;
        }
        return out;
    }

    """Arm lone-ESC timer with wall-clock ms (call after feed when buffer is ESC)."""
    def arm_esc(now_ms: float) {
        if self.buffer == ESC {
            self.esc_armed_at_ms = now_ms;
        }
    }

    """If lone ESC has been pending longer than esc_timeout_ms, emit escape."""
    def flush_esc_timeout(now_ms: float) -> list[HostEvent] {
        if self.buffer != ESC {
            return [];
        }
        if self.esc_armed_at_ms < 0.0 {
            return [];
        }
        if now_ms - self.esc_armed_at_ms < float(self.esc_timeout_ms) {
            return [];
        }
        self.buffer = "";
        self.esc_armed_at_ms = -1.0;
        return [KeyEvent(key="escape")];
    }

    """Record a resize; only the latest is emitted on flush_coalesced."""
    def feed_resize(width: int, height: int) {
        self.pending_resize = ResizeEvent(width=width, height=height);
    }

    """Accumulate a model/stream text chunk for later coalescing."""
    def feed_stream(text: str) {
        if text {
            self.pending_stream += text;
        }
    }

    """Flush an incomplete escape remainder as a literal sequence."""
    def flush_buffer() -> list[HostEvent] {
        out: list[HostEvent] = [];
        if self.buffer {
            out.append(decode_sequence(self.buffer));
            self.buffer = "";
        }
        self.esc_armed_at_ms = -1.0;
        if self.paste_mode and self.paste_buffer {
            # Incomplete paste: emit accumulated text as paste rather than lose it.
            out.append(PasteEvent(text=self.paste_buffer));
            self.paste_mode = False;
            self.paste_buffer = "";
        }
        return out;
    }

    """Emit coalesced resize / mouse-motion / stream events."""
    def flush_coalesced() -> list[HostEvent] {
        out: list[HostEvent] = [];
        if self.pending_resize is not None {
            out.append(self.pending_resize as HostEvent);
            self.pending_resize = None;
        }
        if self.pending_mouse is not None {
            out.append(self.pending_mouse as HostEvent);
            self.pending_mouse = None;
        }
        if self.pending_stream {
            out.append(StreamChunkEvent(text=self.pending_stream));
            self.pending_stream = "";
        }
        return out;
    }

    def clear() {
        self.buffer = "";
        self.paste_mode = False;
        self.paste_buffer = "";
        self.pending_resize = None;
        self.pending_mouse = None;
        self.pending_stream = "";
        self.esc_armed_at_ms = -1.0;
    }
}


"""Merge a list of already-produced events (resize/mouse/stream coalescing)."""
def coalesce_events(events: list[HostEvent]) -> list[HostEvent] {
    out: list[HostEvent] = [];
    last_resize: ResizeEvent | None = None;
    last_mouse: MouseEvent | None = None;
    stream_acc = "";
    for event in events {
        if isinstance(event, ResizeEvent) {
            last_resize = event;
            continue;
        }
        if isinstance(event, MouseEvent) and event.motion {
            last_mouse = event;
            continue;
        }
        if isinstance(event, StreamChunkEvent) {
            stream_acc += event.text;
            continue;
        }
        # Flush pending coalesced items before a non-coalescable event to
        # preserve relative order of interactive input.
        if last_resize is not None {
            out.append(last_resize as HostEvent);
            last_resize = None;
        }
        if last_mouse is not None {
            out.append(last_mouse as HostEvent);
            last_mouse = None;
        }
        if stream_acc {
            out.append(StreamChunkEvent(text=stream_acc));
            stream_acc = "";
        }
        out.append(event);
    }
    if last_resize is not None {
        out.append(last_resize as HostEvent);
    }
    if last_mouse is not None {
        out.append(last_mouse as HostEvent);
    }
    if stream_acc {
        out.append(StreamChunkEvent(text=stream_acc));
    }
    return out;
}
