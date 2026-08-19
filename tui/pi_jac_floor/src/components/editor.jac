import from "../keybindings.jac" { getKeybindings }
import from "../keys.jac" { decodePrintableKey, matchesKey }
import from "../kill-ring.jac" { KillRing }
import from "../tui.jac" { CURSOR_MARKER }
import from "../undo-stack.jac" { UndoStack }
import from "../utils.jac" { cjkBreakRegex, getGraphemeSegmenter, getWordSegmenter, isWhitespaceChar, truncateToWidth, visibleWidth }
import from "../word-navigation.jac" { findWordBackward, findWordForward }
import from "./select-list.jac" { SelectList }
import from re { compile, search, sub }

glob graphemeSegmenter = getGraphemeSegmenter();

glob wordSegmenter = getWordSegmenter();

glob PASTE_MARKER_REGEX = compile(r"\[paste #(\d+)( (\+\d+ lines|\d+ chars))?\]");

glob PASTE_MARKER_SINGLE = compile(r"^\[paste #(\d+)( (\+\d+ lines|\d+ chars))?\]$");

def isPasteMarker(segment: str) -> bool {
    return ((len(segment) >= 10) and (search(PASTE_MARKER_SINGLE, segment) is not None));
}

def segmentWithMarkers(text: str, baseSegmenter: any, validIds: any) -> any {
    if ((validIds.size == 0) or not ("[paste #" in text)) {
        return baseSegmenter.segment(text);
    }
    markers: list[dict[str, float]] = [];
    for m in text.matchAll(PASTE_MARKER_REGEX) {
        id_j = int((m[1] as any), 10);
        if not validIds.has(id_j) {
            continue;
        }
        markers.append({"start": m.index, "end": (m.index + len(m[0]))});
    }
    if (len(markers) == 0) {
        return baseSegmenter.segment(text);
    }
    baseSegments = baseSegmenter.segment(text);
    result: list[any] = [];
    markerIdx = 0;
    for seg in baseSegments {
        while ((markerIdx < len(markers)) and ((markers[markerIdx] as any).end <= seg.index)) {
            markerIdx += 1;
        }
        marker = ((markers[markerIdx] as any) if (markerIdx < len(markers)) else None);
        if ((marker and (seg.index >= marker.start)) and (seg.index < marker.end)) {
            if (seg.index == marker.start) {
                markerText = text[marker.start:marker.end];
                result.append({"segment": markerText, "index": marker.start, "input": text});
            }
        }
        else {
            result.append(seg);
        }
    }
    return result;
}

def:pub wordWrapLine(line: str, maxWidth: float, preSegmented: list[any]) -> list[any] {
    if (not line or (maxWidth <= 0)) {
        return [{"text": "", "startIndex": 0, "endIndex": 0}];
    }
    lineWidth = visibleWidth(line);
    if (lineWidth <= maxWidth) {
        return [{"text": line, "startIndex": 0, "endIndex": len(line)}];
    }
    chunks: list[any] = [];
    segments = (preSegmented if preSegmented is not None else [*graphemeSegmenter.segment(line)]);
    currentWidth = 0;
    chunkStart: float = float(0);
    wrapOppIndex = -1;
    wrapOppWidth = 0;
    i: int = 0;
    while (i < len(segments)) {
        seg = (segments[i] as any);
        grapheme = seg.segment;
        gWidth = visibleWidth(grapheme);
        charIndex = seg.index;
        isWs = (not isPasteMarker(grapheme) and isWhitespaceChar(grapheme));
        if ((currentWidth + gWidth) > maxWidth) {
            if ((wrapOppIndex >= 0) and (((currentWidth - wrapOppWidth) + gWidth) <= maxWidth)) {
                chunks.append({"text": line[chunkStart:wrapOppIndex], "startIndex": chunkStart, "endIndex": wrapOppIndex});
                chunkStart = wrapOppIndex;
                currentWidth -= wrapOppWidth;
            }
            elif (chunkStart < charIndex) {
                chunks.append({"text": line[chunkStart:charIndex], "startIndex": chunkStart, "endIndex": charIndex});
                chunkStart = charIndex;
                currentWidth = 0;
            }
            wrapOppIndex = -1;
        }
        if (gWidth > maxWidth) {
            subChunks = wordWrapLine(grapheme, maxWidth);
            j: int = 0;
            while (j < (len(subChunks) - 1)) {
                sc = (subChunks[j] as any);
                chunks.append({"text": sc.text, "startIndex": (charIndex + sc.startIndex), "endIndex": (charIndex + sc.endIndex)});
                j += 1;
            }
            last = (subChunks[(len(subChunks) - 1)] as any);
            chunkStart = (charIndex + last.startIndex);
            currentWidth = visibleWidth(last.text);
            wrapOppIndex = -1;
            continue;
        }
        currentWidth += gWidth;
        next_j = segments[(i + 1)];
        if ((isWs and next_j) and (isPasteMarker(next_j.segment) or not isWhitespaceChar(next_j.segment))) {
            wrapOppIndex = next_j.index;
            wrapOppWidth = currentWidth;
        }
        elif ((not isWs and next_j) and not isWhitespaceChar(next_j.segment)) {
            isCjk = (not isPasteMarker(grapheme) and cjkBreakRegex.test(grapheme));
            nextIsCjk = (not isPasteMarker(next_j.segment) and cjkBreakRegex.test(next_j.segment));
            if (isCjk or nextIsCjk) {
                wrapOppIndex = next_j.index;
                wrapOppWidth = currentWidth;
            }
        }
        i += 1;
    }
    chunks.append({"text": line[chunkStart:], "startIndex": chunkStart, "endIndex": len(line)});
    return chunks;
}

glob SLASH_COMMAND_SELECT_LIST_LAYOUT: any = {"minPrimaryColumnWidth": 12, "maxPrimaryColumnWidth": 32};

glob ATTACHMENT_AUTOCOMPLETE_DEBOUNCE_MS = 20;

glob DEFAULT_AUTOCOMPLETE_TRIGGER_CHARACTERS = ["@", "#"];

def escapeCharacterClass(value: str) -> str {
    return sub(r"[\\^$.*+?()[\]{}|-]", "\\$&", value);
}

def buildTriggerPattern(triggerCharacters: list[str]) -> any {
    return RegExp(f"(?:^|[\\\\s])[{"".join(triggerCharacters.map(escapeCharacterClass))}][^\\\\s]*$");
}

def buildDebouncePattern(triggerCharacters: list[str]) -> any {
    escapedWithoutAt = [character for character in triggerCharacters if (character != "@")].map(escapeCharacterClass);
    return RegExp(f"(?:^|[ \\\\t])(?:@(?:\"[^\"]*|[^\\\\s]*)|[{"".join(escapedWithoutAt)}][^\\\\s]*)$");
}

obj:pub Editor {
    has tui: any;
    has theme: any;
    has borderColor: any;
    has autocompleteProvider: any | None = None;
    has autocompleteList: any | None = None;
    has autocompleteAbort: any | None = None;
    has autocompleteDebounceTimer: any | None = None;
    has onSubmit: any | None = None;
    has onChange: any | None = None;
    has state: any = {"lines": [""], "cursorLine": 0, "cursorCol": 0};
    has focused: bool = False;
    has paddingX: float = 0;
    has lastWidth: float = 80;
    has scrollOffset: float = 0;
    has autocompleteTriggerCharacters: list = [*DEFAULT_AUTOCOMPLETE_TRIGGER_CHARACTERS];
    has autocompleteTriggerPattern: any = buildTriggerPattern(self.autocompleteTriggerCharacters);
    has autocompleteDebouncePattern: any = buildDebouncePattern(self.autocompleteTriggerCharacters);
    has autocompleteState: any | None = None;
    has autocompletePrefix: str = "";
    has autocompleteMaxVisible: float = 5;
    has autocompleteRequestTask: any = Promise.resolve();
    has autocompleteStartToken: float = 0;
    has autocompleteRequestId: float = 0;
    has pastes: any = {};
    has pasteCounter: float = 0;
    has pasteBuffer: str = "";
    has isInPaste: bool = False;
    has history: list[str] = [];
    has historyIndex: float = -1;
    has historyDraft: any | None = None;
    has killRing: any = KillRing();
    has lastAction: any | None = None;
    has jumpMode: any | None = None;
    has preferredVisualCol: float | None = None;
    has snappedFromCursorCol: float | None = None;
    has undoStack: any = UndoStack();
    has disableSubmit: bool = False;
    def __init__(tui: any, theme: any, options: any = {}) -> None {
        self.tui = tui;
        self.theme = theme;
        self.borderColor = theme.borderColor;
        paddingX = (options.paddingX if options.paddingX is not None else 0);
        self.paddingX = (max(float(0), float(int((paddingX) // 1))) if Number.isFinite(paddingX) else 0);
        maxVisible = (options.autocompleteMaxVisible if options.autocompleteMaxVisible is not None else 5);
        self.autocompleteMaxVisible = (max(float(3), float(min(float(20), float(int((maxVisible) // 1))))) if Number.isFinite(maxVisible) else 5);
    }
    def validPasteIds() -> any {
        return set(self.pastes.keys());
    }
    def segment(text: str, mode: any) -> any {
        return segmentWithMarkers(text, (wordSegmenter if (mode == "word") else graphemeSegmenter), self.validPasteIds());
    }
    def getPaddingX() -> float {
        return self.paddingX;
    }
    def setPaddingX(padding: float) -> None {
        newPadding = (max(float(0), float(int((padding) // 1))) if Number.isFinite(padding) else 0);
        if (self.paddingX != newPadding) {
            self.paddingX = newPadding;
            self.tui.requestRender();
        }
    }
    def getAutocompleteMaxVisible() -> float {
        return self.autocompleteMaxVisible;
    }
    def setAutocompleteMaxVisible(maxVisible: float) -> None {
        newMaxVisible = (max(float(3), float(min(float(20), float(int((maxVisible) // 1))))) if Number.isFinite(maxVisible) else 5);
        if (self.autocompleteMaxVisible != newMaxVisible) {
            self.autocompleteMaxVisible = newMaxVisible;
            self.tui.requestRender();
        }
    }
    def setAutocompleteProvider(provider: any) -> None {
        self.cancelAutocomplete();
        self.autocompleteProvider = provider;
        self.setAutocompleteTriggerCharacters((provider.triggerCharacters if provider.triggerCharacters is not None else []));
    }
    def addToHistory(text: str) -> None {
        trimmed: str = text.strip();
        if not trimmed {
            return;
        }
        if ((len(self.history) > 0) and (self.history[0] == trimmed)) {
            return;
        }
        self.history.unshift(trimmed);
        if (len(self.history) > 100) {
            self.history.pop();
        }
    }
    def isEditorEmpty() -> bool {
        return ((len(self.state.lines) == 1) and (self.state.lines[0] == ""));
    }
    def isOnFirstVisualLine() -> bool {
        visualLines = self.buildVisualLineMap(self.lastWidth);
        currentVisualLine = self.findCurrentVisualLine(visualLines);
        return (currentVisualLine == 0);
    }
    def isOnLastVisualLine() -> bool {
        visualLines = self.buildVisualLineMap(self.lastWidth);
        currentVisualLine = self.findCurrentVisualLine(visualLines);
        return (currentVisualLine == (len(visualLines) - 1));
    }
    def navigateHistory(direction: any) -> None {
        self.lastAction = None;
        if (len(self.history) == 0) {
            return;
        }
        newIndex = (self.historyIndex - direction);
        if ((newIndex < -1) or (newIndex >= len(self.history))) {
            return;
        }
        if ((self.historyIndex == -1) and (newIndex >= 0)) {
            self.pushUndoSnapshot();
            self.historyDraft = structuredClone(self.state);
        }
        self.historyIndex = newIndex;
        if (self.historyIndex == -1) {
            draft = self.historyDraft;
            self.historyDraft = None;
            if draft {
                self.state = draft;
                self.preferredVisualCol = None;
                self.snappedFromCursorCol = None;
                self.scrollOffset = 0;
                if self.onChange {
                    self.onChange(self.getText());
                }
            }
            else {
                self.setTextInternal("");
            }
        }
        else {
            self.setTextInternal((self.history[self.historyIndex] or ""), ("start" if (direction == -1) else "end"));
        }
    }
    def exitHistoryBrowsing() -> None {
        self.historyIndex = -1;
        self.historyDraft = None;
    }
    def setTextInternal(text: str, cursorPlacement: any = "end") -> None {
        lines = text.split("\n");
        self.state.lines = ([""] if (len(lines) == 0) else lines);
        self.state.cursorLine = (0 if (cursorPlacement == "start") else (len(self.state.lines) - 1));
        self.setCursorCol((0 if (cursorPlacement == "start") else ((len(self.state.lines[self.state.cursorLine]) if self.state.lines[self.state.cursorLine] is not None else None) or 0)));
        self.scrollOffset = 0;
        if self.onChange {
            self.onChange(self.getText());
        }
    }
    def invalidate() -> None {
    }
    def render(width: float) -> list[str] {
        maxPadding = max(float(0), float(int((((width - 1) / 2)) // 1)));
        paddingX = min(float(self.paddingX), float(maxPadding));
        contentWidth = max(float(1), float((width - (paddingX * 2))));
        layoutWidth = max(float(1), float((contentWidth - (0 if paddingX else 1))));
        self.lastWidth = layoutWidth;
        horizontal = self.borderColor("─");
        layoutLines = self.layoutText(layoutWidth);
        terminalRows = self.tui.terminal.rows;
        maxVisibleLines = max(float(5), float(int(((terminalRows * 0.3)) // 1)));
        cursorLineIndex = layoutLines.findIndex(lambda (line: any) -> any { return line.hasCursor; });
        if (cursorLineIndex == -1) {
            cursorLineIndex = 0;
        }
        if (cursorLineIndex < self.scrollOffset) {
            self.scrollOffset = cursorLineIndex;
        }
        elif (cursorLineIndex >= (self.scrollOffset + maxVisibleLines)) {
            self.scrollOffset = ((cursorLineIndex - maxVisibleLines) + 1);
        }
        maxScrollOffset = max(float(0), float((len(layoutLines) - maxVisibleLines)));
        self.scrollOffset = max(float(0), float(min(float(self.scrollOffset), float(maxScrollOffset))));
        visibleLines = layoutLines[self.scrollOffset:(self.scrollOffset + maxVisibleLines)];
        result: list[str] = [];
        leftPadding = (" " * int(paddingX));
        rightPadding = leftPadding;
        # JS2JAC-HOLE[E7214]:
        # | if (this.scrollOffset > 0) {
        # | 			const indicator = `─── ↑ ${this.scrollOffset} more `;
        # | 			const remaining = width - visibleWidth(indicator);
        # | 			if (remaining >= 0) {
        # | 				result.push(this.borderColor(indicator + "─".repeat(remaining)));
        # | 			} else {
        # | 				result.push(this.borderColor(truncateToWidth(indicator, width)));
        # | 			}
        # | 		} else {
        # | 			result.push(horizontal.repeat(width));
        # | 		}
        emitCursorMarker = self.focused;
        for layoutLine in visibleLines {
            displayText = layoutLine.text;
            lineVisibleWidth = visibleWidth(layoutLine.text);
            cursorInPadding: bool = False;
            if (layoutLine.hasCursor and (layoutLine.cursorPos != None)) {
                before = displayText[0:layoutLine.cursorPos];
                after = displayText[layoutLine.cursorPos:];
                marker = (CURSOR_MARKER if emitCursorMarker else "");
                if (len(after) > 0) {
                    afterGraphemes = [*self.segment(after, "grapheme")];
                    firstGrapheme = ((afterGraphemes[0].segment if afterGraphemes[0] is not None else None) or "");
                    restAfter = after[len(firstGrapheme):];
                    cursor: str = f"\\x1b[7m{firstGrapheme}\\x1b[0m";
                    displayText = (((before + marker) + cursor) + restAfter);
                }
                else {
                    cursor: str = "\u001b[7m \u001b[0m";
                    displayText = ((before + marker) + cursor);
                    lineVisibleWidth = (lineVisibleWidth + 1);
                    if ((lineVisibleWidth > contentWidth) and (paddingX > 0)) {
                        cursorInPadding = True;
                    }
                }
            }
            padding = (" " * int(max(float(0), float((contentWidth - lineVisibleWidth)))));
            lineRightPadding = (rightPadding[1:] if cursorInPadding else rightPadding);
            result.append(f"{leftPadding}{displayText}{padding}{lineRightPadding}");
        }
        linesBelow = (len(layoutLines) - (self.scrollOffset + len(visibleLines)));
        if (linesBelow > 0) {
            indicator: str = f"─── ↓ {linesBelow} more ";
            remaining = (width - visibleWidth(indicator));
            result.append(self.borderColor((indicator + ("─" * int(max(float(0), float(remaining)))))));
        }
        else {
            result.append((horizontal * int(width)));
        }
        if (self.autocompleteState and self.autocompleteList) {
            autocompleteResult = self.autocompleteList.render(contentWidth);
            for line in autocompleteResult {
                lineWidth = visibleWidth(line);
                linePadding = (" " * int(max(float(0), float((contentWidth - lineWidth)))));
                result.append(f"{leftPadding}{line}{linePadding}{rightPadding}");
            }
        }
        return result;
    }
    # JS2JAC-HOLE[E7205] Class method produced no output:
    # | handleInput(data: string): void {
    # | 		const kb = getKeybindings();
    # | 
    # | 		// Handle character jump mode (awaiting next character to jump to)
    # | 		if (this.jumpMode !== null) {
    # | 			// Cancel if the hotkey is pressed again
    # | 			if (kb.matches(data, "tui.editor.jumpForward") || kb.matches(data, "tui.editor.jumpBackward")) {
    # | 				this.jumpMode = null;
    # | 				return;
    # | 			}
    # | 
    # | 			const printable = decodePrintableKey(data) ?? (data.charCodeAt(0) >= 32 ? data : undefined);
    # | 			if (printable !== undefined) {
    # | 				// Printable character - perform the jump
    # | 				const direction = this.jumpMode;
    # | 				this.jumpMode = null;
    # | 				this.jumpToChar(printable, direction);
    # | 				return;
    # | 			}
    # | 
    # | 			// Control character - cancel and fall through to normal handling
    # | 			this.jumpMode = null;
    # | 		}
    # | 
    # | 		// Handle bracketed paste mode
    # | 		if (data.includes("\x1b[200~")) {
    # | 			this.isInPaste = true;
    # | 			this.pasteBuffer = "";
    # | 			data = data.replace("\x1b[200~", "");
    # | 		}
    # | 
    # | 		if (this.isInPaste) {
    # | 			this.pasteBuffer += data;
    # | 			const endIndex = this.pasteBuffer.indexOf("\x1b[201~");
    # | 			if (endIndex !== -1) {
    # | 				const pasteContent = this.pasteBuffer.substring(0, endIndex);
    # | 				if (pasteContent.length > 0) {
    # | 					this.handlePaste(pasteContent);
    # | 				}
    # | 				this.isInPaste = false;
    # | 				const remaining = this.pasteBuffer.substring(endIndex + 6);
    # | 				this.pasteBuffer = "";
    # | 				if (remaining.length > 0) {
    # | 					this.handleInput(remaining);
    # | 				}
    # | 				return;
    # | 			}
    # | 			return;
    # | 		}
    # | 
    # | 		// Ctrl+C - let parent handle (exit/clear)
    # | 		if (kb.matches(data, "tui.input.copy")) {
    # | 			return;
    # | 		}
    # | 
    # | 		// Undo
    # | 		if (kb.matches(data, "tui.editor.undo")) {
    # | 			this.undo();
    # | 			return;
    # | 		}
    # | 
    # | 		// Handle autocomplete mode
    # | 		if (this.autocompleteState && this.autocompleteList) {
    # | 			if (kb.matches(data, "tui.select.cancel")) {
    # | 				this.cancelAutocomplete();
    # | 				return;
    # | 			}
    # | 
    # | 			if (kb.matches(data, "tui.select.up") || kb.matches(data, "tui.select.down")) {
    # | 				this.autocompleteList.handleInput(data);
    # | 				return;
    # | 			}
    # | 
    # | 			if (kb.matches(data, "tui.input.tab")) {
    # | 				const selected = this.autocompleteList.getSelectedItem();
    # | 				if (selected && this.autocompleteProvider) {
    # | 					this.pushUndoSnapshot();
    # | 					this.lastAction = null;
    # | 					const result = this.autocompleteProvider.applyCompletion(
    # | 						this.state.lines,
    # | 						this.state.cursorLine,
    # | 						this.state.cursorCol,
    # | 						selected,
    # | 						this.autocompletePrefix,
    # | 					);
    # | 					this.state.lines = result.lines;
    # | 					this.state.cursorLine = result.cursorLine;
    # | 					this.setCursorCol(result.cursorCol);
    # | 					this.cancelAutocomplete();
    # | 					if (this.onChange) this.onChange(this.getText());
    # | 				}
    # | 				return;
    # | 			}
    # | 
    # | 			if (kb.matches(data, "tui.select.confirm")) {
    # | 				const selected = this.autocompleteList.getSelectedItem();
    # | 				if (selected && this.autocompleteProvider) {
    # | 					this.pushUndoSnapshot();
    # | 					this.lastAction = null;
    # | 					const result = this.autocompleteProvider.applyCompletion(
    # | 						this.state.lines,
    # | 						this.state.cursorLine,
    # | 						this.state.cursorCol,
    # | 						selected,
    # | 						this.autocompletePrefix,
    # | 					);
    # | 					this.state.lines = result.lines;
    # | 					this.state.cursorLine = result.cursorLine;
    # | 					this.setCursorCol(result.cursorCol);
    # | 
    # | 					if (this.autocompletePrefix.startsWith("/")) {
    # | 						this.cancelAutocomplete();
    # | 						// Fall through to submit
    # | 					} else {
    # | 						this.cancelAutocomplete();
    # | 						if (this.onChange) this.onChange(this.getText());
    # | 						return;
    # | 					}
    # | 				}
    # | 			}
    # | 		}
    # | 
    # | 		// Tab - trigger completion
    # | 		if (kb.matches(data, "tui.input.tab") && !this.autocompleteState) {
    # | 			this.handleTabCompletion();
    # | 			return;
    # | 		}
    # | 
    # | 		// Deletion actions
    # | 		if (kb.matches(data, "tui.editor.deleteToLineEnd")) {
    # | 			this.deleteToEndOfLine();
    # | 			return;
    # | 		}
    # | 		if (kb.matches(data, "tui.editor.deleteToLineStart")) {
    # | 			this.deleteToStartOfLine();
    # | 			return;
    # | 		}
    # | 		if (kb.matches(data, "tui.editor.deleteWordBackward")) {
    # | 			this.deleteWordBackwards();
    # | 			return;
    # | 		}
    # | 		if (kb.matches(data, "tui.editor.deleteWordForward")) {
    # | 			this.deleteWordForward();
    # | 			return;
    # | 		}
    # | 		if (kb.matches(data, "tui.editor.deleteCharBackward") || matchesKey(data, "shift+backspace")) {
    # | 			this.handleBackspace();
    # | 			return;
    # | 		}
    # | 		if (kb.matches(data, "tui.editor.deleteCharForward") || matchesKey(data, "shift+delete")) {
    # | 			this.handleForwardDelete();
    # | 			return;
    # | 		}
    # | 
    # | 		// Kill ring actions
    # | 		if (kb.matches(data, "tui.editor.yank")) {
    # | 			this.yank();
    # | 			return;
    # | 		}
    # | 		if (kb.matches(data, "tui.editor.yankPop")) {
    # | 			this.yankPop();
    # | 			return;
    # | 		}
    # | 
    # | 		// Cursor movement actions
    # | 		if (kb.matches(data, "tui.editor.cursorLineStart")) {
    # | 			this.moveToLineStart();
    # | 			return;
    # | 		}
    # | 		if (kb.matches(data, "tui.editor.cursorLineEnd")) {
    # | 			this.moveToLineEnd();
    # | 			return;
    # | 		}
    # | 		if (kb.matches(data, "tui.editor.cursorWordLeft")) {
    # | 			this.moveWordBackwards();
    # | 			return;
    # | 		}
    # | 		if (kb.matches(data, "tui.editor.cursorWordRight")) {
    # | 			this.moveWordForwards();
    # | 			return;
    # | 		}
    # | 
    # | 		// New line
    # | 		if (
    # | 			kb.matches(data, "tui.input.newLine") ||
    # | 			(data.charCodeAt(0) === 10 && data.length > 1) ||
    # | 			data === "\x1b\r" ||
    # | 			data === "\x1b[13;2~" ||
    # | 			(data.length > 1 && data.includes("\x1b") && data.includes("\r")) ||
    # | 			(data === "\n" && data.length === 1)
    # | 		) {
    # | 			if (this.shouldSubmitOnBackslashEnter(data, kb)) {
    # | 				this.handleBackspace();
    # | 				this.submitValue();
    # | 				return;
    # | 			}
    # | 			this.addNewLine();
    # | 			return;
    # | 		}
    # | 
    # | 		// Submit (Enter)
    # | 		if (kb.matches(data, "tui.input.submit")) {
    # | 			if (this.disableSubmit) return;
    # | 
    # | 			// Workaround for terminals without Shift+Enter support:
    # | 			// If char before cursor is \, delete it and insert newline instead of submitting.
    # | 			const currentLine = this.state.lines[this.state.cursorLine] || "";
    # | 			if (this.state.cursorCol > 0 && currentLine[this.state.cursorCol - 1] === "\\") {
    # | 				this.handleBackspace();
    # | 				this.addNewLine();
    # | 				return;
    # | 			}
    # | 
    # | 			this.submitValue();
    # | 			return;
    # | 		}
    # | 
    # | 		// Arrow key navigation (with history support)
    # | 		if (kb.matches(data, "tui.editor.cursorUp")) {
    # | 			if (
    # | 				this.isOnFirstVisualLine() &&
    # | 				(this.isEditorEmpty() || this.historyIndex > -1 || this.state.cursorCol === 0)
    # | 			) {
    # | 				this.navigateHistory(-1);
    # | 			} else if (this.isOnFirstVisualLine()) {
    # | 				// Already at top - jump to start of line
    # | 				this.moveToLineStart();
    # | 			} else {
    # | 				this.moveCursor(-1, 0);
    # | 			}
    # | 			return;
    # | 		}
    # | 		if (kb.matches(data, "tui.editor.cursorDown")) {
    # | 			if (this.historyIndex > -1 && this.isOnLastVisualLine()) {
    # | 				this.navigateHistory(1);
    # | 			} else if (this.isOnLastVisualLine()) {
    # | 				// Already at bottom - jump to end of line
    # | 				this.moveToLineEnd();
    # | 			} else {
    # | 				this.moveCursor(1, 0);
    # | 			}
    # | 			return;
    # | 		}
    # | 		if (kb.matches(data, "tui.editor.cursorRight")) {
    # | 			this.moveCursor(0, 1);
    # | 			return;
    # | 		}
    # | 		if (kb.matches(data, "tui.editor.cursorLeft")) {
    # | 			this.moveCursor(0, -1);
    # | 			return;
    # | 		}
    # | 
    # | 		// Page up/down - scroll by page and move cursor
    # | 		if (kb.matches(data, "tui.editor.pageUp")) {
    # | 			this.pageScroll(-1);
    # | 			return;
    # | 		}
    # | 		if (kb.matches(data, "tui.editor.pageDown")) {
    # | 			this.pageScroll(1);
    # | 			return;
    # | 		}
    # | 
    # | 		// Character jump mode triggers
    # | 		if (kb.matches(data, "tui.editor.jumpForward")) {
    # | 			this.jumpMode = "forward";
    # | 			return;
    # | 		}
    # | 		if (kb.matches(data, "tui.editor.jumpBackward")) {
    # | 			this.jumpMode = "backward";
    # | 			return;
    # | 		}
    # | 
    # | 		// Shift+Space - insert regular space
    # | 		if (matchesKey(data, "shift+space")) {
    # | 			this.insertCharacter(" ");
    # | 			return;
    # | 		}
    # | 
    # | 		const printable = decodePrintableKey(data);
    # | 		if (printable !== undefined) {
    # | 			this.insertCharacter(printable);
    # | 			return;
    # | 		}
    # | 
    # | 		// Regular characters
    # | 		if (data.charCodeAt(0) >= 32) {
    # | 			this.insertCharacter(data);
    # | 		}
    # | 	}
    def layoutText(contentWidth: float) -> list[any] {
        layoutLines: list[any] = [];
        if ((len(self.state.lines) == 0) or ((len(self.state.lines) == 1) and (self.state.lines[0] == ""))) {
            layoutLines.append({"text": "", "hasCursor": True, "cursorPos": 0});
            return layoutLines;
        }
        i: int = 0;
        while (i < len(self.state.lines)) {
            line = (self.state.lines[i] or "");
            isCurrentLine = (i == self.state.cursorLine);
            lineVisibleWidth = visibleWidth(line);
            if (lineVisibleWidth <= contentWidth) {
                if isCurrentLine {
                    layoutLines.append({"text": line, "hasCursor": True, "cursorPos": self.state.cursorCol});
                }
                else {
                    layoutLines.append({"text": line, "hasCursor": False});
                }
            }
            else {
                chunks = wordWrapLine(line, contentWidth, [*self.segment(line, "grapheme")]);
                chunkIndex: int = 0;
                while (chunkIndex < len(chunks)) {
                    chunk = chunks[chunkIndex];
                    if not chunk {
                        continue;
                    }
                    cursorPos = self.state.cursorCol;
                    isLastChunk = (chunkIndex == (len(chunks) - 1));
                    hasCursorInChunk: bool = False;
                    adjustedCursorPos: float = float(0);
                    if isCurrentLine {
                        if isLastChunk {
                            hasCursorInChunk = (cursorPos >= chunk.startIndex);
                            adjustedCursorPos = (cursorPos - chunk.startIndex);
                        }
                        else {
                            hasCursorInChunk = ((cursorPos >= chunk.startIndex) and (cursorPos < chunk.endIndex));
                            if hasCursorInChunk {
                                adjustedCursorPos = (cursorPos - chunk.startIndex);
                                if (adjustedCursorPos > len(chunk.text)) {
                                    adjustedCursorPos = len(chunk.text);
                                }
                            }
                        }
                    }
                    if hasCursorInChunk {
                        layoutLines.append({"text": chunk.text, "hasCursor": True, "cursorPos": adjustedCursorPos});
                    }
                    else {
                        layoutLines.append({"text": chunk.text, "hasCursor": False});
                    }
                    chunkIndex += 1;
                }
            }
            i += 1;
        }
        return layoutLines;
    }
    def getText() -> str {
        return "\n".join(self.state.lines);
    }
    def expandPasteMarkers(text: str) -> str {
        result = text;
        for _jx_item0 in self.pastes {
            pasteId = _jx_item0[0];
            pasteContent = _jx_item0[1];
            markerRegex = RegExp(f"\\\\[paste #{pasteId}( (\\\\+\\\\d+ lines|\\\\d+ chars))?\\\\]", "g");
            result = result.replace(markerRegex, lambda () -> any { return pasteContent; });
        }
        return result;
    }
    def getExpandedText() -> str {
        return self.expandPasteMarkers("\n".join(self.state.lines));
    }
    def getLines() -> list[str] {
        return [*self.state.lines];
    }
    def getCursor() -> dict[str, float] {
        return {"line": self.state.cursorLine, "col": self.state.cursorCol};
    }
    def setText(text: str) -> None {
        self.cancelAutocomplete();
        self.lastAction = None;
        self.exitHistoryBrowsing();
        self.pastes.clear();
        self.pasteCounter = 0;
        normalized = self.normalizeText(text);
        if (self.getText() != normalized) {
            self.pushUndoSnapshot();
        }
        self.setTextInternal(normalized);
    }
    def insertTextAtCursor(text: str) -> None {
        if not text {
            return;
        }
        self.cancelAutocomplete();
        self.pushUndoSnapshot();
        self.lastAction = None;
        self.exitHistoryBrowsing();
        self.insertTextAtCursorInternal(text);
    }
    def normalizeText(text: str) -> str {
        return text.replace("\r\n", "\n").replace("\r", "\n").replace("\t", "    ");
    }
    def insertTextAtCursorInternal(text: str) -> None {
        if not text {
            return;
        }
        normalized = self.normalizeText(text);
        insertedLines = normalized.split("\n");
        currentLine = (self.state.lines[self.state.cursorLine] or "");
        beforeCursor = currentLine[0:self.state.cursorCol];
        afterCursor = currentLine[self.state.cursorCol:];
        if (len(insertedLines) == 1) {
            self.state.lines[self.state.cursorLine] = ((beforeCursor + normalized) + afterCursor);
            self.setCursorCol((self.state.cursorCol + len(normalized)));
        }
        else {
            self.state.lines = [*self.state.lines[0:self.state.cursorLine], (beforeCursor + insertedLines[0]), *insertedLines[1:-1], (insertedLines[(len(insertedLines) - 1)] + afterCursor), *self.state.lines[(self.state.cursorLine + 1):]];
            self.state.cursorLine += (len(insertedLines) - 1);
            self.setCursorCol(len((insertedLines[(len(insertedLines) - 1)] or "")));
        }
        if self.onChange {
            self.onChange(self.getText());
        }
    }
    def insertCharacter(char: str, skipUndoCoalescing: bool | None = None) -> None {
        self.exitHistoryBrowsing();
        if not skipUndoCoalescing {
            if (isWhitespaceChar(char) or (self.lastAction != "type-word")) {
                self.pushUndoSnapshot();
            }
            self.lastAction = "type-word";
        }
        line = (self.state.lines[self.state.cursorLine] or "");
        before = line[0:self.state.cursorCol];
        after = line[self.state.cursorCol:];
        self.state.lines[self.state.cursorLine] = ((before + char) + after);
        self.setCursorCol((self.state.cursorCol + len(char)));
        if self.onChange {
            self.onChange(self.getText());
        }
        if not self.autocompleteState {
            if ((char == "/") and self.isAtStartOfMessage()) {
                self.tryTriggerAutocomplete();
            }
            elif (char in self.autocompleteTriggerCharacters) {
                currentLine = (self.state.lines[self.state.cursorLine] or "");
                textBeforeCursor = currentLine[0:self.state.cursorCol];
                charBeforeSymbol = textBeforeCursor[(len(textBeforeCursor) - 2)];
                if (((len(textBeforeCursor) == 1) or (charBeforeSymbol == " ")) or (charBeforeSymbol == "\t")) {
                    self.tryTriggerAutocomplete();
                }
            }
            elif (search(r"[a-zA-Z0-9.\-_]", char) is not None) {
                currentLine = (self.state.lines[self.state.cursorLine] or "");
                textBeforeCursor = currentLine[0:self.state.cursorCol];
                if self.isInSlashCommandContext(textBeforeCursor) {
                    self.tryTriggerAutocomplete();
                }
                elif self.autocompleteTriggerPattern.test(textBeforeCursor) {
                    self.tryTriggerAutocomplete();
                }
            }
        }
        else {
            self.updateAutocomplete();
        }
    }
    def handlePaste(pastedText: str) -> None {
        self.cancelAutocomplete();
        self.exitHistoryBrowsing();
        self.lastAction = None;
        self.pushUndoSnapshot();
        decodedText = sub(r"\x1b\[(\d+);5u", lambda (match_j: any, code: any) -> any { cp = Number(code); if ((cp >= 97) and (cp <= 122)) {     return String.fromCharCode((cp - 96)); } if ((cp >= 65) and (cp <= 90)) {     return String.fromCharCode((cp - 64)); } return match_j; }, pastedText);
        cleanText = self.normalizeText(decodedText);
        filteredText = "".join([char for char in cleanText.split("") if ((char == "\n") or (ord(char[0]) >= 32))]);
        if (search(r"^[/~.]", filteredText) is not None) {
            currentLine = (self.state.lines[self.state.cursorLine] or "");
            charBeforeCursor = (currentLine[(self.state.cursorCol - 1)] if (self.state.cursorCol > 0) else "");
            if (charBeforeCursor and (search(r"\w", charBeforeCursor) is not None)) {
                filteredText = f" {filteredText}";
            }
        }
        pastedLines = filteredText.split("\n");
        totalChars = len(filteredText);
        if ((len(pastedLines) > 10) or (totalChars > 1000)) {
            self.pasteCounter += 1;
            pasteId = self.pasteCounter;
            self.pastes.set(pasteId, filteredText);
            marker = (f"[paste #{pasteId} +{len(pastedLines)} lines]" if (len(pastedLines) > 10) else f"[paste #{pasteId} {totalChars} chars]");
            self.insertTextAtCursorInternal(marker);
            return;
        }
        if (len(pastedLines) == 1) {
            self.insertTextAtCursorInternal(filteredText);
            return;
        }
        self.insertTextAtCursorInternal(filteredText);
    }
    def addNewLine() -> None {
        self.cancelAutocomplete();
        self.exitHistoryBrowsing();
        self.lastAction = None;
        self.pushUndoSnapshot();
        currentLine = (self.state.lines[self.state.cursorLine] or "");
        before = currentLine[0:self.state.cursorCol];
        after = currentLine[self.state.cursorCol:];
        self.state.lines[self.state.cursorLine] = before;
        # JS2JAC-HOLE[E7215] splice is supported only as a discard-result statement:
        # | this.state.lines.splice(this.state.cursorLine + 1, 0, after);
        self.state.cursorLine += 1;
        self.setCursorCol(0);
        if self.onChange {
            self.onChange(self.getText());
        }
    }
    def shouldSubmitOnBackslashEnter(data: str, kb: any) -> bool {
        if self.disableSubmit {
            return False;
        }
        if not matchesKey(data, "enter") {
            return False;
        }
        submitKeys = kb.getKeys("tui.input.submit");
        hasShiftEnter = (("shift+enter" in submitKeys) or ("shift+return" in submitKeys));
        if not hasShiftEnter {
            return False;
        }
        currentLine = (self.state.lines[self.state.cursorLine] or "");
        return ((self.state.cursorCol > 0) and (currentLine[(self.state.cursorCol - 1)] == "\\"));
    }
    def submitValue() -> None {
        self.cancelAutocomplete();
        result: str = self.expandPasteMarkers("\n".join(self.state.lines)).strip();
        self.state = {"lines": [""], "cursorLine": 0, "cursorCol": 0};
        self.pastes.clear();
        self.pasteCounter = 0;
        self.exitHistoryBrowsing();
        self.scrollOffset = 0;
        self.undoStack.clear();
        self.lastAction = None;
        if self.onChange {
            self.onChange("");
        }
        if self.onSubmit {
            self.onSubmit(result);
        }
    }
    def handleBackspace() -> None {
        self.exitHistoryBrowsing();
        self.lastAction = None;
        if (self.state.cursorCol > 0) {
            self.pushUndoSnapshot();
            line = (self.state.lines[self.state.cursorLine] or "");
            beforeCursor = line[0:self.state.cursorCol];
            graphemes = [*self.segment(beforeCursor, "grapheme")];
            lastGrapheme = graphemes[(len(graphemes) - 1)];
            graphemeLength = (len(lastGrapheme.segment) if lastGrapheme else 1);
            isPastedSegmented = PASTE_MARKER_SINGLE.exec(lastGrapheme.segment);
            if isPastedSegmented {
                targetId = Number(isPastedSegmented[1]);
                self.pastes.delete(targetId);
                self.pasteCounter += -1;
                # JS2JAC-HOLE[E7215] nullish-coalescing left operand must be side-effect-free:
                # | this.state.lines = this.state.lines.map((line) =>
                # | 					line.replace(PASTE_MARKER_REGEX, (fullMatch, idGroup, suffixGroup) => {
                # | 						const x = Number(idGroup);
                # | 						if (x <= targetId) return fullMatch;
                # | 
                # | 						// [paste #3] become [paste #2] if we remove [paste #1]
                # | 						const newText = `[paste #${x - 1}${suffixGroup}]`;
                # | 						this.pastes.set(x - 1, this.pastes.get(x) ?? newText);
                # | 						this.pastes.delete(x);
                # | 						return newText;
                # | 					}),
                # | 				);
            }
            line = (self.state.lines[self.state.cursorLine] or "");
            before = line[0:(self.state.cursorCol - graphemeLength)];
            after = line[self.state.cursorCol:];
            self.state.lines[self.state.cursorLine] = (before + after);
            self.setCursorCol((self.state.cursorCol - graphemeLength));
        }
        elif (self.state.cursorLine > 0) {
            self.pushUndoSnapshot();
            currentLine = (self.state.lines[self.state.cursorLine] or "");
            previousLine = (self.state.lines[(self.state.cursorLine - 1)] or "");
            self.state.lines[(self.state.cursorLine - 1)] = (previousLine + currentLine);
            del self.state.lines[self.state.cursorLine];
            self.state.cursorLine += -1;
            self.setCursorCol(len(previousLine));
        }
        if self.onChange {
            self.onChange(self.getText());
        }
        if self.autocompleteState {
            self.updateAutocomplete();
        }
        else {
            currentLine = (self.state.lines[self.state.cursorLine] or "");
            textBeforeCursor = currentLine[0:self.state.cursorCol];
            if self.isInSlashCommandContext(textBeforeCursor) {
                self.tryTriggerAutocomplete();
            }
            elif self.autocompleteTriggerPattern.test(textBeforeCursor) {
                self.tryTriggerAutocomplete();
            }
        }
    }
    def setCursorCol(col: float) -> None {
        self.state.cursorCol = col;
        self.preferredVisualCol = None;
        self.snappedFromCursorCol = None;
    }
    def moveToVisualLine(visualLines: list[dict[str, float]], currentVisualLine: float, targetVisualLine: float) -> None {
        currentVL = visualLines[currentVisualLine];
        targetVL = visualLines[targetVisualLine];
        if not (currentVL and targetVL) {
            return;
        }
        currentVisualCol: float;
        if (self.snappedFromCursorCol != None) {
            vlIndex = self.findVisualLineAt(visualLines, currentVL.logicalLine, self.snappedFromCursorCol);
            currentVisualCol = (self.snappedFromCursorCol - visualLines[vlIndex].startCol);
        }
        else {
            currentVisualCol = (self.state.cursorCol - currentVL.startCol);
        }
        isLastSourceSegment = ((currentVisualLine == (len(visualLines) - 1)) or ((visualLines[(currentVisualLine + 1)].logicalLine if visualLines[(currentVisualLine + 1)] is not None else None) != currentVL.logicalLine));
        sourceMaxVisualCol = (len(currentVL) if isLastSourceSegment else max(float(0), float((len(currentVL) - 1))));
        isLastTargetSegment = ((targetVisualLine == (len(visualLines) - 1)) or ((visualLines[(targetVisualLine + 1)].logicalLine if visualLines[(targetVisualLine + 1)] is not None else None) != targetVL.logicalLine));
        targetMaxVisualCol = (len(targetVL) if isLastTargetSegment else max(float(0), float((len(targetVL) - 1))));
        moveToVisualCol = self.computeVerticalMoveColumn(currentVisualCol, sourceMaxVisualCol, targetMaxVisualCol);
        self.state.cursorLine = targetVL.logicalLine;
        targetCol = (targetVL.startCol + moveToVisualCol);
        logicalLine = (self.state.lines[targetVL.logicalLine] or "");
        self.state.cursorCol = min(float(targetCol), float(len(logicalLine)));
        segments = [*self.segment(logicalLine, "grapheme")];
        for seg in segments {
            if (seg.index > self.state.cursorCol) {
                break;
            }
            if (len(seg.segment) <= 1) {
                continue;
            }
            if (self.state.cursorCol < (seg.index + len(seg.segment))) {
                isContinuation = (seg.index < targetVL.startCol);
                isMovingDown = (targetVisualLine > currentVisualLine);
                if (isContinuation and isMovingDown) {
                    segEnd = (seg.index + len(seg.segment));
                    next_j = (targetVisualLine + 1);
                    while (((next_j < len(visualLines)) and (visualLines[next_j].logicalLine == targetVL.logicalLine)) and (visualLines[next_j].startCol < segEnd)) {
                        next_j += 1;
                    }
                    if (next_j < len(visualLines)) {
                        self.moveToVisualLine(visualLines, currentVisualLine, next_j);
                        return;
                    }
                }
                self.snappedFromCursorCol = self.state.cursorCol;
                self.state.cursorCol = seg.index;
                return;
            }
        }
        self.snappedFromCursorCol = None;
    }
    def computeVerticalMoveColumn(currentVisualCol: float, sourceMaxVisualCol: float, targetMaxVisualCol: float) -> float {
        hasPreferred = (self.preferredVisualCol != None);
        cursorInMiddle = (currentVisualCol < sourceMaxVisualCol);
        targetTooShort = (targetMaxVisualCol < currentVisualCol);
        if (not hasPreferred or cursorInMiddle) {
            if targetTooShort {
                self.preferredVisualCol = currentVisualCol;
                return targetMaxVisualCol;
            }
            self.preferredVisualCol = None;
            return currentVisualCol;
        }
        targetCantFitPreferred = (targetMaxVisualCol < (self.preferredVisualCol as any));
        if (targetTooShort or targetCantFitPreferred) {
            return targetMaxVisualCol;
        }
        result = (self.preferredVisualCol as any);
        self.preferredVisualCol = None;
        return result;
    }
    def moveToLineStart() -> None {
        self.lastAction = None;
        self.setCursorCol(0);
    }
    def moveToLineEnd() -> None {
        self.lastAction = None;
        currentLine = (self.state.lines[self.state.cursorLine] or "");
        self.setCursorCol(len(currentLine));
    }
    def deleteToStartOfLine() -> None {
        self.exitHistoryBrowsing();
        currentLine = (self.state.lines[self.state.cursorLine] or "");
        if (self.state.cursorCol > 0) {
            self.pushUndoSnapshot();
            deletedText = currentLine[0:self.state.cursorCol];
            self.killRing.append(deletedText);
            self.lastAction = "kill";
            self.state.lines[self.state.cursorLine] = currentLine[self.state.cursorCol:];
            self.setCursorCol(0);
        }
        elif (self.state.cursorLine > 0) {
            self.pushUndoSnapshot();
            self.killRing.append("\n");
            self.lastAction = "kill";
            previousLine = (self.state.lines[(self.state.cursorLine - 1)] or "");
            self.state.lines[(self.state.cursorLine - 1)] = (previousLine + currentLine);
            del self.state.lines[self.state.cursorLine];
            self.state.cursorLine += -1;
            self.setCursorCol(len(previousLine));
        }
        if self.onChange {
            self.onChange(self.getText());
        }
    }
    def deleteToEndOfLine() -> None {
        self.exitHistoryBrowsing();
        currentLine = (self.state.lines[self.state.cursorLine] or "");
        if (self.state.cursorCol < len(currentLine)) {
            self.pushUndoSnapshot();
            deletedText = currentLine[self.state.cursorCol:];
            self.killRing.append(deletedText);
            self.lastAction = "kill";
            self.state.lines[self.state.cursorLine] = currentLine[0:self.state.cursorCol];
        }
        elif (self.state.cursorLine < (len(self.state.lines) - 1)) {
            self.pushUndoSnapshot();
            self.killRing.append("\n");
            self.lastAction = "kill";
            nextLine = (self.state.lines[(self.state.cursorLine + 1)] or "");
            self.state.lines[self.state.cursorLine] = (currentLine + nextLine);
            del self.state.lines[(self.state.cursorLine + 1)];
        }
        if self.onChange {
            self.onChange(self.getText());
        }
    }
    def deleteWordBackwards() -> None {
        self.exitHistoryBrowsing();
        currentLine = (self.state.lines[self.state.cursorLine] or "");
        if (self.state.cursorCol == 0) {
            if (self.state.cursorLine > 0) {
                self.pushUndoSnapshot();
                self.killRing.append("\n");
                self.lastAction = "kill";
                previousLine = (self.state.lines[(self.state.cursorLine - 1)] or "");
                self.state.lines[(self.state.cursorLine - 1)] = (previousLine + currentLine);
                del self.state.lines[self.state.cursorLine];
                self.state.cursorLine += -1;
                self.setCursorCol(len(previousLine));
            }
        }
        else {
            self.pushUndoSnapshot();
            wasKill = (self.lastAction == "kill");
            oldCursorCol = self.state.cursorCol;
            self.moveWordBackwards();
            deleteFrom = self.state.cursorCol;
            self.setCursorCol(oldCursorCol);
            deletedText = currentLine[deleteFrom:self.state.cursorCol];
            self.killRing.append(deletedText);
            self.lastAction = "kill";
            self.state.lines[self.state.cursorLine] = (currentLine[0:deleteFrom] + currentLine[self.state.cursorCol:]);
            self.setCursorCol(deleteFrom);
        }
        if self.onChange {
            self.onChange(self.getText());
        }
    }
    def deleteWordForward() -> None {
        self.exitHistoryBrowsing();
        currentLine = (self.state.lines[self.state.cursorLine] or "");
        if (self.state.cursorCol >= len(currentLine)) {
            if (self.state.cursorLine < (len(self.state.lines) - 1)) {
                self.pushUndoSnapshot();
                self.killRing.append("\n");
                self.lastAction = "kill";
                nextLine = (self.state.lines[(self.state.cursorLine + 1)] or "");
                self.state.lines[self.state.cursorLine] = (currentLine + nextLine);
                del self.state.lines[(self.state.cursorLine + 1)];
            }
        }
        else {
            self.pushUndoSnapshot();
            wasKill = (self.lastAction == "kill");
            oldCursorCol = self.state.cursorCol;
            self.moveWordForwards();
            deleteTo = self.state.cursorCol;
            self.setCursorCol(oldCursorCol);
            deletedText = currentLine[self.state.cursorCol:deleteTo];
            self.killRing.append(deletedText);
            self.lastAction = "kill";
            self.state.lines[self.state.cursorLine] = (currentLine[0:self.state.cursorCol] + currentLine[deleteTo:]);
        }
        if self.onChange {
            self.onChange(self.getText());
        }
    }
    def handleForwardDelete() -> None {
        self.exitHistoryBrowsing();
        self.lastAction = None;
        currentLine = (self.state.lines[self.state.cursorLine] or "");
        if (self.state.cursorCol < len(currentLine)) {
            self.pushUndoSnapshot();
            afterCursor = currentLine[self.state.cursorCol:];
            graphemes = [*self.segment(afterCursor, "grapheme")];
            firstGrapheme = graphemes[0];
            graphemeLength = (len(firstGrapheme.segment) if firstGrapheme else 1);
            before = currentLine[0:self.state.cursorCol];
            after = currentLine[(self.state.cursorCol + graphemeLength):];
            self.state.lines[self.state.cursorLine] = (before + after);
        }
        elif (self.state.cursorLine < (len(self.state.lines) - 1)) {
            self.pushUndoSnapshot();
            nextLine = (self.state.lines[(self.state.cursorLine + 1)] or "");
            self.state.lines[self.state.cursorLine] = (currentLine + nextLine);
            del self.state.lines[(self.state.cursorLine + 1)];
        }
        if self.onChange {
            self.onChange(self.getText());
        }
        if self.autocompleteState {
            self.updateAutocomplete();
        }
        else {
            currentLine = (self.state.lines[self.state.cursorLine] or "");
            textBeforeCursor = currentLine[0:self.state.cursorCol];
            if self.isInSlashCommandContext(textBeforeCursor) {
                self.tryTriggerAutocomplete();
            }
            elif self.autocompleteTriggerPattern.test(textBeforeCursor) {
                self.tryTriggerAutocomplete();
            }
        }
    }
    def buildVisualLineMap(width: float) -> list[dict[str, float]] {
        visualLines: list[dict[str, float]] = [];
        i: int = 0;
        while (i < len(self.state.lines)) {
            line = (self.state.lines[i] or "");
            lineVisWidth = visibleWidth(line);
            if (len(line) == 0) {
                visualLines.append({"logicalLine": i, "startCol": 0, "length": 0});
            }
            elif (lineVisWidth <= width) {
                visualLines.append({"logicalLine": i, "startCol": 0, "length": len(line)});
            }
            else {
                chunks = wordWrapLine(line, width, [*self.segment(line, "grapheme")]);
                for chunk in chunks {
                    visualLines.append({"logicalLine": i, "startCol": chunk.startIndex, "length": (chunk.endIndex - chunk.startIndex)});
                }
            }
            i += 1;
        }
        return visualLines;
    }
    def findVisualLineAt(visualLines: list[dict[str, float]], line: float, col: float) -> float {
        i: int = 0;
        while (i < len(visualLines)) {
            vl = visualLines[i];
            if (not vl or (vl.logicalLine != line)) {
                continue;
            }
            offset = (col - vl.startCol);
            isLastSegmentOfLine = ((i == (len(visualLines) - 1)) or ((visualLines[(i + 1)].logicalLine if visualLines[(i + 1)] is not None else None) != vl.logicalLine));
            if ((offset >= 0) and ((offset < len(vl)) or (isLastSegmentOfLine and (offset == len(vl))))) {
                return i;
            }
            i += 1;
        }
        return (len(visualLines) - 1);
    }
    def findCurrentVisualLine(visualLines: list[dict[str, float]]) -> float {
        return self.findVisualLineAt(visualLines, self.state.cursorLine, self.state.cursorCol);
    }
    def moveCursor(deltaLine: float, deltaCol: float) -> None {
        self.lastAction = None;
        visualLines = self.buildVisualLineMap(self.lastWidth);
        currentVisualLine = self.findCurrentVisualLine(visualLines);
        if (deltaLine != 0) {
            targetVisualLine = (currentVisualLine + deltaLine);
            if ((targetVisualLine >= 0) and (targetVisualLine < len(visualLines))) {
                self.moveToVisualLine(visualLines, currentVisualLine, targetVisualLine);
            }
        }
        if (deltaCol != 0) {
            currentLine = (self.state.lines[self.state.cursorLine] or "");
            if (deltaCol > 0) {
                if (self.state.cursorCol < len(currentLine)) {
                    afterCursor = currentLine[self.state.cursorCol:];
                    graphemes = [*self.segment(afterCursor, "grapheme")];
                    firstGrapheme = graphemes[0];
                    self.setCursorCol((self.state.cursorCol + (len(firstGrapheme.segment) if firstGrapheme else 1)));
                }
                elif (self.state.cursorLine < (len(self.state.lines) - 1)) {
                    self.state.cursorLine += 1;
                    self.setCursorCol(0);
                }
                else {
                    currentVL = visualLines[currentVisualLine];
                    if currentVL {
                        self.preferredVisualCol = (self.state.cursorCol - currentVL.startCol);
                    }
                }
            }
            else {
                if (self.state.cursorCol > 0) {
                    beforeCursor = currentLine[0:self.state.cursorCol];
                    graphemes = [*self.segment(beforeCursor, "grapheme")];
                    lastGrapheme = graphemes[(len(graphemes) - 1)];
                    self.setCursorCol((self.state.cursorCol - (len(lastGrapheme.segment) if lastGrapheme else 1)));
                }
                elif (self.state.cursorLine > 0) {
                    self.state.cursorLine += -1;
                    prevLine = (self.state.lines[self.state.cursorLine] or "");
                    self.setCursorCol(len(prevLine));
                }
            }
        }
        if self.autocompleteState {
            self.updateAutocomplete();
        }
    }
    def pageScroll(direction: any) -> None {
        self.lastAction = None;
        terminalRows = self.tui.terminal.rows;
        pageSize = max(float(5), float(int(((terminalRows * 0.3)) // 1)));
        visualLines = self.buildVisualLineMap(self.lastWidth);
        currentVisualLine = self.findCurrentVisualLine(visualLines);
        targetVisualLine = max(float(0), float(min(float((len(visualLines) - 1)), float((currentVisualLine + (direction * pageSize))))));
        self.moveToVisualLine(visualLines, currentVisualLine, targetVisualLine);
    }
    def moveWordBackwards() -> None {
        self.lastAction = None;
        currentLine = (self.state.lines[self.state.cursorLine] or "");
        if (self.state.cursorCol == 0) {
            if (self.state.cursorLine > 0) {
                self.state.cursorLine += -1;
                prevLine = (self.state.lines[self.state.cursorLine] or "");
                self.setCursorCol(len(prevLine));
            }
            return;
        }
        self.setCursorCol(findWordBackward(currentLine, self.state.cursorCol, {"segment": lambda (text: any) -> any { return self.segment(text, "word"); }, "isAtomicSegment": isPasteMarker}));
    }
    def yank() -> None {
        if (len(self.killRing) == 0) {
            return;
        }
        self.pushUndoSnapshot();
        text = (self.killRing.peek() as any);
        self.insertYankedText(text);
        self.lastAction = "yank";
    }
    def yankPop() -> None {
        if ((self.lastAction != "yank") or (len(self.killRing) <= 1)) {
            return;
        }
        self.pushUndoSnapshot();
        self.deleteYankedText();
        self.killRing.rotate();
        text = (self.killRing.peek() as any);
        self.insertYankedText(text);
        self.lastAction = "yank";
    }
    def insertYankedText(text: str) -> None {
        self.exitHistoryBrowsing();
        lines = text.split("\n");
        if (len(lines) == 1) {
            currentLine = (self.state.lines[self.state.cursorLine] or "");
            before = currentLine[0:self.state.cursorCol];
            after = currentLine[self.state.cursorCol:];
            self.state.lines[self.state.cursorLine] = ((before + text) + after);
            self.setCursorCol((self.state.cursorCol + len(text)));
        }
        else {
            currentLine = (self.state.lines[self.state.cursorLine] or "");
            before = currentLine[0:self.state.cursorCol];
            after = currentLine[self.state.cursorCol:];
            self.state.lines[self.state.cursorLine] = (before + (lines[0] or ""));
            # JS2JAC-HOLE[E7230] C-style for loops are not supported (rewrite as while or for...of):
            # | for (let i = 1; i < lines.length - 1; i++) {
            # | 				this.state.lines.splice(this.state.cursorLine + i, 0, lines[i] || "");
            # | 			}
            lastLineIndex = ((self.state.cursorLine + len(lines)) - 1);
            # JS2JAC-HOLE[E7215] splice is supported only as a discard-result statement:
            # | this.state.lines.splice(lastLineIndex, 0, (lines[lines.length - 1] || "") + after);
            self.state.cursorLine = lastLineIndex;
            self.setCursorCol(len((lines[(len(lines) - 1)] or "")));
        }
        if self.onChange {
            self.onChange(self.getText());
        }
    }
    def deleteYankedText() -> None {
        yankedText = self.killRing.peek();
        if not yankedText {
            return;
        }
        yankLines = yankedText.split("\n");
        if (len(yankLines) == 1) {
            currentLine = (self.state.lines[self.state.cursorLine] or "");
            deleteLen = len(yankedText);
            before = currentLine[0:(self.state.cursorCol - deleteLen)];
            after = currentLine[self.state.cursorCol:];
            self.state.lines[self.state.cursorLine] = (before + after);
            self.setCursorCol((self.state.cursorCol - deleteLen));
        }
        else {
            startLine = (self.state.cursorLine - (len(yankLines) - 1));
            startCol = (len((self.state.lines[startLine] or "")) - len((yankLines[0] or "")));
            afterCursor = (self.state.lines[self.state.cursorLine] or "")[self.state.cursorCol:];
            beforeYank = (self.state.lines[startLine] or "")[0:startCol];
            # JS2JAC-HOLE[E7215] splice is supported only as a discard-result statement:
            # | this.state.lines.splice(startLine, yankLines.length, beforeYank + afterCursor);
            self.state.cursorLine = startLine;
            self.setCursorCol(startCol);
        }
        if self.onChange {
            self.onChange(self.getText());
        }
    }
    def pushUndoSnapshot() -> None {
        self.undoStack.append(self.state);
    }
    def undo() -> None {
        self.exitHistoryBrowsing();
        snapshot = self.undoStack.pop();
        if not snapshot {
            return;
        }
        Object.assign(self.state, snapshot);
        self.lastAction = None;
        self.preferredVisualCol = None;
        if self.onChange {
            self.onChange(self.getText());
        }
    }
    def jumpToChar(char: str, direction: any) -> None {
        self.lastAction = None;
        isForward = (direction == "forward");
        lines = self.state.lines;
        end = (len(lines) if isForward else -1);
        step = (1 if isForward else -1);
        lineIdx: int = self.state.cursorLine;
        while (lineIdx != end) {
            line = (lines[lineIdx] or "");
            isCurrentLine = (lineIdx == self.state.cursorLine);
            searchFrom = (((self.state.cursorCol + 1) if isForward else (self.state.cursorCol - 1)) if isCurrentLine else None);
            idx = (line.indexOf(char, searchFrom) if isForward else line.lastIndexOf(char, searchFrom));
            if (idx != -1) {
                self.state.cursorLine = lineIdx;
                self.setCursorCol(idx);
                return;
            }
            lineIdx += step;
        }
    }
    def moveWordForwards() -> None {
        self.lastAction = None;
        currentLine = (self.state.lines[self.state.cursorLine] or "");
        if (self.state.cursorCol >= len(currentLine)) {
            if (self.state.cursorLine < (len(self.state.lines) - 1)) {
                self.state.cursorLine += 1;
                self.setCursorCol(0);
            }
            return;
        }
        self.setCursorCol(findWordForward(currentLine, self.state.cursorCol, {"segment": lambda (text: any) -> any { return self.segment(text, "word"); }, "isAtomicSegment": isPasteMarker}));
    }
    def isSlashMenuAllowed() -> bool {
        return (self.state.cursorLine == 0);
    }
    def isAtStartOfMessage() -> bool {
        if not self.isSlashMenuAllowed() {
            return False;
        }
        currentLine = (self.state.lines[self.state.cursorLine] or "");
        beforeCursor = currentLine[0:self.state.cursorCol];
        return ((beforeCursor.strip() == "") or (beforeCursor.strip() == "/"));
    }
    def isInSlashCommandContext(textBeforeCursor: str) -> bool {
        return (self.isSlashMenuAllowed() and textBeforeCursor.lstrip().startswith("/"));
    }
    def getBestAutocompleteMatchIndex(items: list[dict[str, str]], prefix: str) -> float {
        if not prefix {
            return -1;
        }
        firstPrefixIndex = -1;
        i: int = 0;
        while (i < len(items)) {
            value = (items[i] as any).value;
            if (value == prefix) {
                return i;
            }
            if ((firstPrefixIndex == -1) and value.startswith(prefix)) {
                firstPrefixIndex = i;
            }
            i += 1;
        }
        return firstPrefixIndex;
    }
    def createAutocompleteList(prefix: str, items: list[dict[str, str | str | None]]) -> any {
        layout = (SLASH_COMMAND_SELECT_LIST_LAYOUT if prefix.startswith("/") else None);
        return SelectList(items, self.autocompleteMaxVisible, self.theme.selectList, layout);
    }
    def tryTriggerAutocomplete(explicitTab: bool = False) -> None {
        self.requestAutocomplete({"force": False, "explicitTab": explicitTab});
    }
    def handleTabCompletion() -> None {
        if not self.autocompleteProvider {
            return;
        }
        currentLine = (self.state.lines[self.state.cursorLine] or "");
        beforeCursor = currentLine[0:self.state.cursorCol];
        if (self.isInSlashCommandContext(beforeCursor) and not (" " in beforeCursor.lstrip())) {
            self.handleSlashCommandCompletion();
        }
        else {
            self.forceFileAutocomplete(True);
        }
    }
    def handleSlashCommandCompletion() -> None {
        self.requestAutocomplete({"force": False, "explicitTab": True});
    }
    def forceFileAutocomplete(explicitTab: bool = False) -> None {
        self.requestAutocomplete({"force": True, "explicitTab": explicitTab});
    }
    # JS2JAC-HOLE[E7205] Class method produced no output:
    # | private requestAutocomplete(options: { force: boolean; explicitTab: boolean }): void {
    # | 		if (!this.autocompleteProvider) return;
    # | 
    # | 		if (options.force) {
    # | 			const shouldTrigger =
    # | 				!this.autocompleteProvider.shouldTriggerFileCompletion ||
    # | 				this.autocompleteProvider.shouldTriggerFileCompletion(
    # | 					this.state.lines,
    # | 					this.state.cursorLine,
    # | 					this.state.cursorCol,
    # | 				);
    # | 			if (!shouldTrigger) {
    # | 				return;
    # | 			}
    # | 		}
    # | 
    # | 		this.cancelAutocompleteRequest();
    # | 		const startToken = ++this.autocompleteStartToken;
    # | 
    # | 		const debounceMs = this.getAutocompleteDebounceMs(options);
    # | 		if (debounceMs > 0) {
    # | 			this.autocompleteDebounceTimer = setTimeout(() => {
    # | 				this.autocompleteDebounceTimer = undefined;
    # | 				void this.startAutocompleteRequest(startToken, options);
    # | 			}, debounceMs);
    # | 			return;
    # | 		}
    # | 
    # | 		void this.startAutocompleteRequest(startToken, options);
    # | 	}
    # JS2JAC-HOLE[E7205] Async class methods are not supported:
    # | private async startAutocompleteRequest(
    # | 		startToken: number,
    # | 		options: { force: boolean; explicitTab: boolean },
    # | 	): Promise<void> {
    # | 		const previousTask = this.autocompleteRequestTask;
    # | 		this.autocompleteRequestTask = (async () => {
    # | 			await previousTask;
    # | 			if (startToken !== this.autocompleteStartToken || !this.autocompleteProvider) {
    # | 				return;
    # | 			}
    # | 
    # | 			const controller = new AbortController();
    # | 			this.autocompleteAbort = controller;
    # | 			const requestId = ++this.autocompleteRequestId;
    # | 			const snapshotText = this.getText();
    # | 			const snapshotLine = this.state.cursorLine;
    # | 			const snapshotCol = this.state.cursorCol;
    # | 
    # | 			await this.runAutocompleteRequest(requestId, controller, snapshotText, snapshotLine, snapshotCol, options);
    # | 		})();
    # | 		await this.autocompleteRequestTask;
    # | 	}
    def setAutocompleteTriggerCharacters(triggerCharacters: list[str]) -> None {
        next_j = [*DEFAULT_AUTOCOMPLETE_TRIGGER_CHARACTERS];
        for character in triggerCharacters {
            if ((((len(character) != 1) or (character == "/")) or isWhitespaceChar(character)) or (character in next_j)) {
                continue;
            }
            next_j.append(character);
        }
        self.autocompleteTriggerCharacters = next_j;
        self.autocompleteTriggerPattern = buildTriggerPattern(next_j);
        self.autocompleteDebouncePattern = buildDebouncePattern(next_j);
    }
    def getAutocompleteDebounceMs(options: dict[str, bool]) -> float {
        if (options.explicitTab or options.force) {
            return 0;
        }
        currentLine = (self.state.lines[self.state.cursorLine] or "");
        textBeforeCursor = currentLine[0:self.state.cursorCol];
        return (ATTACHMENT_AUTOCOMPLETE_DEBOUNCE_MS if self.autocompleteDebouncePattern.test(textBeforeCursor) else 0);
    }
    # JS2JAC-HOLE[E7205] Async class methods are not supported:
    # | private async runAutocompleteRequest(
    # | 		requestId: number,
    # | 		controller: AbortController,
    # | 		snapshotText: string,
    # | 		snapshotLine: number,
    # | 		snapshotCol: number,
    # | 		options: { force: boolean; explicitTab: boolean },
    # | 	): Promise<void> {
    # | 		if (!this.autocompleteProvider) return;
    # | 
    # | 		const suggestions = await this.autocompleteProvider.getSuggestions(
    # | 			this.state.lines,
    # | 			this.state.cursorLine,
    # | 			this.state.cursorCol,
    # | 			{ signal: controller.signal, force: options.force },
    # | 		);
    # | 
    # | 		if (!this.isAutocompleteRequestCurrent(requestId, controller, snapshotText, snapshotLine, snapshotCol)) {
    # | 			return;
    # | 		}
    # | 
    # | 		this.autocompleteAbort = undefined;
    # | 
    # | 		if (!suggestions || !Array.isArray(suggestions.items) || suggestions.items.length === 0) {
    # | 			this.cancelAutocomplete();
    # | 			this.tui.requestRender();
    # | 			return;
    # | 		}
    # | 
    # | 		if (options.force && options.explicitTab && suggestions.items.length === 1) {
    # | 			const item = suggestions.items[0]!;
    # | 			this.pushUndoSnapshot();
    # | 			this.lastAction = null;
    # | 			const result = this.autocompleteProvider.applyCompletion(
    # | 				this.state.lines,
    # | 				this.state.cursorLine,
    # | 				this.state.cursorCol,
    # | 				item,
    # | 				suggestions.prefix,
    # | 			);
    # | 			this.state.lines = result.lines;
    # | 			this.state.cursorLine = result.cursorLine;
    # | 			this.setCursorCol(result.cursorCol);
    # | 			if (this.onChange) this.onChange(this.getText());
    # | 			this.tui.requestRender();
    # | 			return;
    # | 		}
    # | 
    # | 		this.applyAutocompleteSuggestions(suggestions, options.force ? "force" : "regular");
    # | 		this.tui.requestRender();
    # | 	}
    def isAutocompleteRequestCurrent(requestId: float, controller: any, snapshotText: str, snapshotLine: float, snapshotCol: float) -> bool {
        return ((((not controller.signal.aborted and (requestId == self.autocompleteRequestId)) and (self.getText() == snapshotText)) and (self.state.cursorLine == snapshotLine)) and (self.state.cursorCol == snapshotCol));
    }
    def applyAutocompleteSuggestions(suggestions: any, state: any) -> None {
        self.autocompletePrefix = suggestions.prefix;
        self.autocompleteList = self.createAutocompleteList(suggestions.prefix, suggestions.items);
        bestMatchIndex = self.getBestAutocompleteMatchIndex(suggestions.items, suggestions.prefix);
        if (bestMatchIndex >= 0) {
            self.autocompleteList.setSelectedIndex(bestMatchIndex);
        }
        self.autocompleteState = state;
    }
    def cancelAutocompleteRequest() -> None {
        self.autocompleteStartToken += 1;
        if self.autocompleteDebounceTimer {
            clearTimeout(self.autocompleteDebounceTimer);
            self.autocompleteDebounceTimer = None;
        }
        (self.autocompleteAbort.abort if self.autocompleteAbort is not None else None)();
        self.autocompleteAbort = None;
    }
    def clearAutocompleteUi() -> None {
        self.autocompleteState = None;
        self.autocompleteList = None;
        self.autocompletePrefix = "";
    }
    def cancelAutocomplete() -> None {
        self.cancelAutocompleteRequest();
        self.clearAutocompleteUi();
    }
    def isShowingAutocomplete() -> bool {
        return (self.autocompleteState != None);
    }
    def updateAutocomplete() -> None {
        if (not self.autocompleteState or not self.autocompleteProvider) {
            return;
        }
        self.requestAutocomplete({"force": (self.autocompleteState == "force"), "explicitTab": False});
    }
}
