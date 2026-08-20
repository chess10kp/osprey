import from ..fuzzy { fuzzyFilter }
import from ..keybindings { getKeybindings }
import from ..utils { truncateToWidth, visibleWidth, wrapTextWithAnsi }
import from .input { Input }

obj:pub SettingsList {
    has items: list[any];
    has filteredItems: list[any];
    has theme: any;
    has maxVisible: float;
    has onChange: any;
    has onCancel: any;
    has searchEnabled: bool;
    has selectedIndex: int = 0;
    has searchInput: any | None = None;
    has submenuComponent: any | None = None;
    has submenuItemIndex: float | None = None;
    def __init__(items: list[any], maxVisible: float, theme: any, onChange: any, onCancel: any, options: any = {}) -> None {
        self.items = items;
        self.filteredItems = items;
        self.maxVisible = maxVisible;
        self.theme = theme;
        self.onChange = onChange;
        self.onCancel = onCancel;
        self.selectedIndex = 0;
        self.searchInput = None;
        self.submenuComponent = None;
        self.submenuItemIndex = None;
        self.searchEnabled = (options.get("enableSearch", False) if options is not None else False);
        if self.searchEnabled {
            self.searchInput = Input();
        }
    }
    def updateValue(id_j: str, newValue: str) -> None {
        item = None;
        for i in self.items {
            if (i["id"] == id_j) {
                item = i;
                break;
            }
        }
        if item is not None {
            item["currentValue"] = newValue;
        }
    }
    def invalidate() -> None {
        if self.submenuComponent is not None {
            self.submenuComponent.invalidate();
        }
    }
    def render(width: float) -> list[str] {
        if self.submenuComponent {
            return self.submenuComponent.render(width);
        }
        return self.renderMainList(width);
    }
    def renderMainList(width: float) -> list[str] {
        lines: list[str] = [];
        if (self.searchEnabled and self.searchInput) {
            lines.extend(self.searchInput.render(width));
            lines.append("");
        }
        if (len(self.items) == 0) {
            lines.append(self.theme.hint("  No settings available"));
            if self.searchEnabled {
                self.addHintLine(lines, width);
            }
            return lines;
        }
        displayItems = (self.filteredItems if self.searchEnabled else self.items);
        if (len(displayItems) == 0) {
            lines.append(truncateToWidth(self.theme.hint("  No matching settings"), width));
            self.addHintLine(lines, width);
            return lines;
        }
        startIndex = max(float(0), float(min(float((self.selectedIndex - int(((self.maxVisible / 2)) // 1))), float((len(displayItems) - self.maxVisible)))));
        endIndex = min(float((startIndex + self.maxVisible)), float(len(displayItems)));
        maxLabelWidth = min(float(30), float(max(*[float(_jx_math) for _jx_math in [visibleWidth(item["label"]) for item in self.items]])));
        i: int = int(startIndex);
        while (i < endIndex) {
            item = displayItems[i];
            if not item {
                continue;
            }
            isSelected = (i == self.selectedIndex);
            prefix = (self.theme.cursor if isSelected else "  ");
            prefixWidth = visibleWidth(prefix);
            itemLabel: str = item["label"];
            labelPadded = (itemLabel + (" " * int(max(float(0), float((maxLabelWidth - visibleWidth(itemLabel)))))));
            labelText = self.theme.label(labelPadded, isSelected);
            separator: str = "  ";
            usedWidth = ((prefixWidth + maxLabelWidth) + visibleWidth(separator));
            valueMaxWidth = ((width - usedWidth) - 2);
            valueText = self.theme.value(truncateToWidth(item["currentValue"], valueMaxWidth, ""), isSelected);
            lines.append(truncateToWidth((((prefix + labelText) + separator) + valueText), width));
            i += 1;
        }
        if ((startIndex > 0) or (endIndex < len(displayItems))) {
            scrollText: str = f"  ({(self.selectedIndex + 1)}/{len(displayItems)})";
            lines.append(self.theme.hint(truncateToWidth(scrollText, (width - 2), "")));
        }
        selectedItem = displayItems[self.selectedIndex];
        if (selectedItem is not None and selectedItem.get("description")) {
            lines.append("");
            wrappedDesc = wrapTextWithAnsi(selectedItem["description"], (width - 4));
            for line in wrappedDesc {
                lines.append(self.theme.description(f"  {line}"));
            }
        }
        self.addHintLine(lines, width);
        return lines;
    }
    def handleInput(data: str) -> None {
        if self.submenuComponent {
            if self.submenuComponent.handleInput is not None {
                self.submenuComponent.handleInput(data);
            }
            return;
        }
        kb = getKeybindings();
        displayItems = (self.filteredItems if self.searchEnabled else self.items);
        if kb.matches(data, "tui.select.up") {
            if (len(displayItems) == 0) {
                return;
            }
            self.selectedIndex = ((len(displayItems) - 1) if (self.selectedIndex == 0) else (self.selectedIndex - 1));
        }
        elif kb.matches(data, "tui.select.down") {
            if (len(displayItems) == 0) {
                return;
            }
            self.selectedIndex = (0 if (self.selectedIndex == (len(displayItems) - 1)) else (self.selectedIndex + 1));
        }
        elif (kb.matches(data, "tui.select.confirm") or (data == " ")) {
            self.activateItem();
        }
        elif kb.matches(data, "tui.select.cancel") {
            self.onCancel();
        }
        elif (self.searchEnabled and self.searchInput) {
            sanitized = data.replace(" ", "");
            if not sanitized {
                return;
            }
            self.searchInput.handleInput(sanitized);
            self.applyFilter(self.searchInput.getValue());
        }
    }
    def activateItem() -> None {
        item = (self.filteredItems[self.selectedIndex] if self.searchEnabled else self.items[self.selectedIndex]);
        if not item {
            return;
        }
        if item.get("submenu") {
            self.submenuItemIndex = self.selectedIndex;
            submenuFactory = item["submenu"];
            doneCallback = lambda (selectedValue: str | None) -> None {
                if (selectedValue != None) {
                    item["currentValue"] = selectedValue;
                    self.onChange(item["id"], selectedValue);
                }
                self.closeSubmenu();
            };
            self.submenuComponent = submenuFactory(item["currentValue"], doneCallback);
        }
        elif (item.get("values") and (len(item["values"]) > 0)) {
            values: list[any] = item["values"];
            currentValue = item["currentValue"];
            currentIndex = (-1 if currentValue not in values else values.index(currentValue));
            nextIndex = ((currentIndex + 1) % len(values));
            newValue = values[nextIndex];
            item["currentValue"] = newValue;
            self.onChange(item["id"], newValue);
        }
    }
    def closeSubmenu() -> None {
        self.submenuComponent = None;
        if (self.submenuItemIndex != None) {
            self.selectedIndex = int(self.submenuItemIndex);
            self.submenuItemIndex = None;
        }
    }
    def applyFilter(query: str) -> None {
        labelKey = lambda (item: any) -> any { return item["label"]; };
        self.filteredItems = fuzzyFilter(self.items, query, labelKey);
        self.selectedIndex = 0;
    }
    def addHintLine(lines: list[str], width: float) -> None {
        lines.append("");
        lines.append(truncateToWidth(self.theme.hint(("  Type to search · Enter/Space to change · Esc to cancel" if self.searchEnabled else "  Enter/Space to change · Esc to cancel")), width));
    }
}
