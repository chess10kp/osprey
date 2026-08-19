import from "../keybindings.jac" { getKeybindings }
import from "./loader.jac" { Loader }

obj:pub CancellableLoader(Loader) {
    has onAbort: any | None = None;
    has stop: any = None;
    has abortController: any = AbortController();
    # JS2JAC-HOLE[E7205] Class getters/setters are not supported:
    # | get signal(): AbortSignal {
    # | 		return this.abortController.signal;
    # | 	}
    # JS2JAC-HOLE[E7205] Class getters/setters are not supported:
    # | get aborted(): boolean {
    # | 		return this.abortController.signal.aborted;
    # | 	}
    override def handleInput(data: str) -> None {
        kb = getKeybindings();
        if kb.matches(data, "tui.select.cancel") {
            self.abortController.abort();
            (self.onAbort() if self.onAbort is not None else None);
        }
    }
    override def dispose() -> None {
        self.stop();
    }
}
