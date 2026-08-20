import from copy { deepcopy }

obj:pub UndoStack {
    has stack: list[any] = [];
    def push(state: any) -> None {
        self.stack.append(deepcopy(state));
    }
    def pop() -> any | None {
        return self.stack.pop();
    }
    def clear() -> None {
        self.stack.clear();
    }
    def length() -> float {
        return len(self.stack);
    }
}
