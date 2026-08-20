import from ..keybindings { getKeybindings }
import from ..keys { decodeKittyPrintable }
import from ..kill_ring { KillRing }
import from ..tui { CURSOR_MARKER }
import from ..undo_stack { UndoStack }
import from ..utils { getGraphemeSegmenter, isWhitespaceChar, sliceByColumn, visibleWidth }
import from ..word_navigation { findWordBackward, findWordForward }

glob segmenter = getGraphemeSegmenter();

obj:pub Input {
    has value: str = "";
    has cursor: int = 0;
    has onSubmit: any | None = None;
    has onEscape: any | None = None;
    has focused: bool = False;
    has pasteBuffer: str = "";
    has isInPaste: bool = False;
    has killRing: any = KillRing();
    has lastAction: any | None = None;
    has undoStack: any = UndoStack();
    def getValue() -> str {
        return self.value;
    }
    def setValue(value: str) -> None {
        self.value = value;
        self.cursor = min(self.cursor, len(value));
    }
    def handleInput(data: str) -> None {
        if ("\u001b[200~" in data) {
            self.isInPaste = True;
            self.pasteBuffer = "";
            data = data.replace("\u001b[200~", "");
        }
        if self.isInPaste {
            self.pasteBuffer += data;
            endIndex = (-1 if "\u001b[201~" not in self.pasteBuffer else self.pasteBuffer.index("\u001b[201~"));
            if (endIndex != -1) {
                pasteContent = self.pasteBuffer[0:endIndex];
                self.handlePaste(pasteContent);
                self.isInPaste = False;
                remaining = self.pasteBuffer[(endIndex + 6):];
                self.pasteBuffer = "";
                if remaining {
                    self.handleInput(remaining);
                }
            }
            return;
        }
        kb = getKeybindings();
        if kb.matches(data, "tui.select.cancel") {
            if self.onEscape {
                self.onEscape();
            }
            return;
        }
        if kb.matches(data, "tui.editor.undo") {
            self.undo();
            return;
        }
        if (kb.matches(data, "tui.input.submit") or (data == "\n")) {
            if self.onSubmit {
                self.onSubmit(self.value);
            }
            return;
        }
        if kb.matches(data, "tui.editor.deleteCharBackward") {
            self.handleBackspace();
            return;
        }
        if kb.matches(data, "tui.editor.deleteCharForward") {
            self.handleForwardDelete();
            return;
        }
        if kb.matches(data, "tui.editor.deleteWordBackward") {
            self.deleteWordBackwards();
            return;
        }
        if kb.matches(data, "tui.editor.deleteWordForward") {
            self.deleteWordForward();
            return;
        }
        if kb.matches(data, "tui.editor.deleteToLineStart") {
            self.deleteToLineStart();
            return;
        }
        if kb.matches(data, "tui.editor.deleteToLineEnd") {
            self.deleteToLineEnd();
            return;
        }
        if kb.matches(data, "tui.editor.yank") {
            self.yank();
            return;
        }
        if kb.matches(data, "tui.editor.yankPop") {
            self.yankPop();
            return;
        }
        if kb.matches(data, "tui.editor.cursorLeft") {
            self.lastAction = None;
            if (self.cursor > 0) {
                beforeCursor = self.value[0:self.cursor];
                graphemes = [*segmenter.segment(beforeCursor)];
                lastGrapheme = graphemes[(len(graphemes) - 1)];
                self.cursor -= (len((lastGrapheme.segment as str)) if lastGrapheme else 1);
            }
            return;
        }
        if kb.matches(data, "tui.editor.cursorRight") {
            self.lastAction = None;
            if (self.cursor < len(self.value)) {
                afterCursor = self.value[self.cursor:];
                graphemes = [*segmenter.segment(afterCursor)];
                firstGrapheme = graphemes[0];
                self.cursor += (len((firstGrapheme.segment as str)) if firstGrapheme else 1);
            }
            return;
        }
        if kb.matches(data, "tui.editor.cursorLineStart") {
            self.lastAction = None;
            self.cursor = 0;
            return;
        }
        if kb.matches(data, "tui.editor.cursorLineEnd") {
            self.lastAction = None;
            self.cursor = len(self.value);
            return;
        }
        if kb.matches(data, "tui.editor.cursorWordLeft") {
            self.moveWordBackwards();
            return;
        }
        if kb.matches(data, "tui.editor.cursorWordRight") {
            self.moveWordForwards();
            return;
        }
        kittyPrintable = decodeKittyPrintable(data);
        if (kittyPrintable != None) {
            self.insertCharacter(kittyPrintable);
            return;
        }
        hasControlChars = any((((ord(ch) < 32) or (ord(ch) == 127)) or ((ord(ch) >= 128) and (ord(ch) <= 159))) for ch in data);
        if not hasControlChars {
            self.insertCharacter(data);
        }
    }
    def insertCharacter(char: str) -> None {
        if (isWhitespaceChar(char) or (self.lastAction != "type-word")) {
            self.pushUndo();
        }
        self.lastAction = "type-word";
        self.value = ((self.value[0:self.cursor] + char) + self.value[self.cursor:]);
        self.cursor += len(char);
    }
    def handleBackspace() -> None {
        self.lastAction = None;
        if (self.cursor > 0) {
            self.pushUndo();
            beforeCursor = self.value[0:self.cursor];
            graphemes = [*segmenter.segment(beforeCursor)];
            lastGrapheme = graphemes[(len(graphemes) - 1)];
            graphemeLength = (len((lastGrapheme.segment as str)) if lastGrapheme else 1);
            self.value = (self.value[0:(self.cursor - graphemeLength)] + self.value[self.cursor:]);
            self.cursor -= graphemeLength;
        }
    }
    def handleForwardDelete() -> None {
        self.lastAction = None;
        if (self.cursor < len(self.value)) {
            self.pushUndo();
            afterCursor = self.value[self.cursor:];
            graphemes = [*segmenter.segment(afterCursor)];
            firstGrapheme = graphemes[0];
            graphemeLength = (len((firstGrapheme.segment as str)) if firstGrapheme else 1);
            self.value = (self.value[0:self.cursor] + self.value[(self.cursor + graphemeLength):]);
        }
    }
    def deleteToLineStart() -> None {
        if (self.cursor == 0) {
            return;
        }
        self.pushUndo();
        deletedText = self.value[0:self.cursor];
        self.killRing.push(deletedText, {"prepend": True, "accumulate": (self.lastAction == "kill")});
        self.lastAction = "kill";
        self.value = self.value[self.cursor:];
        self.cursor = 0;
    }
    def deleteToLineEnd() -> None {
        if (self.cursor >= len(self.value)) {
            return;
        }
        self.pushUndo();
        deletedText = self.value[self.cursor:];
        self.killRing.push(deletedText, {"prepend": False, "accumulate": (self.lastAction == "kill")});
        self.lastAction = "kill";
        self.value = self.value[0:self.cursor];
    }
    def deleteWordBackwards() -> None {
        if (self.cursor == 0) {
            return;
        }
        wasKill = (self.lastAction == "kill");
        self.pushUndo();
        oldCursor = self.cursor;
        self.moveWordBackwards();
        deleteFrom = self.cursor;
        self.cursor = oldCursor;
        deletedText = self.value[deleteFrom:self.cursor];
        self.killRing.push(deletedText, {"prepend": True, "accumulate": wasKill});
        self.lastAction = "kill";
        self.value = (self.value[0:deleteFrom] + self.value[self.cursor:]);
        self.cursor = deleteFrom;
    }
    def deleteWordForward() -> None {
        if (self.cursor >= len(self.value)) {
            return;
        }
        wasKill = (self.lastAction == "kill");
        self.pushUndo();
        oldCursor = self.cursor;
        self.moveWordForwards();
        deleteTo = self.cursor;
        self.cursor = oldCursor;
        deletedText = self.value[self.cursor:deleteTo];
        self.killRing.push(deletedText, {"prepend": False, "accumulate": wasKill});
        self.lastAction = "kill";
        self.value = (self.value[0:self.cursor] + self.value[deleteTo:]);
    }
    def yank() -> None {
        text = self.killRing.peek();
        if not text {
            return;
        }
        self.pushUndo();
        self.value = ((self.value[0:self.cursor] + text) + self.value[self.cursor:]);
        self.cursor += len(text);
        self.lastAction = "yank";
    }
    def yankPop() -> None {
        if ((self.lastAction != "yank") or (self.killRing.length() <= 1)) {
            return;
        }
        self.pushUndo();
        prevText = (self.killRing.peek() or "");
        self.value = (self.value[0:(self.cursor - len(prevText))] + self.value[self.cursor:]);
        self.cursor -= len(prevText);
        self.killRing.rotate();
        text = (self.killRing.peek() or "");
        self.value = ((self.value[0:self.cursor] + text) + self.value[self.cursor:]);
        self.cursor += len(text);
        self.lastAction = "yank";
    }
    def pushUndo() -> None {
        self.undoStack.push({"value": self.value, "cursor": self.cursor});
    }
    def undo() -> None {
        snapshot = self.undoStack.pop();
        if not snapshot {
            return;
        }
        self.value = snapshot["value"];
        self.cursor = int(snapshot["cursor"]);
        self.lastAction = None;
    }
    def moveWordBackwards() -> None {
        if (self.cursor == 0) {
            return;
        }
        self.lastAction = None;
        self.cursor = int(findWordBackward(self.value, self.cursor));
    }
    def moveWordForwards() -> None {
        if (self.cursor >= len(self.value)) {
            return;
        }
        self.lastAction = None;
        self.cursor = int(findWordForward(self.value, self.cursor));
    }
    def handlePaste(pastedText: str) -> None {
        self.lastAction = None;
        self.pushUndo();
        cleanText = pastedText.replace("\r\n", "").replace("\r", "").replace("\n", "").replace("\t", "    ");
        self.value = ((self.value[0:self.cursor] + cleanText) + self.value[self.cursor:]);
        self.cursor += len(cleanText);
    }
    def invalidate() -> None {
    }
    def render(width: float) -> list[str] {
        prompt: str = "> ";
        availableWidth = (width - len(prompt));
        if (availableWidth <= 0) {
            return [prompt];
        }
        visibleText: str = "";
        cursorDisplay = self.cursor;
        totalWidth = visibleWidth(self.value);
        if (totalWidth < availableWidth) {
            visibleText = self.value;
        }
        else {
            scrollWidth = ((availableWidth - 1) if (self.cursor == len(self.value)) else availableWidth);
            cursorCol = visibleWidth(self.value[0:self.cursor]);
            if (scrollWidth > 0) {
                halfWidth = int(((scrollWidth / 2)) // 1);
                startCol: float = float(0);
                if (cursorCol < halfWidth) {
                    startCol = float(0);
                }
                elif (cursorCol > (totalWidth - halfWidth)) {
                    startCol = max(float(0), float((totalWidth - scrollWidth)));
                }
                else {
                    startCol = max(float(0), float((cursorCol - halfWidth)));
                }
                visibleText = sliceByColumn(self.value, startCol, scrollWidth, True);
                beforeCursor = sliceByColumn(self.value, startCol, max(float(0), float((cursorCol - startCol))), True);
                cursorDisplay = len(beforeCursor);
            }
            else {
                visibleText = "";
                cursorDisplay = 0;
            }
        }
        graphemes = [*segmenter.segment(visibleText[cursorDisplay:])];
        cursorGrapheme = (graphemes[0] if (len(graphemes) > 0) else None);
        beforeCursor = visibleText[0:cursorDisplay];
        cursorSegment = ((cursorGrapheme.segment as str) if cursorGrapheme is not None else None);
        atCursor: str = (cursorSegment if cursorSegment is not None else " ");
        afterCursor = visibleText[(cursorDisplay + len(atCursor)):];
        marker = (CURSOR_MARKER if self.focused else "");
        cursorChar: str = f"\x1b[7m{atCursor}\x1b[27m";
        textWithCursor = (((beforeCursor + marker) + cursorChar) + afterCursor);
        visualLength = visibleWidth(textWithCursor);
        padding = (" " * int(max(float(0), float((availableWidth - visualLength)))));
        line = ((prompt + textWithCursor) + padding);
        return [line];
    }
}
