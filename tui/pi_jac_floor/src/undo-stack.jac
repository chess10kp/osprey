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
    def length() -> float {
        return len(self.stack);
    }
}
