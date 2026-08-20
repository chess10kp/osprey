import from .keys { isKeyRelease, matchesKey }
import from .terminal_colors { isOsc11BackgroundColorResponse, parseOsc11BackgroundColor, parseTerminalColorSchemeReport }
import from .terminal_image { deleteKittyImage, getCapabilities, isImageLine, setCellDimensions }
import from .utils { extractSegments, normalizeTerminalOutput, sliceByColumn, sliceWithWidth, visibleWidth }
import from .terminal_support { process, fs, path, Number, DateValue, now_ms }
import from .input_support { set_timeout, clear_timeout, Promise, SimplePromise }
import from re { search }
import from os { environ }
import os;
import datetime;
import json;

# Generic JS Array.prototype.find() replacement: first item matching pred, or None.
def _find(items: list, pred: any) -> any | None {
    for item in items {
        if pred(item) {
            return item;
        }
    }
    return None;
}

def _is_integer(n: any) -> bool {
    if isinstance(n, bool) {
        return False;
    }
    if isinstance(n, int) {
        return True;
    }
    if isinstance(n, float) {
        return n.is_integer();
    }
    return False;
}

glob KITTY_SEQUENCE_PREFIX = "\u001b_G";

def parseKittyImageHeader(line: str) -> any | None {
    sequenceStart = (-1 if KITTY_SEQUENCE_PREFIX not in line else line.index(KITTY_SEQUENCE_PREFIX));
    if (sequenceStart == -1) {
        return None;
    }
    paramsStart = (sequenceStart + len(KITTY_SEQUENCE_PREFIX));
    paramsEnd = line.find(";", paramsStart);
    if (paramsEnd == -1) {
        return None;
    }
    ids: list[float] = [];
    rows = 1;
    params = line[paramsStart:paramsEnd];
    for param in params.split(",") {
        _jx_d0: any = param.split("=", 2);
        key = _jx_d0[0];
        value = (_jx_d0[1] if len(_jx_d0) > 1 else None);
        if (value == None) {
            continue;
        }
        numberValue = Number(value);
        if ((not _is_integer(numberValue) or (numberValue <= 0)) or (numberValue > 4294967295)) {
            continue;
        }
        if (key == "i") {
            ids.append(float(numberValue));
        }
        elif (key == "r") {
            rows = int(numberValue);
        }
    }
    return {"ids": ids, "rows": rows};
}

def extractKittyImageIds(line: str) -> list[float] {
    header = parseKittyImageHeader(line);
    return (header["ids"] if header is not None else []);
}

def extractKittyImageRows(line: str) -> float {
    header = parseKittyImageHeader(line);
    return (header["rows"] if header is not None else 1);
}

def:pub isFocusable(component: any | None) -> bool {
    if component is None {
        return False;
    }
    if isinstance(component, dict) {
        return "focused" in component;
    }
    return hasattr(component, "focused");
}

glob:pub CURSOR_MARKER = "\u001b_pi:c\u0007";

def parseSizeValue(value: any | None, referenceSize: float) -> float | None {
    if (value == None) {
        return None;
    }
    if isinstance(value, (int, float)) {
        return value;
    }
    match_j = search(r"^(\d+(?:\.\d+)?)%$", value);
    if match_j {
        return int((((referenceSize * float(match_j.group(1))) / 100)) // 1);
    }
    return None;
}

def isTermuxSession() -> bool {
    return bool(environ.get("TERMUX_VERSION"));
}

obj:pub Container {
    has children: list[any] = [];
    def addChild(component: any) -> None {
        self.children.append(component);
    }
    def removeChild(component: any) -> None {
        index = (-1 if component not in self.children else self.children.index(component));
        if (index != -1) {
            del self.children[index];
        }
    }
    def clear() -> None {
        self.children = [];
    }
    def invalidate() -> None {
        for child in self.children {
            ((lambda (_jx_opt4: any) -> any { return (_jx_opt4() if _jx_opt4 is not None else None); })(child.invalidate));
        }
    }
    def render(width: float) -> list[str] {
        lines: list[str] = [];
        for child in self.children {
            childLines = child.render(width);
            for line in childLines {
                lines.append(line);
            }
        }
        return lines;
    }
}

glob:pub MIN_RENDER_INTERVAL_MS = 16;
glob:pub SEGMENT_RESET = "\u001b[0m\u001b]8;;\u0007";

# Overlay-stack entry (was an ad-hoc JS object literal). A real obj so dotted
# attribute access works under the Jac runtime (plain dicts do not support it).
obj OverlayEntry {
    has component: any = None;
    has options: any = None;
    has preFocus: any = None;
    has hidden: bool = False;
    has focusOrder: int = 0;
}

# Resume descriptor nested inside FocusRestoreState.resume.
obj FocusResume {
    has status: str = "";
    has target: any = None;
}

# Tracks how focus should be restored once a blocking/overlay-owning
# component loses focus. status is one of "inactive" | "eligible" | "blocked".
obj FocusRestoreState {
    has status: str = "inactive";
    has overlay: any = None;
    has blockedBy: any = None;
    has resume: any = None;
}

# Pending OSC 11 / color-scheme query bookkeeping (was an ad-hoc object literal).
obj OscQuery {
    has settled: bool = False;
    has resolve: any = None;
    has timer: any = None;
}

obj:pub TUI(Container) {
    has terminal: any = None;
    has renderTimer: any | None = None;
    has children: any = None;
    has previousLines: list[str] = [];
    has previousKittyImageIds: any = set();
    has previousWidth: float = 0;
    has previousHeight: float = 0;
    has focusedComponent: any | None = None;
    has inputListeners: any = set();
    has onDebug: any | None = None;
    has renderRequested: bool = False;
    has lastRenderAt: int = 0;
    has cursorRow: float = 0;
    has hardwareCursorRow: float = 0;
    has showHardwareCursor: any = (environ.get("PI_HARDWARE_CURSOR") == "1");
    has clearOnShrink: any = (environ.get("PI_CLEAR_ON_SHRINK") == "1");
    has maxLinesRendered: float = 0;
    has previousViewportTop: float = 0;
    has fullRedrawCount: int = 0;
    has stopped: bool = False;
    has pendingOsc11BackgroundReplies: int = 0;
    has pendingOsc11BackgroundQueries: list[any] = [];
    has terminalColorSchemeListeners: any = set();
    has terminalColorSchemeNotificationsEnabled: bool = False;
    has focusOrderCounter: int = 0;
    has overlayStack: list[any] = [];
    has overlayFocusRestore: any = FocusRestoreState();
    def __init__(terminal: any, showHardwareCursor: bool | None = None) -> None {
        # A custom __init__ suppresses automatic `has`-default application,
        # so every field this obj declares must be seeded here explicitly.
        self.terminal = terminal;
        self.renderTimer = None;
        self.children = [];
        self.previousLines = [];
        self.previousKittyImageIds = set();
        self.previousWidth = 0;
        self.previousHeight = 0;
        self.focusedComponent = None;
        self.inputListeners = set();
        self.onDebug = None;
        self.renderRequested = False;
        self.lastRenderAt = 0;
        self.cursorRow = 0;
        self.hardwareCursorRow = 0;
        self.showHardwareCursor = (environ.get("PI_HARDWARE_CURSOR") == "1");
        self.clearOnShrink = (environ.get("PI_CLEAR_ON_SHRINK") == "1");
        self.maxLinesRendered = 0;
        self.previousViewportTop = 0;
        self.fullRedrawCount = 0;
        self.stopped = False;
        self.pendingOsc11BackgroundReplies = 0;
        self.pendingOsc11BackgroundQueries = [];
        self.terminalColorSchemeListeners = set();
        self.terminalColorSchemeNotificationsEnabled = False;
        self.focusOrderCounter = 0;
        self.overlayStack = [];
        self.overlayFocusRestore = FocusRestoreState();
        if (showHardwareCursor != None) {
            self.showHardwareCursor = showHardwareCursor;
        }
    }
    override def fullRedraws() -> float {
        return self.fullRedrawCount;
    }
    override def getShowHardwareCursor() -> bool {
        return self.showHardwareCursor;
    }
    override def setShowHardwareCursor(enabled: bool) -> None {
        if (self.showHardwareCursor == enabled) {
            return;
        }
        self.showHardwareCursor = enabled;
        if not enabled {
            self.terminal.hideCursor();
        }
        self.requestRender();
    }
    override def getClearOnShrink() -> bool {
        return self.clearOnShrink;
    }
    override def setClearOnShrink(enabled: bool) -> None {
        self.clearOnShrink = enabled;
    }
    override def setFocus(component: any | None) -> None {
        self.setFocusInternal(component, "clear");
    }
    override def setFocusInternal(component: any | None, overlayFocusRestore: str = "preserve") -> None {
        previousFocus = self.focusedComponent;
        nextFocus = component;
        previousFocusedOverlay = (_find(self.overlayStack, lambda (entry_j: any) -> any { return ((entry_j.component == previousFocus) and self.isOverlayVisible(entry_j)); }) if previousFocus else None);
        nextFocusIsOverlay = (any((entry_j.component == nextFocus) for entry_j in self.overlayStack) if nextFocus else False);
        restoreState = self.getVisibleOverlayFocusRestore();
        if (nextFocus and not nextFocusIsOverlay) {
            if ((restoreState.status == "blocked") and (restoreState.blockedBy == previousFocus)) {
                if ((restoreState.resume.status == "focus-target") or not self.isComponentMounted(restoreState.blockedBy)) {
                    nextFocus = self.resolveBlockedOverlayFocusResume(restoreState);
                }
                else {
                    self.overlayFocusRestore = FocusRestoreState(status="blocked", overlay=restoreState.overlay, blockedBy=nextFocus, resume=restoreState.resume);
                }
            }
            elif (((previousFocusedOverlay and (restoreState.status != "inactive")) and (restoreState.overlay == previousFocusedOverlay)) and not self.isOverlayFocusAncestor(previousFocusedOverlay, nextFocus)) {
                self.overlayFocusRestore = FocusRestoreState(status="blocked", overlay=previousFocusedOverlay, blockedBy=nextFocus, resume=FocusResume(status="restore-overlay"));
            }
        }
        elif (nextFocus == None) {
            if ((restoreState.status == "blocked") and (restoreState.blockedBy == previousFocus)) {
                nextFocus = self.resolveBlockedOverlayFocusResume(restoreState);
            }
            elif (overlayFocusRestore == "clear") {
                self.clearOverlayFocusRestore();
            }
        }
        if isFocusable(self.focusedComponent) {
            (self.focusedComponent as any).focused = False;
        }
        self.focusedComponent = nextFocus;
        if isFocusable(nextFocus) {
            (nextFocus as any).focused = True;
        }
        focusedOverlay = (_find(self.overlayStack, lambda (entry_j: any) -> any { return ((entry_j.component == nextFocus) and self.isOverlayVisible(entry_j)); }) if nextFocus else None);
        if focusedOverlay {
            self.overlayFocusRestore = FocusRestoreState(status="eligible", overlay=focusedOverlay);
        }
    }
    override def clearOverlayFocusRestore() -> None {
        self.overlayFocusRestore = FocusRestoreState(status="inactive");
    }
    override def clearOverlayFocusRestoreFor(overlay: any) -> None {
        if ((self.overlayFocusRestore.status != "inactive") and (self.overlayFocusRestore.overlay == overlay)) {
            self.clearOverlayFocusRestore();
        }
    }
    override def resolveBlockedOverlayFocusResume(restoreState: any) -> any | None {
        if (restoreState.resume.status == "restore-overlay") {
            return restoreState.overlay.component;
        }
        self.clearOverlayFocusRestore();
        return restoreState.resume.target;
    }
    override def getVisibleOverlayFocusRestore() -> any {
        restoreState = self.overlayFocusRestore;
        if (restoreState.status == "inactive") {
            return restoreState;
        }
        if (not (restoreState.overlay in self.overlayStack) or not self.isOverlayVisible(restoreState.overlay)) {
            return FocusRestoreState(status="inactive");
        }
        return restoreState;
    }
    override def isOverlayFocusAncestor(entry_j: any, component: any) -> bool {
        visited = set();
        current = entry_j.preFocus;
        while (current and (current not in visited)) {
            visited.add(current);
            if (current == component) {
                return True;
            }
            found = _find(self.overlayStack, lambda (overlay: any) -> any { return (overlay.component == current); });
            current = (found.preFocus if found is not None else None);
        }
        return False;
    }
    override def retargetOverlayPreFocus(removed: any) -> None {
        for overlay in self.overlayStack {
            if ((overlay != removed) and (overlay.preFocus == removed.component)) {
                overlay.preFocus = removed.preFocus;
            }
        }
    }
    override def isComponentMounted(component: any) -> bool {
        return any(self.containsComponent(child, component) for child in self.children);
    }
    override def containsComponent(root_j: any, target: any) -> bool {
        if (root_j == target) {
            return True;
        }
        if not isinstance(root_j, Container) {
            return False;
        }
        return any(self.containsComponent(child, target) for child in root_j.children);
    }
    override def nextFocusOrder() -> int {
        self.focusOrderCounter += 1;
        return self.focusOrderCounter;
    }
    override def showOverlay(component: any, options: any | None = None) -> any {
        entry_j: OverlayEntry = OverlayEntry(component=component, options=options, preFocus=self.focusedComponent, hidden=False, focusOrder=self.nextFocusOrder());
        self.overlayStack.append(entry_j);
        if (not (options is not None and options.get("nonCapturing")) and self.isOverlayVisible(entry_j)) {
            self.setFocus(component);
        }
        self.terminal.hideCursor();
        self.requestRender();
        def _hide() -> None {
            index = (-1 if entry_j not in self.overlayStack else self.overlayStack.index(entry_j));
            if (index != -1) {
                self.clearOverlayFocusRestoreFor(entry_j);
                self.retargetOverlayPreFocus(entry_j);
                del self.overlayStack[index];
                if (self.focusedComponent == component) {
                    topVisible = self.getTopmostVisibleOverlay();
                    self.setFocus(topVisible.component if topVisible is not None else entry_j.preFocus);
                }
                if (len(self.overlayStack) == 0) {
                    self.terminal.hideCursor();
                }
                self.requestRender();
            }
        }
        def _setHidden(hidden: bool) -> None {
            if (entry_j.hidden == hidden) {
                return;
            }
            entry_j.hidden = hidden;
            if hidden {
                self.clearOverlayFocusRestoreFor(entry_j);
                if (self.focusedComponent == component) {
                    topVisible = self.getTopmostVisibleOverlay();
                    self.setFocus(topVisible.component if topVisible is not None else entry_j.preFocus);
                }
            } else {
                if (not (options is not None and options.get("nonCapturing")) and self.isOverlayVisible(entry_j)) {
                    entry_j.focusOrder = self.nextFocusOrder();
                    self.setFocus(component);
                }
            }
            self.requestRender();
        }
        def _isHidden() -> bool {
            return entry_j.hidden;
        }
        def _focus() -> None {
            if (not (entry_j in self.overlayStack) or not self.isOverlayVisible(entry_j)) {
                return;
            }
            entry_j.focusOrder = self.nextFocusOrder();
            self.setFocus(component);
            self.requestRender();
        }
        def _unfocus(unfocusOptions: any = None) -> None {
            isFocused = (self.focusedComponent == component);
            restoreState = self.overlayFocusRestore;
            hasPendingRestore = ((restoreState.status != "inactive") and (restoreState.overlay == entry_j));
            if (not isFocused and not hasPendingRestore) {
                return;
            }
            if (((restoreState.status == "blocked") and (restoreState.overlay == entry_j)) and (self.focusedComponent == restoreState.blockedBy)) {
                if unfocusOptions {
                    self.overlayFocusRestore = FocusRestoreState(status="blocked", overlay=entry_j, blockedBy=restoreState.blockedBy, resume=FocusResume(status="focus-target", target=unfocusOptions.get("target")));
                } else {
                    self.clearOverlayFocusRestore();
                }
                self.requestRender();
                return;
            }
            self.clearOverlayFocusRestoreFor(entry_j);
            if (isFocused or unfocusOptions) {
                topVisible = self.getTopmostVisibleOverlay();
                fallbackTarget = (topVisible.component if (topVisible and (topVisible != entry_j)) else entry_j.preFocus);
                self.setFocus(unfocusOptions.get("target") if unfocusOptions else fallbackTarget);
            }
            self.requestRender();
        }
        def _isFocused() -> bool {
            return self.focusedComponent == component;
        }
        return {"hide": _hide, "setHidden": _setHidden, "isHidden": _isHidden, "focus": _focus, "unfocus": _unfocus, "isFocused": _isFocused};
    }
    override def hideOverlay() -> None {
        if (len(self.overlayStack) == 0) {
            return;
        }
        overlay = self.overlayStack[(len(self.overlayStack) - 1)];
        self.clearOverlayFocusRestoreFor(overlay);
        self.retargetOverlayPreFocus(overlay);
        self.overlayStack.pop();
        if (self.focusedComponent == overlay.component) {
            topVisible = self.getTopmostVisibleOverlay();
            self.setFocus(topVisible.component if topVisible is not None else overlay.preFocus);
        }
        if (len(self.overlayStack) == 0) {
            self.terminal.hideCursor();
        }
        self.requestRender();
    }
    override def hasOverlay() -> bool {
        return any(self.isOverlayVisible(o) for o in self.overlayStack);
    }
    override def isOverlayVisible(entry_j: any) -> bool {
        if entry_j.hidden {
            return False;
        }
        if (entry_j.options is not None and entry_j.options.get("visible") is not None) {
            return entry_j.options.get("visible")(self.terminal.columns(), self.terminal.rows());
        }
        return True;
    }
    override def getTopmostVisibleOverlay() -> any | None {
        topmost: any | None = None;
        for overlay in self.overlayStack {
            if ((overlay.options is not None and overlay.options.get("nonCapturing")) or not self.isOverlayVisible(overlay)) {
                continue;
            }
            if (not topmost or (overlay.focusOrder > topmost.focusOrder)) {
                topmost = overlay;
            }
        }
        return topmost;
    }
    override def invalidate() -> None {
        Container.invalidate(self);
        for overlay in self.overlayStack {
            if (hasattr(overlay.component, "invalidate") and overlay.component.invalidate is not None) {
                overlay.component.invalidate();
            }
        }
    }
    override def start() -> None {
        self.stopped = False;
        self.terminal.start(lambda (data: any) -> any { return self.handleInput(data); }, lambda () -> any { return self.requestRender(); });
        self.terminal.hideCursor();
        if self.terminalColorSchemeNotificationsEnabled {
            self.terminal.write("\u001b[?2031h");
        }
        self.queryCellSize();
        self.requestRender();
    }
    override def addInputListener(listener: any) -> any {
        self.inputListeners.add(listener);
        return lambda () -> any { self.inputListeners.discard(listener); };
    }
    override def removeInputListener(listener: any) -> None {
        self.inputListeners.discard(listener);
    }
    override def onTerminalColorSchemeChange(listener: any) -> any {
        self.terminalColorSchemeListeners.add(listener);
        return lambda () -> any { self.terminalColorSchemeListeners.discard(listener); };
    }
    override def setTerminalColorSchemeNotifications(enabled: bool) -> None {
        if (self.terminalColorSchemeNotificationsEnabled == enabled) {
            return;
        }
        self.terminalColorSchemeNotificationsEnabled = enabled;
        if not self.stopped {
            self.terminal.write(("\u001b[?2031h" if enabled else "\u001b[?2031l"));
        }
    }
    override def queryCellSize() -> None {
        if not getCapabilities().get("images") {
            return;
        }
        self.terminal.write("\u001b[16t");
    }
    override def stop() -> None {
        self.stopped = True;
        if self.renderTimer {
            clear_timeout(self.renderTimer);
            self.renderTimer = None;
        }
        if self.terminalColorSchemeNotificationsEnabled {
            self.terminal.write("\u001b[?2031l");
        }
        if (len(self.previousLines) > 0) {
            targetRow = len(self.previousLines);
            lineDiff = (targetRow - self.hardwareCursorRow);
            if (lineDiff > 0) {
                self.terminal.write(f"\x1b[{lineDiff}B");
            }
            elif (lineDiff < 0) {
                self.terminal.write(f"\x1b[{-lineDiff}A");
            }
            self.terminal.write("\r\n");
        }
        self.terminal.showCursor();
        self.terminal.stop();
    }
    override def requestRender(force: bool = False) -> None {
        if force {
            self.previousLines = [];
            self.previousWidth = -1;
            self.previousHeight = -1;
            self.cursorRow = 0;
            self.hardwareCursorRow = 0;
            self.maxLinesRendered = 0;
            self.previousViewportTop = 0;
            if self.renderTimer {
                clear_timeout(self.renderTimer);
                self.renderTimer = None;
            }
            self.renderRequested = True;
            self._onNextTickFullRender();
            return;
        }
        if self.renderRequested {
            return;
        }
        self.renderRequested = True;
        self.scheduleRender();
    }
    override def _onNextTickFullRender() -> None {
        if (self.stopped or not self.renderRequested) {
            return;
        }
        self.renderRequested = False;
        self.lastRenderAt = int(now_ms());
        self.doRender();
    }
    override def scheduleRender() -> None {
        if ((self.stopped or self.renderTimer) or not self.renderRequested) {
            return;
        }
        elapsed = (now_ms() - self.lastRenderAt);
        delay = max(float(0), float((MIN_RENDER_INTERVAL_MS - elapsed)));
        def _fire() -> None {
            self.renderTimer = None;
            if (self.stopped or not self.renderRequested) {
                return;
            }
            self.renderRequested = False;
            self.lastRenderAt = int(now_ms());
            self.doRender();
            if self.renderRequested {
                self.scheduleRender();
            }
        }
        self.renderTimer = set_timeout(_fire, delay);
    }
    override def handleInput(data: str) -> None {
        if self.consumeOsc11BackgroundResponse(data) {
            return;
        }
        if self.consumeTerminalColorSchemeReport(data) {
            return;
        }
        if (len(self.inputListeners) > 0) {
            current = data;
            for listener in self.inputListeners {
                result = listener(current);
                if (isinstance(result, dict) and result.get("consume")) {
                    return;
                }
                if (isinstance(result, dict) and (result.get("data") is not None)) {
                    current = (result.get("data") as str);
                }
            }
            if (len(current) == 0) {
                return;
            }
            data = current;
        }
        if self.consumeCellSizeResponse(data) {
            return;
        }
        if (matchesKey(data, "shift+ctrl+d") and self.onDebug) {
            self.onDebug();
            return;
        }
        focusedOverlay = _find(self.overlayStack, lambda (o: any) -> any { return (o.component == self.focusedComponent); });
        if (focusedOverlay and not self.isOverlayVisible(focusedOverlay)) {
            topVisible = self.getTopmostVisibleOverlay();
            if topVisible {
                self.setFocus(topVisible.component);
            }
            else {
                self.setFocusInternal(focusedOverlay.preFocus, "preserve");
            }
        }
        focusIsOverlay = any((o.component == self.focusedComponent) for o in self.overlayStack);
        if not focusIsOverlay {
            restoreState = self.getVisibleOverlayFocusRestore();
            if (restoreState.status == "eligible") {
                self.setFocus(restoreState.overlay.component);
            }
            elif ((restoreState.status == "blocked") and (restoreState.blockedBy != self.focusedComponent)) {
                if (restoreState.resume.status == "restore-overlay") {
                    self.setFocus(restoreState.overlay.component);
                }
                else {
                    self.clearOverlayFocusRestore();
                    self.setFocus(restoreState.resume.target);
                }
            }
        }
        if (self.focusedComponent is not None and hasattr(self.focusedComponent, "handleInput") and self.focusedComponent.handleInput is not None) {
            if (isKeyRelease(data) and not self.focusedComponent.wantsKeyRelease) {
                return;
            }
            self.focusedComponent.handleInput(data);
            self.requestRender();
        }
    }
    override def consumeOsc11BackgroundResponse(data: str) -> bool {
        if (self.pendingOsc11BackgroundReplies <= 0) {
            return False;
        }
        if not isOsc11BackgroundColorResponse(data) {
            return False;
        }
        rgb = parseOsc11BackgroundColor(data);
        self.pendingOsc11BackgroundReplies -= 1;
        query = self.pendingOsc11BackgroundQueries.pop(0);
        if (query and not query.settled) {
            query.settled = True;
            if query.timer {
                clear_timeout(query.timer);
                query.timer = None;
            }
            if query.resolve is not None {
                query.resolve(rgb);
            }
            query.resolve = None;
        }
        return True;
    }
    override def consumeTerminalColorSchemeReport(data: str) -> bool {
        scheme = parseTerminalColorSchemeReport(data);
        if not scheme {
            return False;
        }
        for listener in self.terminalColorSchemeListeners {
            listener(scheme);
        }
        return True;
    }
    override def consumeCellSizeResponse(data: str) -> bool {
        match_j = search(r"^\x1b\[6;(\d+);(\d+)t$", data);
        if not match_j {
            return False;
        }
        heightPx = int(match_j.group(1), 10);
        widthPx = int(match_j.group(2), 10);
        if ((heightPx <= 0) or (widthPx <= 0)) {
            return True;
        }
        setCellDimensions({"widthPx": widthPx, "heightPx": heightPx});
        self.invalidate();
        self.requestRender();
        return True;
    }
    override def resolveOverlayLayout(options: any | None, overlayHeight: float, termWidth: float, termHeight: float) -> dict[str, float | float | None] {
        opt: dict[str, any] = (options if options is not None else {});
        optMargin = opt.get("margin");
        margin: dict[str, any] = ({"top": optMargin, "right": optMargin, "bottom": optMargin, "left": optMargin} if isinstance(optMargin, (int, float)) else (optMargin if optMargin is not None else {}));
        marginTop = max(float(0), float(((margin.get("top") if margin.get("top") is not None else 0)) as float));
        marginRight = max(float(0), float(((margin.get("right") if margin.get("right") is not None else 0)) as float));
        marginBottom = max(float(0), float(((margin.get("bottom") if margin.get("bottom") is not None else 0)) as float));
        marginLeft = max(float(0), float(((margin.get("left") if margin.get("left") is not None else 0)) as float));
        availWidth = max(float(1), float(((termWidth - marginLeft) - marginRight)));
        availHeight = max(float(1), float(((termHeight - marginTop) - marginBottom)));
        parsedWidth = parseSizeValue(opt.get("width"), termWidth);
        width = (parsedWidth if parsedWidth is not None else min(float(80), float(availWidth)));
        if (opt.get("minWidth") != None) {
            width = max(float(width), float((opt.get("minWidth") as float)));
        }
        width = max(float(1), float(min(float(width), float(availWidth))));
        maxHeight = parseSizeValue(opt.get("maxHeight"), termHeight);
        if (maxHeight != None) {
            maxHeight = max(float(1), float(min(float(maxHeight), float(availHeight))));
        }
        effectiveHeight = (min(float(overlayHeight), float(maxHeight)) if (maxHeight != None) else overlayHeight);
        row: float;
        col: float;
        optRow = opt.get("row");
        if (optRow != None) {
            if isinstance(optRow, str) {
                match_j = search(r"^(\d+(?:\.\d+)?)%$", optRow);
                if match_j {
                    maxRow = max(float(0), float((availHeight - effectiveHeight)));
                    percent = (float(match_j.group(1)) / 100);
                    row = (marginTop + int(((maxRow * percent)) // 1));
                }
                else {
                    row = self.resolveAnchorRow("center", effectiveHeight, availHeight, marginTop);
                }
            }
            else {
                row = (optRow as float);
            }
        }
        else {
            anchor = (opt.get("anchor") if opt.get("anchor") is not None else "center");
            row = self.resolveAnchorRow(anchor, effectiveHeight, availHeight, marginTop);
        }
        optCol = opt.get("col");
        if (optCol != None) {
            if isinstance(optCol, str) {
                match_j = search(r"^(\d+(?:\.\d+)?)%$", optCol);
                if match_j {
                    maxCol = max(float(0), float((availWidth - width)));
                    percent = (float(match_j.group(1)) / 100);
                    col = (marginLeft + int(((maxCol * percent)) // 1));
                }
                else {
                    col = self.resolveAnchorCol("center", width, availWidth, marginLeft);
                }
            }
            else {
                col = (optCol as float);
            }
        }
        else {
            anchor = (opt.get("anchor") if opt.get("anchor") is not None else "center");
            col = self.resolveAnchorCol(anchor, width, availWidth, marginLeft);
        }
        if (opt.get("offsetY") != None) {
            row = float(row + (opt.get("offsetY") as float));
        }
        if (opt.get("offsetX") != None) {
            col = float(col + (opt.get("offsetX") as float));
        }
        row = max(float(marginTop), float(min(float(row), float(((termHeight - marginBottom) - effectiveHeight)))));
        col = max(float(marginLeft), float(min(float(col), float(((termWidth - marginRight) - width)))));
        return {"width": width, "row": row, "col": col, "maxHeight": maxHeight};
    }
    override def resolveAnchorRow(anchor: any, height: float, availHeight: float, marginTop: float) -> float {
        _sw = anchor;
        if (_sw == "top-left") or (_sw == "top-center") or (_sw == "top-right") {
            return marginTop;
        }
        elif (_sw == "bottom-left") or (_sw == "bottom-center") or (_sw == "bottom-right") {
            return ((marginTop + availHeight) - height);
        }
        elif (_sw == "left-center") or (_sw == "center") or (_sw == "right-center") {
            return (marginTop + int((((availHeight - height) / 2)) // 1));
        }
        return marginTop;
    }
    override def resolveAnchorCol(anchor: any, width: float, availWidth: float, marginLeft: float) -> float {
        _sw = anchor;
        if (_sw == "top-left") or (_sw == "left-center") or (_sw == "bottom-left") {
            return marginLeft;
        }
        elif (_sw == "top-right") or (_sw == "right-center") or (_sw == "bottom-right") {
            return ((marginLeft + availWidth) - width);
        }
        elif (_sw == "top-center") or (_sw == "center") or (_sw == "bottom-center") {
            return (marginLeft + int((((availWidth - width) / 2)) // 1));
        }
        return marginLeft;
    }
    override def compositeOverlays(lines: list[str], termWidth: float, termHeight: float) -> list[str] {
        if (len(self.overlayStack) == 0) {
            return lines;
        }
        result = [*lines];
        rendered: list[dict[str, list[str] | float]] = [];
        minLinesNeeded: float = float(len(result));
        visibleEntries = [e for e in self.overlayStack if self.isOverlayVisible(e)];
        visibleEntries.sort(key=lambda (_jx_sort: any) -> any { return _jx_sort["focusOrder"]; });
        for entry_j in visibleEntries {
            component = entry_j.component;
            options = entry_j.options;
            layout0 = self.resolveOverlayLayout(options, 0, termWidth, termHeight);
            width = (layout0["width"] as float);
            maxHeight = layout0["maxHeight"];
            overlayLines = component.render(width);
            if ((maxHeight != None) and (len(overlayLines) > maxHeight)) {
                overlayLines = overlayLines[0:maxHeight];
            }
            layout1 = self.resolveOverlayLayout(options, len(overlayLines), termWidth, termHeight);
            row = (layout1["row"] as float);
            col = (layout1["col"] as float);
            rendered.append({"overlayLines": overlayLines, "row": row, "col": col, "w": width});
            minLinesNeeded = max(float(minLinesNeeded), float((row + len(overlayLines))));
        }
        workingHeight = max(float(len(result)), float(termHeight), float(minLinesNeeded));
        while (len(result) < workingHeight) {
            result.append("");
        }
        viewportStart = max(float(0), float((workingHeight - termHeight)));
        for _jx_item0 in rendered {
            overlayLines = (_jx_item0["overlayLines"] as list[str]);
            row = (_jx_item0["row"] as float);
            col = (_jx_item0["col"] as float);
            w = (_jx_item0["w"] as float);
            i: int = 0;
            while (i < len(overlayLines)) {
                idx: int = int(((viewportStart + row) + i));
                if ((idx >= 0) and (idx < len(result))) {
                    truncatedOverlayLine = (sliceByColumn(overlayLines[i], 0, w, True) if (visibleWidth(overlayLines[i]) > w) else overlayLines[i]);
                    result[idx] = self.compositeLineAt(result[idx], (truncatedOverlayLine as str), col, w, termWidth);
                }
                i += 1;
            }
        }
        return result;
    }
    override def applyLineResets(lines: list[str]) -> list[str] {
        reset = SEGMENT_RESET;
        i: int = 0;
        while (i < len(lines)) {
            line = lines[i];
            if not isImageLine(line) {
                lines[i] = (normalizeTerminalOutput(line) + reset);
            }
            i += 1;
        }
        return lines;
    }
    override def collectKittyImageIds(lines: list[str]) -> any {
        ids = set();
        for line in lines {
            for id_j in extractKittyImageIds(line) {
                ids.add(id_j);
            }
        }
        return ids;
    }
    override def deleteKittyImages(ids: any) -> str {
        buffer: str = "";
        for id_j in ids {
            buffer += deleteKittyImage(id_j);
        }
        return buffer;
    }
    override def getKittyImageReservedRows(lines: list[str], index: float, maxIndex: any = None) -> float {
        if (maxIndex is None) {
            maxIndex = (len(lines) - 1);
        }
        headerLine = lines[index];
        rows: float = float(extractKittyImageRows((headerLine if headerLine is not None else "") as str));
        if (rows <= 1) {
            return 1;
        }
        maxRows = min(float(rows), float(((maxIndex - index) + 1)), float((len(lines) - index)));
        reservedRows = 1;
        while (reservedRows < maxRows) {
            rawLine = lines[(index + reservedRows)];
            line = ((rawLine if rawLine is not None else "") as str);
            if (isImageLine(line) or (visibleWidth(line) > 0)) {
                break;
            }
            reservedRows += 1;
        }
        return reservedRows;
    }
    override def expandChangedRangeForKittyImages(firstChanged: float, lastChanged: float, newLines: list[str]) -> dict[str, float] {
        expandedFirstChanged = firstChanged;
        expandedLastChanged = lastChanged;
        def expandForLines(lines: list[str]) -> None {
            i: int = 0;
            while (i < len(lines)) {
                if (len(extractKittyImageIds(lines[i])) == 0) {
                    i += 1;
                    continue;
                }
                blockEnd = ((i + self.getKittyImageReservedRows(lines, i)) - 1);
                if ((i >= firstChanged) or ((i <= lastChanged) and (blockEnd >= firstChanged))) {
                    expandedFirstChanged = min(float(expandedFirstChanged), float(i));
                    expandedLastChanged = max(float(expandedLastChanged), float(blockEnd));
                }
                i += 1;
            }
        }
        expandForLines(self.previousLines);
        expandForLines(newLines);
        return {"firstChanged": expandedFirstChanged, "lastChanged": expandedLastChanged};
    }
    override def deleteChangedKittyImages(firstChanged: float, lastChanged: float) -> str {
        if ((firstChanged < 0) or (lastChanged < firstChanged)) {
            return "";
        }
        ids = set();
        maxLine = min(float(lastChanged), float((len(self.previousLines) - 1)));
        i: int = int(firstChanged);
        while (i <= maxLine) {
            prevLine = self.previousLines[i];
            for id_j in extractKittyImageIds(prevLine if prevLine is not None else "") {
                ids.add(id_j);
            }
            i += 1;
        }
        return self.deleteKittyImages(ids);
    }
    override def compositeLineAt(baseLine: str, overlayLine: str, startCol: float, overlayWidth: float, totalWidth: float) -> str {
        if isImageLine(baseLine) {
            return baseLine;
        }
        afterStart = (startCol + overlayWidth);
        base = extractSegments(baseLine, startCol, afterStart, (totalWidth - afterStart), True);
        overlay = sliceWithWidth(overlayLine, 0, overlayWidth, True);
        beforePad = max(float(0), float((startCol - base["beforeWidth"])));
        overlayPad = max(float(0), float((overlayWidth - overlay["width"])));
        actualBeforeWidth = max(float(startCol), float(base["beforeWidth"]));
        actualOverlayWidth = max(float(overlayWidth), float(overlay["width"]));
        afterTarget = max(float(0), float(((totalWidth - actualBeforeWidth) - actualOverlayWidth)));
        afterPad = max(float(0), float((afterTarget - base["afterWidth"])));
        r = SEGMENT_RESET;
        result = (((((((base["before"] as str) + (" " * int(beforePad))) + r) + (overlay["text"] as str)) + (" " * int(overlayPad))) + r) + (base["after"] as str)) + (" " * int(afterPad));
        resultWidth = visibleWidth(result);
        if (resultWidth <= totalWidth) {
            return result;
        }
        return sliceByColumn(result, 0, totalWidth, True);
    }
    override def extractCursorPosition(lines: list[str], height: float) -> dict[str, float] | None {
        viewportTop = max(float(0), float((len(lines) - height)));
        row: int = int((len(lines) - 1));
        while (row >= viewportTop) {
            line = lines[row];
            markerIndex = (-1 if CURSOR_MARKER not in line else line.index(CURSOR_MARKER));
            if (markerIndex != -1) {
                beforeMarker = line[0:markerIndex];
                col = visibleWidth(beforeMarker);
                lines[row] = (line[0:markerIndex] + line[(markerIndex + len(CURSOR_MARKER)):]);
                return {"row": row, "col": col};
            }
            row += -1;
        }
        return None;
    }
    override def doRender() -> None {
        if self.stopped {
            return;
        }
        width = self.terminal.columns();
        height = self.terminal.rows();
        widthChanged = ((self.previousWidth != 0) and (self.previousWidth != width));
        heightChanged = ((self.previousHeight != 0) and (self.previousHeight != height));
        previousBufferLength = ((self.previousViewportTop + self.previousHeight) if (self.previousHeight > 0) else height);
        prevViewportTop = (max(float(0), float((previousBufferLength - height))) if heightChanged else self.previousViewportTop);
        viewportTop = prevViewportTop;
        hardwareCursorRow = self.hardwareCursorRow;
        computeLineDiff = lambda (targetRow: float) -> any { currentScreenRow = (hardwareCursorRow - prevViewportTop); targetScreenRow = (targetRow - viewportTop); return (targetScreenRow - currentScreenRow); };
        newLines = self.render(width);
        if (len(self.overlayStack) > 0) {
            newLines = self.compositeOverlays(newLines, width, height);
        }
        cursorPos = self.extractCursorPosition(newLines, height);
        newLines = self.applyLineResets(newLines);
        def fullRender(clear: bool) -> None {
            self.fullRedrawCount += 1;
            buffer: str = "\u001b[?2026h";
            if clear {
                buffer += self.deleteKittyImages(self.previousKittyImageIds);
                buffer += "\u001b[2J\u001b[H\u001b[3J";
            }
            i: int = 0;
            while (i < len(newLines)) {
                if (i > 0) {
                    buffer += "\r\n";
                }
                line = newLines[i];
                isImage = isImageLine(line);
                imageReservedRows = (self.getKittyImageReservedRows(newLines, i) if isImage else 1);
                if ((imageReservedRows > 1) and (imageReservedRows <= height)) {
                    row: int = 1;
                    while (row < imageReservedRows) {
                        buffer += "\r\n";
                        row += 1;
                    }
                    buffer += f"\x1b[{(imageReservedRows - 1)}A";
                    buffer += line;
                    buffer += f"\x1b[{(imageReservedRows - 1)}B";
                    i += int((imageReservedRows - 1));
                    continue;
                }
                buffer += line;
                i += 1;
            }
            buffer += "\u001b[?2026l";
            self.terminal.write(buffer);
            self.cursorRow = max(float(0), float((len(newLines) - 1)));
            self.hardwareCursorRow = self.cursorRow;
            if clear {
                self.maxLinesRendered = len(newLines);
            } else {
                self.maxLinesRendered = max(float(self.maxLinesRendered), float(len(newLines)));
            }
            bufferLength = max(float(height), float(len(newLines)));
            self.previousViewportTop = max(float(0), float((bufferLength - height)));
            self.positionHardwareCursor(cursorPos, len(newLines));
            self.previousLines = newLines;
            self.previousKittyImageIds = self.collectKittyImageIds(newLines);
            self.previousWidth = width;
            self.previousHeight = height;
        }
        debugRedraw = (environ.get("PI_DEBUG_REDRAW") == "1");
        def logRedraw(reason: str) -> None {
            if not debugRedraw {
                return;
            }
            logPath = os.path.join(os.path.expanduser("~"), ".pi-tui-redraw.log");
            msg: str = f"[{datetime.datetime.now().isoformat()}] fullRender: {reason} (prev={len(self.previousLines)}, new={len(newLines)}, height={height})\n";
            fs.appendFileSync(logPath, msg);
        }
        if (((len(self.previousLines) == 0) and not widthChanged) and not heightChanged) {
            logRedraw("first render");
            fullRender(False);
            return;
        }
        if widthChanged {
            logRedraw(f"terminal width changed ({self.previousWidth} -> {width})");
            fullRender(True);
            return;
        }
        if (heightChanged and not isTermuxSession()) {
            logRedraw(f"terminal height changed ({self.previousHeight} -> {height})");
            fullRender(True);
            return;
        }
        if ((self.clearOnShrink and (len(newLines) < self.maxLinesRendered)) and (len(self.overlayStack) == 0)) {
            logRedraw(f"clearOnShrink (maxLinesRendered={self.maxLinesRendered})");
            fullRender(True);
            return;
        }
        firstChanged = -1;
        lastChanged = -1;
        maxLines = max(float(len(newLines)), float(len(self.previousLines)));
        i: int = 0;
        while (i < maxLines) {
            oldLine = (self.previousLines[i] if (i < len(self.previousLines)) else "");
            newLine = (newLines[i] if (i < len(newLines)) else "");
            if (oldLine != newLine) {
                if (firstChanged == -1) {
                    firstChanged = i;
                }
                lastChanged = i;
            }
            i += 1;
        }
        appendedLines = (len(newLines) > len(self.previousLines));
        if appendedLines {
            if (firstChanged == -1) {
                firstChanged = len(self.previousLines);
            }
            lastChanged = (len(newLines) - 1);
        }
        if (firstChanged != -1) {
            expandedRange = self.expandChangedRangeForKittyImages(firstChanged, lastChanged, newLines);
            firstChanged = int(expandedRange["firstChanged"]);
            lastChanged = int(expandedRange["lastChanged"]);
        }
        appendStart = ((appendedLines and (firstChanged == len(self.previousLines))) and (firstChanged > 0));
        if (firstChanged == -1) {
            self.positionHardwareCursor(cursorPos, len(newLines));
            self.previousViewportTop = prevViewportTop;
            self.previousHeight = height;
            return;
        }
        if (firstChanged >= len(newLines)) {
            if (len(self.previousLines) > len(newLines)) {
                buffer: str = "\u001b[?2026h";
                buffer += self.deleteChangedKittyImages(firstChanged, lastChanged);
                targetRow = max(float(0), float((len(newLines) - 1)));
                if (targetRow < prevViewportTop) {
                    logRedraw(f"deleted lines moved viewport up ({targetRow} < {prevViewportTop})");
                    fullRender(True);
                    return;
                }
                lineDiff = computeLineDiff(targetRow);
                if (lineDiff > 0) {
                    buffer += f"\x1b[{lineDiff}B";
                }
                elif (lineDiff < 0) {
                    buffer += f"\x1b[{-lineDiff}A";
                }
                buffer += "\r";
                extraLines = (len(self.previousLines) - len(newLines));
                if (extraLines > height) {
                    logRedraw(f"extraLines > height ({extraLines} > {height})");
                    fullRender(True);
                    return;
                }
                clearStartOffset = (0 if (len(newLines) == 0) else 1);
                if ((extraLines > 0) and (clearStartOffset > 0)) {
                    buffer += f"\x1b[{clearStartOffset}B";
                }
                i: int = 0;
                while (i < extraLines) {
                    buffer += "\r\u001b[2K";
                    if (i < (extraLines - 1)) {
                        buffer += "\u001b[1B";
                    }
                    i += 1;
                }
                moveBack = max(float(0), float(((extraLines - 1) + clearStartOffset)));
                if (moveBack > 0) {
                    buffer += f"\x1b[{moveBack}A";
                }
                buffer += "\u001b[?2026l";
                self.terminal.write(buffer);
                self.cursorRow = targetRow;
                self.hardwareCursorRow = targetRow;
            }
            self.positionHardwareCursor(cursorPos, len(newLines));
            self.previousLines = newLines;
            self.previousKittyImageIds = self.collectKittyImageIds(newLines);
            self.previousWidth = width;
            self.previousHeight = height;
            self.previousViewportTop = prevViewportTop;
            return;
        }
        if (firstChanged < prevViewportTop) {
            logRedraw(f"firstChanged < viewportTop ({firstChanged} < {prevViewportTop})");
            fullRender(True);
            return;
        }
        buffer: str = "\u001b[?2026h";
        buffer += self.deleteChangedKittyImages(firstChanged, lastChanged);
        prevViewportBottom = ((prevViewportTop + height) - 1);
        moveTargetRow = ((firstChanged - 1) if appendStart else firstChanged);
        if (moveTargetRow > prevViewportBottom) {
            currentScreenRow = max(float(0), float(min(float((height - 1)), float((hardwareCursorRow - prevViewportTop)))));
            moveToBottom = ((height - 1) - currentScreenRow);
            if (moveToBottom > 0) {
                buffer += f"\x1b[{moveToBottom}B";
            }
            scroll = (moveTargetRow - prevViewportBottom);
            buffer += ("\r\n" * int(scroll));
            prevViewportTop += scroll;
            viewportTop += scroll;
            hardwareCursorRow = moveTargetRow;
        }
        lineDiff = computeLineDiff(moveTargetRow);
        if (lineDiff > 0) {
            buffer += f"\x1b[{lineDiff}B";
        }
        elif (lineDiff < 0) {
            buffer += f"\x1b[{-lineDiff}A";
        }
        buffer += ("\r\n" if appendStart else "\r");
        renderEnd = min(float(lastChanged), float((len(newLines) - 1)));
        i: int = int(firstChanged);
        while (i <= renderEnd) {
            if (i > firstChanged) {
                buffer += "\r\n";
            }
            line = newLines[i];
            isImage = isImageLine(line);
            imageReservedRows = (self.getKittyImageReservedRows(newLines, i, renderEnd) if isImage else 1);
            if (imageReservedRows > 1) {
                imageStartScreenRow = (i - viewportTop);
                if ((imageStartScreenRow < 0) or ((imageStartScreenRow + imageReservedRows) > height)) {
                    logRedraw(f"kitty image pre-clear would scroll ({imageStartScreenRow} + {imageReservedRows} > {height})");
                    fullRender(True);
                    return;
                }
                buffer += "\u001b[2K";
                row: int = 1;
                while (row < imageReservedRows) {
                    buffer += "\r\n\u001b[2K";
                    row += 1;
                }
                buffer += f"\x1b[{(imageReservedRows - 1)}A";
                buffer += line;
                buffer += f"\x1b[{(imageReservedRows - 1)}B";
                i += int((imageReservedRows - 1));
                continue;
            }
            buffer += "\u001b[2K";
            if (not isImage and (visibleWidth(line) > width)) {
                crashDir = os.path.join(os.path.expanduser("~"), ".pi-tui-crash");
                os.makedirs(crashDir, exist_ok=True);
                crashLogPath = os.path.join(crashDir, f"crash-{int(now_ms())}.log");
                renderedLines: list[str] = [];
                _rl_idx: int = 0;
                while (_rl_idx < len(newLines)) {
                    renderedLines.append(f"[{_rl_idx}] (w={visibleWidth(newLines[_rl_idx])}) {newLines[_rl_idx]}");
                    _rl_idx += 1;
                }
                crashData = "\n".join([f"Crash at {datetime.datetime.now().isoformat()}", f"Terminal width: {width}", f"Line {i} visible width: {visibleWidth(line)}", "", "=== All rendered lines ===", *renderedLines, ""]);
                with open(crashLogPath, "w", encoding="utf8") as _crash_fh {
                    _crash_fh.write(crashData);
                }
                self.stop();
                errorMsg = "\n".join([f"Rendered line {i} exceeds terminal width ({visibleWidth(line)} > {width}).", "", "This is likely caused by a custom TUI component not truncating its output.", "Use visibleWidth() to measure and truncateToWidth() to truncate lines.", "", f"Debug log written to: {crashLogPath}"]);
                raise Exception(errorMsg);
            }
            buffer += line;
            i += 1;
        }
        finalCursorRow = renderEnd;
        if (len(self.previousLines) > len(newLines)) {
            if (renderEnd < (len(newLines) - 1)) {
                moveDown = ((len(newLines) - 1) - renderEnd);
                buffer += f"\x1b[{moveDown}B";
                finalCursorRow = (len(newLines) - 1);
            }
            extraLines = (len(self.previousLines) - len(newLines));
            i: int = int(len(newLines));
            while (i < len(self.previousLines)) {
                buffer += "\r\n\u001b[2K";
                i += 1;
            }
            buffer += f"\x1b[{extraLines}A";
        }
        buffer += "\u001b[?2026l";
        if (environ.get("PI_TUI_DEBUG") == "1") {
            debugDir: str = "/tmp/tui";
            os.makedirs(debugDir, exist_ok=True);
            debugPath = os.path.join(debugDir, "render-debug.log");
            debugData = "\n".join([f"firstChanged: {firstChanged}", f"viewportTop: {viewportTop}", f"cursorRow: {self.cursorRow}", f"height: {height}", f"lineDiff: {lineDiff}", f"hardwareCursorRow: {hardwareCursorRow}", f"renderEnd: {renderEnd}", f"finalCursorRow: {finalCursorRow}", f"cursorPos: {json.dumps(cursorPos)}", f"newLines.length: {len(newLines)}", f"previousLines.length: {len(self.previousLines)}", "", "=== newLines ===", json.dumps(newLines, indent=2), "", "=== previousLines ===", json.dumps(self.previousLines, indent=2), "", "=== buffer ===", json.dumps(buffer)]);
            with open(debugPath, "w", encoding="utf8") as _debug_fh {
                _debug_fh.write(debugData);
            }
        }
        self.terminal.write(buffer);
        self.cursorRow = max(float(0), float((len(newLines) - 1)));
        self.hardwareCursorRow = finalCursorRow;
        self.maxLinesRendered = max(float(self.maxLinesRendered), float(len(newLines)));
        self.previousViewportTop = max(float(prevViewportTop), float(((finalCursorRow - height) + 1)));
        self.positionHardwareCursor(cursorPos, len(newLines));
        self.previousLines = newLines;
        self.previousKittyImageIds = self.collectKittyImageIds(newLines);
        self.previousWidth = width;
        self.previousHeight = height;
    }
    override def positionHardwareCursor(cursorPos: dict[str, float] | None, totalLines: float) -> None {
        if (not cursorPos or (totalLines <= 0)) {
            self.terminal.hideCursor();
            return;
        }
        targetRow = max(float(0), float(min(float(cursorPos["row"]), float((totalLines - 1)))));
        targetCol = max(float(0), float(cursorPos["col"]));
        rowDelta = (targetRow - self.hardwareCursorRow);
        buffer: str = "";
        if (rowDelta > 0) {
            buffer += f"\x1b[{rowDelta}B";
        }
        elif (rowDelta < 0) {
            buffer += f"\x1b[{-rowDelta}A";
        }
        buffer += f"\x1b[{(targetCol + 1)}G";
        if buffer {
            self.terminal.write(buffer);
        }
        self.hardwareCursorRow = targetRow;
        if self.showHardwareCursor {
            self.terminal.showCursor();
        }
        else {
            self.terminal.hideCursor();
        }
    }
    override def queryTerminalBackgroundColor(timeoutMs: float) -> SimplePromise {
        def executor(resolve: any) -> None {
            query: OscQuery = OscQuery(settled=False, resolve=resolve, timer=None);
            def onTimeout() -> None {
                if query.settled {
                    return;
                }
                query.settled = True;
                query.timer = None;
                if query.resolve is not None {
                    query.resolve(None);
                }
                query.resolve = None;
            }
            query.timer = set_timeout(onTimeout, timeoutMs);
            self.pendingOsc11BackgroundQueries.append(query);
            self.pendingOsc11BackgroundReplies += 1;
            self.terminal.write("\u001b]11;?\u0007");
        }
        return Promise(executor);
    }
    override def queryTerminalColorScheme(timeoutMs: float) -> SimplePromise {
        def executor(resolve: any) -> None {
            state: dict = {"settled": False, "timer": None, "unsubscribe": None};
            def settle(scheme: any | None) -> None {
                if state["settled"] {
                    return;
                }
                state["settled"] = True;
                if state["timer"] {
                    clear_timeout(state["timer"]);
                    state["timer"] = None;
                }
                if state["unsubscribe"] is not None {
                    state["unsubscribe"]();
                }
                resolve(scheme);
            }
            state["unsubscribe"] = self.onTerminalColorSchemeChange(settle);
            state["timer"] = set_timeout(lambda () -> any { return settle(None); }, timeoutMs);
            self.terminal.write("\u001b[?996n");
        }
        return Promise(executor);
    }
}
