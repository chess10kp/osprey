obj:pub KillRing {
    has ring: list[str] = [];
    def push(text: str, opts: dict[str, bool | bool | None]) -> None {
        if not text {
            return;
        }
        if (opts["accumulate"] and (len(self.ring) > 0)) {
            last: str = self.ring.pop();
            self.ring.append(((text + last) if opts["prepend"] else (last + text)));
        }
        else {
            self.ring.append(text);
        }
    }
    def peek() -> str | None {
        return (self.ring[(len(self.ring) - 1)] if (len(self.ring) > 0) else None);
    }
    def rotate() -> None {
        if (len(self.ring) > 1) {
            last = (self.ring.pop() as any);
            self.ring.insert(0, last);
        }
    }
    def length() -> float {
        return len(self.ring);
    }
}
