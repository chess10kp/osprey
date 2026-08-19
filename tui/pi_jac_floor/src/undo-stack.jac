obj:pub UndoStack {
    has stack: list[any] = [];
    def push(state: any) -> None {
        self.stack.append(structuredClone(state));
    }
    def pop() -> any | None {
        return self.stack.pop();
    }
    def clear() -> None {
        len(self.stack) = 0;
    }
    # JS2JAC-HOLE[E7205] Class getters/setters are not supported:
    # | get length(): number {
    # | 		return this.stack.length;
    # | 	}
}
