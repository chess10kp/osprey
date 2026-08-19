import from "./text.jac" { Text }

glob DEFAULT_FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

glob DEFAULT_INTERVAL_MS = 80;

obj:pub Loader(Text) {
    has spinnerColorFn: any;
    has messageColorFn: any;
    has setText: any = None;
    has frames: list = [*DEFAULT_FRAMES];
    has intervalMs: any = DEFAULT_INTERVAL_MS;
    has currentFrame: int = 0;
    has intervalId: any | None = None;
    has ui: any | None = None;
    has renderIndicatorVerbatim: bool = False;
    has message: str = "Loading...";
    def __init__(ui: any, spinnerColorFn: any, messageColorFn: any, message: str = "Loading...", indicator: any | None = None) -> None {
        super("", 1, 0);
        self.ui = ui;
        self.spinnerColorFn = spinnerColorFn;
        self.messageColorFn = messageColorFn;
        self.message = message;
        self.setIndicator(indicator);
    }
    override def render(width: float) -> list[str] {
        return ["", *super().render(width)];
    }
    override def start() -> None {
        self.updateDisplay();
        self.restartAnimation();
    }
    override def stop() -> None {
        if self.intervalId {
            clearInterval(self.intervalId);
            self.intervalId = None;
        }
    }
    override def setMessage(message: str) -> None {
        self.message = message;
        self.updateDisplay();
    }
    override def setIndicator(indicator: any | None = None) -> None {
        self.renderIndicatorVerbatim = (indicator != None);
        self.frames = ([*indicator.frames] if (((lambda (_jx_opt0: any) -> any { return (_jx_opt0.frames if _jx_opt0 is not None else None); })(indicator)) != None) else [*DEFAULT_FRAMES]);
        self.intervalMs = (indicator.intervalMs if (((lambda (_jx_opt1: any) -> any { return (_jx_opt1.intervalMs if _jx_opt1 is not None else None); })(indicator)) and (indicator.intervalMs > 0)) else DEFAULT_INTERVAL_MS);
        self.currentFrame = 0;
        self.start();
    }
    override def restartAnimation() -> None {
        self.stop();
        if (len(self.frames) <= 1) {
            return;
        }
        self.intervalId = setInterval(lambda () -> any { self.currentFrame = ((self.currentFrame + 1) % len(self.frames)); self.updateDisplay(); }, self.intervalMs);
    }
    override def updateDisplay() -> None {
        frame = ((lambda (_jx_null2: any) -> any { return (_jx_null2 if _jx_null2 is not None else ""); })(self.frames[self.currentFrame]));
        renderedFrame = (frame if self.renderIndicatorVerbatim else self.spinnerColorFn(frame));
        indicator = (f"{renderedFrame} " if (len(frame) > 0) else "");
        self.setText(f"{indicator}{self.messageColorFn(self.message)}");
        if self.ui {
            self.ui.requestRender();
        }
    }
}
