import from ..keybindings { getKeybindings }
import from ..input_support { AbortController }
import from .loader { Loader }

obj:pub CancellableLoader(Loader) {
    has abortController: any = AbortController();
    has onAbort: any | None = None;
    def __init__(ui: any, spinnerColorFn: any, messageColorFn: any, message: str = "Loading...", indicator: any | None = None) -> None {
        # NOTE(port): this Jac runtime cannot lower a zero-arg super() call
        # across multiple inheritance levels, so call the base Loader
        # constructor directly by class name instead.
        Loader.__init__(self, ui, spinnerColorFn, messageColorFn, message, indicator);
        self.abortController = AbortController();
        self.onAbort = None;
    }
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
