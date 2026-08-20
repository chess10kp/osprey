import from .text { Text }
import from ..terminal_support { set_interval, clear_interval }

glob DEFAULT_FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

glob DEFAULT_INTERVAL_MS = 80;

obj:pub Loader(Text) {
    has spinnerColorFn: any = None;
    has messageColorFn: any = None;
    has frames: list = [*DEFAULT_FRAMES];
    has intervalMs: any = DEFAULT_INTERVAL_MS;
    has currentFrame: int = 0;
    has intervalId: any | None = None;
    has ui: any | None = None;
    has renderIndicatorVerbatim: bool = False;
    has message: str = "Loading...";
    def __init__(ui: any, spinnerColorFn: any, messageColorFn: any, message: str = "Loading...", indicator: any | None = None) -> None {
        # NOTE(port): this Jac runtime cannot lower a `super(args)` call across
        # multiple inheritance levels (CancellableLoader -> Loader -> Text), so
        # seed the inherited Text state directly rather than via super().
        self.text = "";
        self.paddingX = 1;
        self.paddingY = 0;
        self.customBgFn = None;
        self.cachedText = None;
        self.cachedWidth = None;
        self.cachedLines = None;
        # NOTE(port): a custom __init__ suppresses Jac's auto-application of
        # `has` field defaults, so the defaulted fields must be set explicitly.
        self.frames = [*DEFAULT_FRAMES];
        self.intervalMs = DEFAULT_INTERVAL_MS;
        self.currentFrame = 0;
        self.intervalId = None;
        self.renderIndicatorVerbatim = False;
        self.ui = ui;
        self.spinnerColorFn = spinnerColorFn;
        self.messageColorFn = messageColorFn;
        self.message = message;
        self.setIndicator(indicator);
    }
    override def render(width: float) -> list[str] {
        # NOTE(port): zero-arg super() cannot be lowered here either (same
        # multi-level-inheritance limitation as __init__ above); call the
        # base implementation directly instead.
        return ["", *Text.render(self, width)];
    }
    override def start() -> None {
        self.updateDisplay();
        self.restartAnimation();
    }
    override def stop() -> None {
        if self.intervalId {
            clear_interval(self.intervalId);
            self.intervalId = None;
        }
    }
    override def setMessage(message: str) -> None {
        self.message = message;
        self.updateDisplay();
    }
    override def setIndicator(indicator: any | None = None) -> None {
        self.renderIndicatorVerbatim = (indicator != None);
        indicatorFrames = (indicator.frames if indicator is not None else None);
        self.frames = ([*indicatorFrames] if (indicatorFrames != None) else [*DEFAULT_FRAMES]);
        indicatorInterval = (indicator.intervalMs if indicator is not None else None);
        self.intervalMs = (indicatorInterval if ((indicatorInterval != None) and (indicatorInterval > 0)) else DEFAULT_INTERVAL_MS);
        self.currentFrame = 0;
        self.start();
    }
    override def restartAnimation() -> None {
        self.stop();
        if (len(self.frames) <= 1) {
            return;
        }
        self.intervalId = set_interval(lambda () -> any { self.currentFrame = ((self.currentFrame + 1) % len(self.frames)); self.updateDisplay(); }, self.intervalMs);
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
