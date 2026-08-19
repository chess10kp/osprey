import from "../fuzzy.jac" { fuzzyFilter }
import from "../keybindings.jac" { getKeybindings }
import from "../utils.jac" { truncateToWidth, visibleWidth, wrapTextWithAnsi }
import from "./input.jac" { Input }

obj:pub SettingsList {
    has items: list[any];
    has filteredItems: list[any];
    has theme: any;
    has maxVisible: float;
    has onChange: any;
    has onCancel: any;
    has searchInput: any | None = None;
    has searchEnabled: bool;
    has selectedIndex: int = 0;
    has submenuComponent: any | None = None;
    has submenuItemIndex: float | None = None;
    def __init__(items: list[any], maxVisible: float, theme: any, onChange: any, onCancel: any, options: any = {}) -> None {
        self.items = items;
        self.filteredItems = items;
        self.maxVisible = maxVisible;
        self.theme = theme;
        self.onChange = onChange;
        self.onCancel = onCancel;
        self.searchEnabled = ((lambda (_jx_null0: any) -> any { return (_jx_null0 if _jx_null0 is not None else False); })(options.enableSearch));
        if self.searchEnabled {
            self.searchInput = Input();
        }
    }
    def updateValue(id_j: str, newValue: str) -> None {
        item = self.items.find(lambda (i: any) -> any { return (i.id == id_j); });
        if item {
            item.currentValue = newValue;
        }
    }
    def invalidate() -> None {
        ((lambda (_jx_opt1: any) -> any { return (((lambda (_jx_opt2: any) -> any { return (_jx_opt2() if _jx_opt2 is not None else None); })(_jx_opt1.invalidate)) if _jx_opt1 is not None else None); })(self.submenuComponent));
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
        maxLabelWidth = min(float(30), float(max(*[float(_jx_math) for _jx_math in [visibleWidth(item.label) for item in self.items]])));
        i: int = startIndex;
        while (i < endIndex) {
            item = displayItems[i];
            if not item {
                continue;
            }
            isSelected = (i == self.selectedIndex);
            prefix = (self.theme.cursor if isSelected else "  ");
            prefixWidth = visibleWidth(prefix);
            labelPadded = (item.label + (" " * int(max(float(0), float((maxLabelWidth - visibleWidth(item.label)))))));
            labelText = self.theme.label(labelPadded, isSelected);
            separator: str = "  ";
            usedWidth = ((prefixWidth + maxLabelWidth) + visibleWidth(separator));
            valueMaxWidth = ((width - usedWidth) - 2);
            valueText = self.theme.value(truncateToWidth(item.currentValue, valueMaxWidth, ""), isSelected);
            lines.append(truncateToWidth((((prefix + labelText) + separator) + valueText), width));
            i += 1;
        }
        if ((startIndex > 0) or (endIndex < len(displayItems))) {
            scrollText: str = f"  ({(self.selectedIndex + 1)}/{len(displayItems)})";
            lines.append(self.theme.hint(truncateToWidth(scrollText, (width - 2), "")));
        }
        selectedItem = displayItems[self.selectedIndex];
        if ((lambda (_jx_opt3: any) -> any { return (_jx_opt3.description if _jx_opt3 is not None else None); })(selectedItem)) {
            lines.append("");
            wrappedDesc = wrapTextWithAnsi(selectedItem.description, (width - 4));
            for line in wrappedDesc {
                lines.append(self.theme.description(f"  {line}"));
            }
        }
        self.addHintLine(lines, width);
        return lines;
    }
    def handleInput(data: str) -> None {
        if self.submenuComponent {
            ((lambda (_jx_opt4: any) -> any { return (_jx_opt4(data) if _jx_opt4 is not None else None); })(self.submenuComponent.handleInput));
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
        if item.submenu {
            self.submenuItemIndex = self.selectedIndex;
            self.submenuComponent = item.submenu(item.currentValue, lambda (selectedValue: str) -> any { if (selectedValue != None) {     item.currentValue = selectedValue;     self.onChange(item.id, selectedValue); } self.closeSubmenu(); });
        }
        elif (item.values and (len(item.values) > 0)) {
            currentIndex = (-1 if item.currentValue not in item.values else item.values.index(item.currentValue));
            nextIndex = ((currentIndex + 1) % len(item.values));
            newValue = item.values[nextIndex];
            item.currentValue = newValue;
            self.onChange(item.id, newValue);
        }
    }
    def closeSubmenu() -> None {
        self.submenuComponent = None;
        if (self.submenuItemIndex != None) {
            self.selectedIndex = self.submenuItemIndex;
            self.submenuItemIndex = None;
        }
    }
    def applyFilter(query: str) -> None {
        self.filteredItems = fuzzyFilter(self.items, query, lambda (item: any) -> any { return item.label; });
        self.selectedIndex = 0;
    }
    def addHintLine(lines: list[str], width: float) -> None {
        lines.append("");
        lines.append(truncateToWidth(self.theme.hint(("  Type to search · Enter/Space to change · Esc to cancel" if self.searchEnabled else "  Enter/Space to change · Esc to cancel")), width));
    }
}
