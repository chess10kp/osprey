obj:pub KillRing {
    has ring: list[str] = [];
    def push(text: str, opts: dict[str, bool | bool | None]) -> None {
        if not text {
            return;
        }
        if (opts.accumulate and (len(self.ring) > 0)) {
            last = (self.ring.pop() as any);
            self.ring.append(((text + last) if opts.prepend else (last + text)));
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
            self.ring.unshift(last);
        }
    }
    # JS2JAC-HOLE[E7205] Class getters/setters are not supported:
    # | get length(): number {
    # | 		return this.ring.length;
    # | 	}
}
