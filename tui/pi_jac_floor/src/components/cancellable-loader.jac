import from "../keybindings.jac" { getKeybindings }
import from "./loader.jac" { Loader }

obj:pub CancellableLoader(Loader) {
    has onAbort: any | None = None;
    has stop: any = None;
    has abortController: any = AbortController();
    override def signal() -> any {
        return self.abortController.signal;
    }
    override def aborted() -> bool {
        return self.abortController.signal.aborted;
    }
    override def handleInput(data: str) -> None {
        kb = getKeybindings();
        if kb.matches(data, "tui.select.cancel") {
            self.abortController.abort();
            ((lambda (_jx_opt0: any) -> any { return (_jx_opt0() if _jx_opt0 is not None else None); })(self.onAbort));
        }
    }
    override def dispose() -> None {
        self.stop();
    }
}
