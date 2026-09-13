"""Void lambdas with statement-call bodies must terminate with `ret void`.

Regression: a `-> None` lambda whose single statement is a method call got a
`ret i64 0` terminator -- the statement-call's non-None placeholder value was
coerced into the void return -- and LLVM verification rejected the whole
module with E5020 (value doesn't match function result type 'void'). This
blocked any module that carries a `-> None` lambda over a statement body,
such as a callable-field handler `on_event=lambda (x: int) -> None { ... }`.
"""
obj Probe {
    has on_event: any = None;

    def fire(x: int) {
        if self.on_event is not None {
            self.on_event(x);
        }
    }
}

with entry {
    seen: list[int] = [];
    p = Probe();
    p.on_event = lambda (x: int) -> None { seen.append(x); };
    p.fire(7);
    print(len(seen));
}
