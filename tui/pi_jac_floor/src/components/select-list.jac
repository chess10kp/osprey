import from "../keybindings.jac" { getKeybindings }
import from "../utils.jac" { truncateToWidth, visibleWidth }
import from re { sub }

glob DEFAULT_PRIMARY_COLUMN_WIDTH = 32;

glob PRIMARY_COLUMN_GAP = 2;

glob MIN_DESCRIPTION_WIDTH = 10;

def normalizeToSingleLine(text: str) -> str {
    return sub(r"[\r\n]+", " ", text).strip();
}

def clamp(value: float, min_j: float, max_j: float) -> float {
    return max(float(min_j), float(min(float(value), float(max_j))));
}

obj:pub SelectList {
    has theme: any;
    has layout: any;
    has onSelect: any | None = None;
    has onCancel: any | None = None;
    has onSelectionChange: any | None = None;
    has items: list[any] = [];
    has filteredItems: list[any] = [];
    has selectedIndex: float = 0;
    has maxVisible: float = 5;
    def __init__(items: list[any], maxVisible: float, theme: any, layout: any = {}) -> None {
        self.items = items;
        self.filteredItems = items;
        self.maxVisible = maxVisible;
        self.theme = theme;
        self.layout = layout;
    }
    def setFilter(filter_j: str) -> None {
        self.filteredItems = [item for item in self.items if item.value.lower().startswith(filter_j.lower())];
        self.selectedIndex = 0;
    }
    def setSelectedIndex(index: float) -> None {
        self.selectedIndex = max(float(0), float(min(float(index), float((len(self.filteredItems) - 1)))));
    }
    def invalidate() -> None {
    }
    def render(width: float) -> list[str] {
        lines: list[str] = [];
        if (len(self.filteredItems) == 0) {
            lines.append(self.theme.noMatch("  No matching commands"));
            return lines;
        }
        primaryColumnWidth = self.getPrimaryColumnWidth();
        startIndex = max(float(0), float(min(float((self.selectedIndex - int(((self.maxVisible / 2)) // 1))), float((len(self.filteredItems) - self.maxVisible)))));
        endIndex = min(float((startIndex + self.maxVisible)), float(len(self.filteredItems)));
        i: int = startIndex;
        while (i < endIndex) {
            item = self.filteredItems[i];
            if not item {
                continue;
            }
            isSelected = (i == self.selectedIndex);
            descriptionSingleLine = (normalizeToSingleLine(item.description) if item.description else None);
            lines.append(self.renderItem(item, isSelected, width, descriptionSingleLine, primaryColumnWidth));
            i += 1;
        }
        # JS2JAC-HOLE[E7214]:
        # | if (startIndex > 0 || endIndex < this.filteredItems.length) {
        # | 			const scrollText = `  (${this.selectedIndex + 1}/${this.filteredItems.length})`;
        # | 			// Truncate if too long for terminal
        # | 			lines.push(this.theme.scrollInfo(truncateToWidth(scrollText, width - 2, "")));
        # | 		}
        return lines;
    }
    def handleInput(keyData: str) -> None {
        kb = getKeybindings();
        if kb.matches(keyData, "tui.select.up") {
            self.selectedIndex = ((len(self.filteredItems) - 1) if (self.selectedIndex == 0) else (self.selectedIndex - 1));
            self.notifySelectionChange();
        }
        elif kb.matches(keyData, "tui.select.down") {
            self.selectedIndex = (0 if (self.selectedIndex == (len(self.filteredItems) - 1)) else (self.selectedIndex + 1));
            self.notifySelectionChange();
        }
        elif kb.matches(keyData, "tui.select.confirm") {
            selectedItem = self.filteredItems[self.selectedIndex];
            if (selectedItem and self.onSelect) {
                self.onSelect(selectedItem);
            }
        }
        elif kb.matches(keyData, "tui.select.cancel") {
            if self.onCancel {
                self.onCancel();
            }
        }
    }
    def renderItem(item: any, isSelected: bool, width: float, descriptionSingleLine: str | None, primaryColumnWidth: float) -> str {
        prefix = ("→ " if isSelected else "  ");
        prefixWidth = visibleWidth(prefix);
        if (descriptionSingleLine and (width > 40)) {
            effectivePrimaryColumnWidth = max(float(1), float(min(float(primaryColumnWidth), float(((width - prefixWidth) - 4)))));
            maxPrimaryWidth = max(float(1), float((effectivePrimaryColumnWidth - PRIMARY_COLUMN_GAP)));
            truncatedValue = self.truncatePrimary(item, isSelected, maxPrimaryWidth, effectivePrimaryColumnWidth);
            truncatedValueWidth = visibleWidth(truncatedValue);
            spacing = (" " * int(max(float(1), float((effectivePrimaryColumnWidth - truncatedValueWidth)))));
            descriptionStart = ((prefixWidth + truncatedValueWidth) + len(spacing));
            remainingWidth = ((width - descriptionStart) - 2);
            if (remainingWidth > MIN_DESCRIPTION_WIDTH) {
                truncatedDesc = truncateToWidth(descriptionSingleLine, remainingWidth, "");
                if isSelected {
                    return self.theme.selectedText(f"{prefix}{truncatedValue}{spacing}{truncatedDesc}");
                }
                descText = self.theme.description((spacing + truncatedDesc));
                return ((prefix + truncatedValue) + descText);
            }
        }
        maxWidth = ((width - prefixWidth) - 2);
        truncatedValue = self.truncatePrimary(item, isSelected, maxWidth, maxWidth);
        if isSelected {
            return self.theme.selectedText(f"{prefix}{truncatedValue}");
        }
        return (prefix + truncatedValue);
    }
    def getPrimaryColumnWidth() -> float {
        _jx_d0: any = self.getPrimaryColumnBounds();
        min = _jx_d0.min;
        max = _jx_d0.max;
        widestPrimary = self.filteredItems.reduce(lambda (widest: any, item: any) -> any { return max(float(widest), float((visibleWidth(self.getDisplayValue(item)) + PRIMARY_COLUMN_GAP))); }, 0);
        return clamp(widestPrimary, min_j, max_j);
    }
    # JS2JAC-HOLE[E7205] Class method produced no output:
    # | private getPrimaryColumnBounds(): { min: number; max: number } {
    # | 		const rawMin =
    # | 			this.layout.minPrimaryColumnWidth ?? this.layout.maxPrimaryColumnWidth ?? DEFAULT_PRIMARY_COLUMN_WIDTH;
    # | 		const rawMax =
    # | 			this.layout.maxPrimaryColumnWidth ?? this.layout.minPrimaryColumnWidth ?? DEFAULT_PRIMARY_COLUMN_WIDTH;
    # | 
    # | 		return {
    # | 			min: Math.max(1, Math.min(rawMin, rawMax)),
    # | 			max: Math.max(1, Math.max(rawMin, rawMax)),
    # | 		};
    # | 	}
    def truncatePrimary(item: any, isSelected: bool, maxWidth: float, columnWidth: float) -> str {
        displayValue = self.getDisplayValue(item);
        truncatedValue = (self.layout.truncatePrimary({"text": displayValue, "maxWidth": maxWidth, "columnWidth": columnWidth, "item": item, "isSelected": isSelected}) if self.layout.truncatePrimary else truncateToWidth(displayValue, maxWidth, ""));
        return truncateToWidth(truncatedValue, maxWidth, "");
    }
    def getDisplayValue(item: any) -> str {
        return (item.label or item.value);
    }
    def notifySelectionChange() -> None {
        selectedItem = self.filteredItems[self.selectedIndex];
        if (selectedItem and self.onSelectionChange) {
            self.onSelectionChange(selectedItem);
        }
    }
    def getSelectedItem() -> any | None {
        item = self.filteredItems[self.selectedIndex];
        return (item or None);
    }
}
