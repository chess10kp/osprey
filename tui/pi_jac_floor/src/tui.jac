# interop import: node:fs { fs }
# interop import: node:os { os }
# interop import: node:path { path }
# interop import: node:perf_hooks { performance }
import from "./keys.jac" { isKeyRelease, matchesKey }
import from "./terminal-colors.jac" { isOsc11BackgroundColorResponse, parseOsc11BackgroundColor, parseTerminalColorSchemeReport }
import from "./terminal-image.jac" { deleteKittyImage, getCapabilities, isImageLine, setCellDimensions }
import from "./utils.jac" { extractSegments, normalizeTerminalOutput, sliceByColumn, sliceWithWidth, visibleWidth }
import from re { search }
import from os { environ }

glob KITTY_SEQUENCE_PREFIX = "\u001b_G";

def parseKittyImageHeader(line: str) -> any | None {
    sequenceStart = (-1 if KITTY_SEQUENCE_PREFIX not in line else line.index(KITTY_SEQUENCE_PREFIX));
    if (sequenceStart == -1) {
        return None;
    }
    paramsStart = (sequenceStart + len(KITTY_SEQUENCE_PREFIX));
    paramsEnd = line.indexOf(";", paramsStart);
    if (paramsEnd == -1) {
        return None;
    }
    ids: list[float] = [];
    rows = 1;
    params = line[paramsStart:paramsEnd];
    for param in params.split(",") {
        _jx_d0: any = param.split("=", 2);
        key = _jx_d0[0];
        value = _jx_d0[1];
        if (value == None) {
            continue;
        }
        numberValue = Number(value);
        if ((not Number.isInteger(numberValue) or (numberValue <= 0)) or (numberValue > 4294967295)) {
            continue;
        }
        if (key == "i") {
            ids.append(numberValue);
        }
        elif (key == "r") {
            rows = numberValue;
        }
    }
    return {"ids": ids, "rows": rows};
}

def extractKittyImageIds(line: str) -> list[float] {
    return ((lambda (_jx_null1: any) -> any { return (_jx_null1 if _jx_null1 is not None else []); })(((lambda (_jx_opt0: any) -> any { return ((_jx_opt0["ids"] as list[float]) if _jx_opt0 is not None else None); })(parseKittyImageHeader(line)))));
}

def extractKittyImageRows(line: str) -> float {
    return ((lambda (_jx_null3: any) -> any { return (_jx_null3 if _jx_null3 is not None else 1); })(((lambda (_jx_opt2: any) -> any { return ((_jx_opt2["rows"] as float) if _jx_opt2 is not None else None); })(parseKittyImageHeader(line)))));
}

def:pub isFocusable(component: any | None) -> bool {
    return ((component != None) and ("focused" in component));
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
    return Boolean(environ.get("TERMUX_VERSION"));
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

obj:pub TUI(Container) {
    has terminal: any;
    has onDebug: any | None = None;
    has renderTimer: any | None;
    has children: any = None;
    has previousLines: list[str] = [];
    has previousKittyImageIds: any = set();
    has previousWidth: int = 0;
    has previousHeight: int = 0;
    has focusedComponent: any | None = None;
    has inputListeners: any = set();
    has renderRequested: bool = False;
    has lastRenderAt: int = 0;
    has cursorRow: int = 0;
    has hardwareCursorRow: int = 0;
    has showHardwareCursor: any = (environ.get("PI_HARDWARE_CURSOR") == "1");
    has clearOnShrink: any = (environ.get("PI_CLEAR_ON_SHRINK") == "1");
    has maxLinesRendered: int = 0;
    has previousViewportTop: int = 0;
    has fullRedrawCount: int = 0;
    has stopped: bool = False;
    has pendingOsc11BackgroundReplies: int = 0;
    has pendingOsc11BackgroundQueries: list[any] = [];
    has terminalColorSchemeListeners: any = set();
    has terminalColorSchemeNotificationsEnabled: bool = False;
    has focusOrderCounter: int = 0;
    has overlayStack: list[any] = [];
    has overlayFocusRestore: any = {"status": "inactive"};
    def __init__(terminal: any, showHardwareCursor: bool | None = None) -> None {
        super();
        self.terminal = terminal;
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
        self.setFocusInternal({"component": component, "overlayFocusRestore": "clear"});
    }
    # JS2JAC-HOLE[E7232] Unsupported class method parameter form: ObjectPattern:
    # | private setFocusInternal({
    # | 		component,
    # | 		overlayFocusRestore,
    # | 	}: {
    # | 		component: Component | null;
    # | 		overlayFocusRestore: OverlayFocusRestorePolicy;
    # | 	}): void {
    # | 		const previousFocus = this.focusedComponent;
    # | 		let nextFocus = component;
    # | 		const previousFocusedOverlay = previousFocus
    # | 			? this.overlayStack.find((entry) => entry.component === previousFocus && this.isOverlayVisible(entry))
    # | 			: undefined;
    # | 		const nextFocusIsOverlay = nextFocus ? this.overlayStack.some((entry) => entry.component === nextFocus) : false;
    # | 		const restoreState = this.getVisibleOverlayFocusRestore();
    # | 		if (nextFocus && !nextFocusIsOverlay) {
    # | 			if (restoreState.status === "blocked" && restoreState.blockedBy === previousFocus) {
    # | 				if (restoreState.resume.status === "focus-target" || !this.isComponentMounted(restoreState.blockedBy)) {
    # | 					nextFocus = this.resolveBlockedOverlayFocusResume(restoreState);
    # | 				} else {
    # | 					this.overlayFocusRestore = {
    # | 						status: "blocked",
    # | 						overlay: restoreState.overlay,
    # | 						blockedBy: nextFocus,
    # | 						resume: restoreState.resume,
    # | 					};
    # | 				}
    # | 			} else if (
    # | 				previousFocusedOverlay &&
    # | 				restoreState.status !== "inactive" &&
    # | 				restoreState.overlay === previousFocusedOverlay &&
    # | 				!this.isOverlayFocusAncestor(previousFocusedOverlay, nextFocus)
    # | 			) {
    # | 				this.overlayFocusRestore = {
    # | 					status: "blocked",
    # | 					overlay: previousFocusedOverlay,
    # | 					blockedBy: nextFocus,
    # | 					resume: { status: "restore-overlay" },
    # | 				};
    # | 			}
    # | 		} else if (nextFocus === null) {
    # | 			if (restoreState.status === "blocked" && restoreState.blockedBy === previousFocus) {
    # | 				nextFocus = this.resolveBlockedOverlayFocusResume(restoreState);
    # | 			} else if (overlayFocusRestore === "clear") {
    # | 				this.clearOverlayFocusRestore();
    # | 			}
    # | 		}
    # | 
    # | 		if (isFocusable(this.focusedComponent)) {
    # | 			this.focusedComponent.focused = false;
    # | 		}
    # | 
    # | 		this.focusedComponent = nextFocus;
    # | 
    # | 		if (isFocusable(nextFocus)) {
    # | 			nextFocus.focused = true;
    # | 		}
    # | 
    # | 		const focusedOverlay = nextFocus
    # | 			? this.overlayStack.find((entry) => entry.component === nextFocus && this.isOverlayVisible(entry))
    # | 			: undefined;
    # | 		if (focusedOverlay) {
    # | 			this.overlayFocusRestore = { status: "eligible", overlay: focusedOverlay };
    # | 		}
    # | 	}
    override def clearOverlayFocusRestore() -> None {
        self.overlayFocusRestore = {"status": "inactive"};
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
            return {"status": "inactive"};
        }
        return restoreState;
    }
    override def isOverlayFocusAncestor(entry_j: any, component: any) -> bool {
        visited = set();
        current = entry_j.preFocus;
        while (current and not visited.has(current)) {
            visited.add(current);
            if (current == component) {
                return True;
            }
            current = ((lambda (_jx_null6: any) -> any { return (_jx_null6 if _jx_null6 is not None else None); })(((lambda (_jx_opt5: any) -> any { return (_jx_opt5.preFocus if _jx_opt5 is not None else None); })(self.overlayStack.find(lambda (overlay: any) -> any { return (overlay.component == current); })))));
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
    # JS2JAC-HOLE[E7205] Class method produced no output:
    # | private containsComponent(root: Component, target: Component): boolean {
    # | 		if (root === target) return true;
    # | 		if (!(root instanceof Container)) return false;
    # | 		return root.children.some((child) => this.containsComponent(child, target));
    # | 	}
    # JS2JAC-HOLE[E7205] Class method produced no output:
    # | showOverlay(component: Component, options?: OverlayOptions): OverlayHandle {
    # | 		const entry: OverlayStackEntry = {
    # | 			component,
    # | 			...(options === undefined ? {} : { options }),
    # | 			preFocus: this.focusedComponent,
    # | 			hidden: false,
    # | 			focusOrder: ++this.focusOrderCounter,
    # | 		};
    # | 		this.overlayStack.push(entry);
    # | 		// Only focus if overlay is actually visible
    # | 		if (!options?.nonCapturing && this.isOverlayVisible(entry)) {
    # | 			this.setFocus(component);
    # | 		}
    # | 		this.terminal.hideCursor();
    # | 		this.requestRender();
    # | 
    # | 		// Return handle for controlling this overlay
    # | 		return {
    # | 			hide: () => {
    # | 				const index = this.overlayStack.indexOf(entry);
    # | 				if (index !== -1) {
    # | 					this.clearOverlayFocusRestoreFor(entry);
    # | 					this.retargetOverlayPreFocus(entry);
    # | 					this.overlayStack.splice(index, 1);
    # | 					// Restore focus if this overlay had focus
    # | 					if (this.focusedComponent === component) {
    # | 						const topVisible = this.getTopmostVisibleOverlay();
    # | 						this.setFocus(topVisible?.component ?? entry.preFocus);
    # | 					}
    # | 					if (this.overlayStack.length === 0) this.terminal.hideCursor();
    # | 					this.requestRender();
    # | 				}
    # | 			},
    # | 			setHidden: (hidden: boolean) => {
    # | 				if (entry.hidden === hidden) return;
    # | 				entry.hidden = hidden;
    # | 				// Update focus when hiding/showing
    # | 				if (hidden) {
    # | 					this.clearOverlayFocusRestoreFor(entry);
    # | 					// If this overlay had focus, move focus to next visible or preFocus
    # | 					if (this.focusedComponent === component) {
    # | 						const topVisible = this.getTopmostVisibleOverlay();
    # | 						this.setFocus(topVisible?.component ?? entry.preFocus);
    # | 					}
    # | 				} else {
    # | 					// Restore focus to this overlay when showing (if it's actually visible)
    # | 					if (!options?.nonCapturing && this.isOverlayVisible(entry)) {
    # | 						entry.focusOrder = ++this.focusOrderCounter;
    # | 						this.setFocus(component);
    # | 					}
    # | 				}
    # | 				this.requestRender();
    # | 			},
    # | 			isHidden: () => entry.hidden,
    # | 			focus: () => {
    # | 				if (!this.overlayStack.includes(entry) || !this.isOverlayVisible(entry)) return;
    # | 				entry.focusOrder = ++this.focusOrderCounter;
    # | 				this.setFocus(component);
    # | 				this.requestRender();
    # | 			},
    # | 			unfocus: (unfocusOptions) => {
    # | 				const isFocused = this.focusedComponent === component;
    # | 				const restoreState = this.overlayFocusRestore;
    # | 				const hasPendingRestore = restoreState.status !== "inactive" && restoreState.overlay === entry;
    # | 				if (!isFocused && !hasPendingRestore) return;
    # | 				if (
    # | 					restoreState.status === "blocked" &&
    # | 					restoreState.overlay === entry &&
    # | 					this.focusedComponent === restoreState.blockedBy
    # | 				) {
    # | 					if (unfocusOptions) {
    # | 						this.overlayFocusRestore = {
    # | 							status: "blocked",
    # | 							overlay: entry,
    # | 							blockedBy: restoreState.blockedBy,
    # | 							resume: { status: "focus-target", target: unfocusOptions.target },
    # | 						};
    # | 					} else {
    # | 						this.clearOverlayFocusRestore();
    # | 					}
    # | 					this.requestRender();
    # | 					return;
    # | 				}
    # | 				this.clearOverlayFocusRestoreFor(entry);
    # | 				if (isFocused || unfocusOptions) {
    # | 					const topVisible = this.getTopmostVisibleOverlay();
    # | 					const fallbackTarget = topVisible && topVisible !== entry ? topVisible.component : entry.preFocus;
    # | 					this.setFocus(unfocusOptions ? unfocusOptions.target : fallbackTarget);
    # | 				}
    # | 				this.requestRender();
    # | 			},
    # | 			isFocused: () => this.focusedComponent === component,
    # | 		};
    # | 	}
    override def hideOverlay() -> None {
        overlay = self.overlayStack[(len(self.overlayStack) - 1)];
        if not overlay {
            return;
        }
        self.clearOverlayFocusRestoreFor(overlay);
        self.retargetOverlayPreFocus(overlay);
        self.overlayStack.pop();
        if (self.focusedComponent == overlay.component) {
            topVisible = self.getTopmostVisibleOverlay();
            self.setFocus(((lambda (_jx_null14: any) -> any { return (_jx_null14 if _jx_null14 is not None else overlay.preFocus); })(((lambda (_jx_opt13: any) -> any { return (_jx_opt13.component if _jx_opt13 is not None else None); })(topVisible)))));
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
        if ((lambda (_jx_opt15: any) -> any { return (_jx_opt15.visible if _jx_opt15 is not None else None); })(entry_j.options)) {
            return entry_j.options.visible(self.terminal.columns, self.terminal.rows);
        }
        return True;
    }
    override def getTopmostVisibleOverlay() -> any | None {
        topmost: any | None;
        for overlay in self.overlayStack {
            if (((lambda (_jx_opt16: any) -> any { return (_jx_opt16.nonCapturing if _jx_opt16 is not None else None); })(overlay.options)) or not self.isOverlayVisible(overlay)) {
                continue;
            }
            if (not topmost or (overlay.focusOrder > topmost.focusOrder)) {
                topmost = overlay;
            }
        }
        return topmost;
    }
    override def invalidate() -> None {
        super().invalidate();
        for overlay in self.overlayStack {
            ((lambda (_jx_opt17: any) -> any { return (_jx_opt17() if _jx_opt17 is not None else None); })(overlay.component.invalidate));
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
        return lambda () -> any { self.inputListeners.delete(listener); };
    }
    override def removeInputListener(listener: any) -> None {
        self.inputListeners.delete(listener);
    }
    override def onTerminalColorSchemeChange(listener: any) -> any {
        self.terminalColorSchemeListeners.add(listener);
        return lambda () -> any { self.terminalColorSchemeListeners.delete(listener); };
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
        if not getCapabilities().images {
            return;
        }
        self.terminal.write("\u001b[16t");
    }
    override def stop() -> None {
        self.stopped = True;
        if self.renderTimer {
            clearTimeout(self.renderTimer);
            self.renderTimer = None;
        }
        if self.terminalColorSchemeNotificationsEnabled {
            self.terminal.write("\u001b[?2031l");
        }
        if (len(self.previousLines) > 0) {
            targetRow = len(self.previousLines);
            lineDiff = (targetRow - self.hardwareCursorRow);
            if (lineDiff > 0) {
                self.terminal.write(f"\\x1b[{lineDiff}B");
            }
            elif (lineDiff < 0) {
                self.terminal.write(f"\\x1b[{-lineDiff}A");
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
                clearTimeout(self.renderTimer);
                self.renderTimer = None;
            }
            self.renderRequested = True;
            process.nextTick(lambda () -> any { if (self.stopped or not self.renderRequested) {     return; } self.renderRequested = False; self.lastRenderAt = performance.now(); self.doRender(); });
            return;
        }
        if self.renderRequested {
            return;
        }
        self.renderRequested = True;
        process.nextTick(lambda () -> any { return self.scheduleRender(); });
    }
    override def scheduleRender() -> None {
        if ((self.stopped or self.renderTimer) or not self.renderRequested) {
            return;
        }
        elapsed = (performance.now() - self.lastRenderAt);
        delay = max(float(0), float((MIN_RENDER_INTERVAL_MS - elapsed)));
        self.renderTimer = setTimeout(lambda () -> any { self.renderTimer = None; if (self.stopped or not self.renderRequested) {     return; } self.renderRequested = False; self.lastRenderAt = performance.now(); self.doRender(); if self.renderRequested {     self.scheduleRender(); } }, delay);
    }
    override def handleInput(data: str) -> None {
        if self.consumeOsc11BackgroundResponse(data) {
            return;
        }
        if self.consumeTerminalColorSchemeReport(data) {
            return;
        }
        if (self.inputListeners.size > 0) {
            current = data;
            for listener in self.inputListeners {
                result = listener(current);
                if ((lambda (_jx_opt18: any) -> any { return (_jx_opt18.consume if _jx_opt18 is not None else None); })(result)) {
                    return;
                }
                if (((lambda (_jx_opt19: any) -> any { return (_jx_opt19.data if _jx_opt19 is not None else None); })(result)) != None) {
                    current = result.data;
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
        focusedOverlay = self.overlayStack.find(lambda (o: any) -> any { return (o.component == self.focusedComponent); });
        if (focusedOverlay and not self.isOverlayVisible(focusedOverlay)) {
            topVisible = self.getTopmostVisibleOverlay();
            if topVisible {
                self.setFocus(topVisible.component);
            }
            else {
                self.setFocusInternal({"component": focusedOverlay.preFocus, "overlayFocusRestore": "preserve"});
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
        if ((lambda (_jx_opt20: any) -> any { return (_jx_opt20.handleInput if _jx_opt20 is not None else None); })(self.focusedComponent)) {
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
        query = self.pendingOsc11BackgroundQueries.shift();
        if (query and not query.settled) {
            query.settled = True;
            if query.timer {
                clearTimeout(query.timer);
                query.timer = None;
            }
            ((lambda (_jx_opt21: any) -> any { return (_jx_opt21(rgb) if _jx_opt21 is not None else None); })(query.resolve));
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
        opt = ((lambda (_jx_null22: any) -> any { return (_jx_null22 if _jx_null22 is not None else {}); })(options));
        margin = ({"top": opt.margin, "right": opt.margin, "bottom": opt.margin, "left": opt.margin} if isinstance(opt.margin, (int, float)) else ((lambda (_jx_null23: any) -> any { return (_jx_null23 if _jx_null23 is not None else {}); })(opt.margin)));
        marginTop = max(float(0), float(((lambda (_jx_null24: any) -> any { return (_jx_null24 if _jx_null24 is not None else 0); })(margin.top))));
        marginRight = max(float(0), float(((lambda (_jx_null25: any) -> any { return (_jx_null25 if _jx_null25 is not None else 0); })(margin.right))));
        marginBottom = max(float(0), float(((lambda (_jx_null26: any) -> any { return (_jx_null26 if _jx_null26 is not None else 0); })(margin.bottom))));
        marginLeft = max(float(0), float(((lambda (_jx_null27: any) -> any { return (_jx_null27 if _jx_null27 is not None else 0); })(margin.left))));
        availWidth = max(float(1), float(((termWidth - marginLeft) - marginRight)));
        availHeight = max(float(1), float(((termHeight - marginTop) - marginBottom)));
        width = ((lambda (_jx_null28: any) -> any { return (_jx_null28 if _jx_null28 is not None else min(float(80), float(availWidth))); })(parseSizeValue(opt.width, termWidth)));
        if (opt.minWidth != None) {
            width = max(float(width), float(opt.minWidth));
        }
        width = max(float(1), float(min(float(width), float(availWidth))));
        maxHeight = parseSizeValue(opt.maxHeight, termHeight);
        if (maxHeight != None) {
            maxHeight = max(float(1), float(min(float(maxHeight), float(availHeight))));
        }
        effectiveHeight = (min(float(overlayHeight), float(maxHeight)) if (maxHeight != None) else overlayHeight);
        row: float;
        col: float;
        if (opt.row != None) {
            if isinstance(opt.row, str) {
                match_j = search(r"^(\d+(?:\.\d+)?)%$", opt.row);
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
                row = opt.row;
            }
        }
        else {
            anchor = ((lambda (_jx_null29: any) -> any { return (_jx_null29 if _jx_null29 is not None else "center"); })(opt.anchor));
            row = self.resolveAnchorRow(anchor, effectiveHeight, availHeight, marginTop);
        }
        if (opt.col != None) {
            if isinstance(opt.col, str) {
                match_j = search(r"^(\d+(?:\.\d+)?)%$", opt.col);
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
                col = opt.col;
            }
        }
        else {
            anchor = ((lambda (_jx_null30: any) -> any { return (_jx_null30 if _jx_null30 is not None else "center"); })(opt.anchor));
            col = self.resolveAnchorCol(anchor, width, availWidth, marginLeft);
        }
        if (opt.offsetY != None) {
            row += opt.offsetY;
        }
        if (opt.offsetX != None) {
            col += opt.offsetX;
        }
        row = max(float(marginTop), float(min(float(row), float(((termHeight - marginBottom) - effectiveHeight)))));
        col = max(float(marginLeft), float(min(float(col), float(((termWidth - marginRight) - width)))));
        return {"width": width, "row": row, "col": col, "maxHeight": maxHeight};
    }
    # JS2JAC-HOLE[E7205] Class method produced no output:
    # | private resolveAnchorRow(anchor: OverlayAnchor, height: number, availHeight: number, marginTop: number): number {
    # | 		switch (anchor) {
    # | 			case "top-left":
    # | 			case "top-center":
    # | 			case "top-right":
    # | 				return marginTop;
    # | 			case "bottom-left":
    # | 			case "bottom-center":
    # | 			case "bottom-right":
    # | 				return marginTop + availHeight - height;
    # | 			case "left-center":
    # | 			case "center":
    # | 			case "right-center":
    # | 				return marginTop + Math.floor((availHeight - height) / 2);
    # | 		}
    # | 	}
    # JS2JAC-HOLE[E7205] Class method produced no output:
    # | private resolveAnchorCol(anchor: OverlayAnchor, width: number, availWidth: number, marginLeft: number): number {
    # | 		switch (anchor) {
    # | 			case "top-left":
    # | 			case "left-center":
    # | 			case "bottom-left":
    # | 				return marginLeft;
    # | 			case "top-right":
    # | 			case "right-center":
    # | 			case "bottom-right":
    # | 				return marginLeft + availWidth - width;
    # | 			case "top-center":
    # | 			case "center":
    # | 			case "bottom-center":
    # | 				return marginLeft + Math.floor((availWidth - width) / 2);
    # | 		}
    # | 	}
    override def compositeOverlays(lines: list[str], termWidth: float, termHeight: float) -> list[str] {
        if (len(self.overlayStack) == 0) {
            return lines;
        }
        result = [*lines];
        rendered: list[dict[str, list[str] | float]] = [];
        minLinesNeeded = len(result);
        visibleEntries = [e for e in self.overlayStack if self.isOverlayVisible(e)];
        visibleEntries.sort(key=lambda (_jx_sort: any) -> any { return _jx_sort["focusOrder"]; });
        for entry_j in visibleEntries {
            _jx_d0: any = entry_j;
            component = _jx_d0.component;
            options = _jx_d0.options;
            _jx_d0: any = self.resolveOverlayLayout(options, 0, termWidth, termHeight);
            width = _jx_d0.width;
            maxHeight = _jx_d0.maxHeight;
            overlayLines = component.render(width);
            if ((maxHeight != None) and (len(overlayLines) > maxHeight)) {
                overlayLines = overlayLines[0:maxHeight];
            }
            _jx_d0: any = self.resolveOverlayLayout(options, len(overlayLines), termWidth, termHeight);
            row = _jx_d0.row;
            col = _jx_d0.col;
            rendered.append({"overlayLines": overlayLines, "row": row, "col": col, "w": width});
            minLinesNeeded = max(float(minLinesNeeded), float((row + len(overlayLines))));
        }
        workingHeight = max(float(len(result)), float(termHeight), float(minLinesNeeded));
        while (len(result) < workingHeight) {
            result.append("");
        }
        viewportStart = max(float(0), float((workingHeight - termHeight)));
        for _jx_item0 in rendered {
            overlayLines = _jx_item0.overlayLines;
            row = _jx_item0.row;
            col = _jx_item0.col;
            w = _jx_item0.w;
            i: int = 0;
            while (i < len(overlayLines)) {
                idx = ((viewportStart + row) + i);
                if ((idx >= 0) and (idx < len(result))) {
                    truncatedOverlayLine = (sliceByColumn(overlayLines[i], 0, w, True) if (visibleWidth(overlayLines[i]) > w) else overlayLines[i]);
                    result[idx] = self.compositeLineAt(result[idx], truncatedOverlayLine, col, w, termWidth);
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
    override def getKittyImageReservedRows(lines: list[str], index: float, maxIndex: any = (len(lines) - 1)) -> float {
        rows: float = float(extractKittyImageRows(((lambda (_jx_null31: any) -> any { return (_jx_null31 if _jx_null31 is not None else ""); })(lines[index]))));
        if (rows <= 1) {
            return 1;
        }
        maxRows = min(float(rows), float(((maxIndex - index) + 1)), float((len(lines) - index)));
        reservedRows = 1;
        while (reservedRows < maxRows) {
            line = ((lambda (_jx_null32: any) -> any { return (_jx_null32 if _jx_null32 is not None else ""); })(lines[(index + reservedRows)]));
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
        expandForLines = lambda (lines: list[str]) -> any { i: int = 0; while (i < len(lines)) {     if (len(extractKittyImageIds(lines[i])) == 0) {         continue;     }     blockEnd = ((i + self.getKittyImageReservedRows(lines, i)) - 1);     if ((i >= firstChanged) or ((i <= lastChanged) and (blockEnd >= firstChanged))) {         expandedFirstChanged = min(float(expandedFirstChanged), float(i));         expandedLastChanged = max(float(expandedLastChanged), float(blockEnd));     }     i += 1; } };
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
        i: int = firstChanged;
        while (i <= maxLine) {
            for id_j in extractKittyImageIds(((lambda (_jx_null33: any) -> any { return (_jx_null33 if _jx_null33 is not None else ""); })(self.previousLines[i]))) {
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
        beforePad = max(float(0), float((startCol - base.beforeWidth)));
        overlayPad = max(float(0), float((overlayWidth - overlay.width)));
        actualBeforeWidth = max(float(startCol), float(base.beforeWidth));
        actualOverlayWidth = max(float(overlayWidth), float(overlay.width));
        afterTarget = max(float(0), float(((totalWidth - actualBeforeWidth) - actualOverlayWidth)));
        afterPad = max(float(0), float((afterTarget - base.afterWidth)));
        r = SEGMENT_RESET;
        result = (((((((base.before + (" " * int(beforePad))) + r) + overlay.text) + (" " * int(overlayPad))) + r) + base.after) + (" " * int(afterPad)));
        resultWidth = visibleWidth(result);
        if (resultWidth <= totalWidth) {
            return result;
        }
        return sliceByColumn(result, 0, totalWidth, True);
    }
    override def extractCursorPosition(lines: list[str], height: float) -> dict[str, float] | None {
        viewportTop = max(float(0), float((len(lines) - height)));
        row: int = (len(lines) - 1);
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
        width = self.terminal.columns;
        height = self.terminal.rows;
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
        fullRender = lambda (clear: bool) -> any { self.fullRedrawCount += 1; buffer: str = "\u001b[?2026h"; if clear {     buffer += self.deleteKittyImages(self.previousKittyImageIds);     buffer += "\u001b[2J\u001b[H\u001b[3J"; } i: int = 0; while (i < len(newLines)) {     if (i > 0) {         buffer += "\r\n";     }     line = newLines[i];     isImage = isImageLine(line);     imageReservedRows = (self.getKittyImageReservedRows(newLines, i) if isImage else 1);     if ((imageReservedRows > 1) and (imageReservedRows <= height)) {         row: int = 1;         while (row < imageReservedRows) {             buffer += "\r\n";             row += 1;         }         buffer += f"\\x1b[{(imageReservedRows - 1)}A";         buffer += line;         buffer += f"\\x1b[{(imageReservedRows - 1)}B";         i += (imageReservedRows - 1);         continue;     }     buffer += line;     i += 1; } buffer += "\u001b[?2026l"; self.terminal.write(buffer); self.cursorRow = max(float(0), float((len(newLines) - 1))); self.hardwareCursorRow = self.cursorRow; if clear {     self.maxLinesRendered = len(newLines); } else {     self.maxLinesRendered = max(float(self.maxLinesRendered), float(len(newLines))); } bufferLength = max(float(height), float(len(newLines))); self.previousViewportTop = max(float(0), float((bufferLength - height))); self.positionHardwareCursor(cursorPos, len(newLines)); self.previousLines = newLines; self.previousKittyImageIds = self.collectKittyImageIds(newLines); self.previousWidth = width; self.previousHeight = height; };
        debugRedraw = (environ.get("PI_DEBUG_REDRAW") == "1");
        logRedraw = lambda (reason: str) -> any { if not debugRedraw {     return; } logPath = os.homedir().join(path); msg: str = f"[{Date().toISOString()}] fullRender: {reason} (prev={len(self.previousLines)}, new={len(newLines)}, height={height})\\n"; fs.appendFileSync(logPath, msg); };
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
            firstChanged = expandedRange.firstChanged;
            lastChanged = expandedRange.lastChanged;
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
                    buffer += f"\\x1b[{lineDiff}B";
                }
                elif (lineDiff < 0) {
                    buffer += f"\\x1b[{-lineDiff}A";
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
                    buffer += f"\\x1b[{clearStartOffset}B";
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
                    buffer += f"\\x1b[{moveBack}A";
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
                buffer += f"\\x1b[{moveToBottom}B";
            }
            scroll = (moveTargetRow - prevViewportBottom);
            buffer += ("\r\n" * int(scroll));
            prevViewportTop += scroll;
            viewportTop += scroll;
            hardwareCursorRow = moveTargetRow;
        }
        lineDiff = computeLineDiff(moveTargetRow);
        if (lineDiff > 0) {
            buffer += f"\\x1b[{lineDiff}B";
        }
        elif (lineDiff < 0) {
            buffer += f"\\x1b[{-lineDiff}A";
        }
        buffer += ("\r\n" if appendStart else "\r");
        renderEnd = min(float(lastChanged), float((len(newLines) - 1)));
        i: int = firstChanged;
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
                buffer += f"\\x1b[{(imageReservedRows - 1)}A";
                buffer += line;
                buffer += f"\\x1b[{(imageReservedRows - 1)}B";
                i += (imageReservedRows - 1);
                continue;
            }
            buffer += "\u001b[2K";
            if (not isImage and (visibleWidth(line) > width)) {
                crashLogPath = os.homedir().join(path);
                crashData = "\n".join([f"Crash at {Date().toISOString()}", f"Terminal width: {width}", f"Line {i} visible width: {visibleWidth(line)}", "", "=== All rendered lines ===", *newLines.map(lambda (l: any, idx: any) -> any { return f"[{idx}] (w={visibleWidth(l)}) {l}"; }), ""]);
                fs.mkdirSync(path.dirname(crashLogPath), {"recursive": True});
                fs.writeFileSync(crashLogPath, crashData);
                self.stop();
                errorMsg = "\n".join([f"Rendered line {i} exceeds terminal width ({visibleWidth(line)} > {width}).", "", "This is likely caused by a custom TUI component not truncating its output.", "Use visibleWidth() to measure and truncateToWidth() to truncate lines.", "", f"Debug log written to: {crashLogPath}"]);
                # JS2JAC-HOLE[E7230] ThrowStatement is not supported in V2 (deferred to a later slice):
                # | throw new Error(errorMsg);
            }
            buffer += line;
            i += 1;
        }
        finalCursorRow = renderEnd;
        if (len(self.previousLines) > len(newLines)) {
            if (renderEnd < (len(newLines) - 1)) {
                moveDown = ((len(newLines) - 1) - renderEnd);
                buffer += f"\\x1b[{moveDown}B";
                finalCursorRow = (len(newLines) - 1);
            }
            extraLines = (len(self.previousLines) - len(newLines));
            i: int = len(newLines);
            while (i < len(self.previousLines)) {
                buffer += "\r\n\u001b[2K";
                i += 1;
            }
            buffer += f"\\x1b[{extraLines}A";
        }
        buffer += "\u001b[?2026l";
        if (environ.get("PI_TUI_DEBUG") == "1") {
            debugDir: str = "/tmp/tui";
            fs.mkdirSync(debugDir, {"recursive": True});
            debugPath = debugDir.join(path);
            debugData = "\n".join([f"firstChanged: {firstChanged}", f"viewportTop: {viewportTop}", f"cursorRow: {self.cursorRow}", f"height: {height}", f"lineDiff: {lineDiff}", f"hardwareCursorRow: {hardwareCursorRow}", f"renderEnd: {renderEnd}", f"finalCursorRow: {finalCursorRow}", f"cursorPos: {JSON.stringify(cursorPos)}", f"newLines.length: {len(newLines)}", f"previousLines.length: {len(self.previousLines)}", "", "=== newLines ===", JSON.stringify(newLines, None, 2), "", "=== previousLines ===", JSON.stringify(self.previousLines, None, 2), "", "=== buffer ===", JSON.stringify(buffer)]);
            fs.writeFileSync(debugPath, debugData);
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
        targetRow = max(float(0), float(min(float(cursorPos.row), float((totalLines - 1)))));
        targetCol = max(float(0), float(cursorPos.col));
        rowDelta = (targetRow - self.hardwareCursorRow);
        buffer: str = "";
        if (rowDelta > 0) {
            buffer += f"\\x1b[{rowDelta}B";
        }
        elif (rowDelta < 0) {
            buffer += f"\\x1b[{-rowDelta}A";
        }
        buffer += f"\\x1b[{(targetCol + 1)}G";
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
    # JS2JAC-HOLE[E7232] Unsupported class method parameter form: ObjectPattern:
    # | queryTerminalBackgroundColor({ timeoutMs }: { timeoutMs: number }): Promise<RgbColor | undefined> {
    # | 		return new Promise((resolve) => {
    # | 			const query: PendingOsc11BackgroundQuery = {
    # | 				settled: false,
    # | 				resolve,
    # | 				timer: undefined,
    # | 			};
    # | 
    # | 			query.timer = setTimeout(() => {
    # | 				if (query.settled) {
    # | 					return;
    # | 				}
    # | 				query.settled = true;
    # | 				query.timer = undefined;
    # | 				query.resolve?.(undefined);
    # | 				query.resolve = undefined;
    # | 			}, timeoutMs);
    # | 			this.pendingOsc11BackgroundQueries.push(query);
    # | 			this.pendingOsc11BackgroundReplies += 1;
    # | 			this.terminal.write("\x1b]11;?\x07");
    # | 		});
    # | 	}
    # JS2JAC-HOLE[E7232] Unsupported class method parameter form: ObjectPattern:
    # | queryTerminalColorScheme({ timeoutMs }: { timeoutMs: number }): Promise<TerminalColorScheme | undefined> {
    # | 		return new Promise((resolve) => {
    # | 			let settled = false;
    # | 			let timer: NodeJS.Timeout | undefined;
    # | 			let unsubscribe: () => void = () => {};
    # | 			const settle = (scheme: TerminalColorScheme | undefined) => {
    # | 				if (settled) return;
    # | 				settled = true;
    # | 				if (timer) {
    # | 					clearTimeout(timer);
    # | 					timer = undefined;
    # | 				}
    # | 				unsubscribe();
    # | 				resolve(scheme);
    # | 			};
    # | 
    # | 			unsubscribe = this.onTerminalColorSchemeChange(settle);
    # | 			timer = setTimeout(() => settle(undefined), timeoutMs);
    # | 			this.terminal.write("\x1b[?996n");
    # | 		});
    # | 	}
}
