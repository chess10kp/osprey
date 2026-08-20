"""Runtime smoke for the SettingsList component (src/components/settings_list.jac).

Exercises rendering, fuzzy-filter narrowing (search enabled), up/down
selection movement (with wrap), and value cycling via activateItem().

The js2jac output left several check-passing-but-crashing JS leftovers
here: `list.find()` (no such Jac list method), dot-access on setting-item
dicts (`item.label`, `item.currentValue`, `item.values`, ...), and
`options.enableSearch` dot-access on a plain options dict. This smoke
proves the Jac-native (bracket-access / explicit-loop) fixes run
correctly, and that the barrel `src/index.jac` imports cleanly.

Run: jac run smoke_settings_list.jac
"""

import from src.components.settings_list { SettingsList }
import from src.index { SettingsList as IndexSettingsList, Input as IndexInput }

obj SettingsTheme {
    def hint(text: str) -> str { return text; }
    def label(text: str, selected: bool) -> str { return (f"*{text}*" if selected else text); }
    def value(text: str, selected: bool) -> str { return text; }
    def description(text: str) -> str { return text; }
    has cursor: str = ">";
}

with entry {
    # Confirm the barrel module re-exports these symbols and binds them.
    assert IndexSettingsList is SettingsList;
    assert IndexInput is not None;

    items = [
        {"id": "sound", "label": "Sound", "currentValue": "on", "values": ["on", "off"]},
        {"id": "theme", "label": "Theme", "currentValue": "dark", "values": ["dark", "light", "auto"]},
        {"id": "volume", "label": "Volume Level", "currentValue": "50", "description": "How loud things are"},
    ];
    theme = SettingsTheme();
    changes: list[any] = [];
    cancels: list[bool] = [];
    onChange = lambda (id_j: str, newValue: str) -> None { changes.append((id_j, newValue)); };
    onCancel = lambda () -> None { cancels.append(True); };

    sl = SettingsList(items, 5, theme, onChange, onCancel, {"enableSearch": True});
    assert sl.selectedIndex == 0;
    assert sl.searchEnabled == True;
    assert sl.searchInput is not None;

    # --- render: shows all three labels, current values, and the hint line ---
    lines = sl.render(60.0);
    joined = "\n".join(lines);
    assert "Sound" in joined;
    assert "Theme" in joined;
    assert "Volume Level" in joined;
    assert "on" in joined;
    assert "dark" in joined;
    assert "Type to search" in joined;
    # selected item (index 0) is wrapped by the theme's label() marker
    assert "*Sound" in joined;

    # --- selection: down wraps at the end, up wraps at the start ---
    ESC = chr(27);
    sl.handleInput(f"{ESC}[B");   # down -> select "theme"
    assert sl.selectedIndex == 1;
    sl.handleInput(f"{ESC}[B");   # down -> select "volume"
    assert sl.selectedIndex == 2;
    sl.handleInput(f"{ESC}[B");   # down wraps -> back to "sound"
    assert sl.selectedIndex == 0;
    sl.handleInput(f"{ESC}[A");   # up wraps -> "volume"
    assert sl.selectedIndex == 2;

    # description line only shows for the selected item that has one
    lines2 = sl.render(60.0);
    assert "How loud things are" in "\n".join(lines2);

    # --- value cycling: confirm on "volume" has no values list, no-op ---
    before = items[2]["currentValue"];
    sl.handleInput(chr(13));   # enter -> confirm/activateItem
    assert items[2]["currentValue"] == before;
    assert len(changes) == 0;

    # move to "sound" (has values ["on", "off"]) and cycle it
    sl.handleInput(f"{ESC}[A");   # up -> "theme"
    sl.handleInput(f"{ESC}[A");   # up -> "sound"
    assert sl.selectedIndex == 0;
    sl.handleInput(" ");   # space -> confirm/activateItem, cycles on -> off
    assert items[0]["currentValue"] == "off";
    assert changes[-1] == ("sound", "off");
    sl.handleInput(" ");   # cycles off -> on (wraps)
    assert items[0]["currentValue"] == "on";
    assert changes[-1] == ("sound", "on");

    # --- fuzzy filter: narrow to just "Theme" via the search input ---
    sl.handleInput("t");
    sl.handleInput("h");
    sl.handleInput("e");
    sl.handleInput("m");
    assert sl.searchInput.getValue() == "them";
    assert len(sl.filteredItems) == 1;
    assert sl.filteredItems[0]["id"] == "theme";
    assert sl.selectedIndex == 0;
    linesFiltered = sl.render(60.0);
    joinedFiltered = "\n".join(linesFiltered);
    assert "Sound" not in joinedFiltered;
    assert "Theme" in joinedFiltered;

    # --- cancel callback wiring ---
    sl2 = SettingsList(items, 5, theme, onChange, onCancel, {});
    assert sl2.searchEnabled == False;
    assert sl2.searchInput is None;
    sl2.handleInput(ESC);
    assert len(cancels) == 1;

    # --- updateValue: direct lookup-by-id path ---
    sl2.updateValue("volume", "75");
    assert items[2]["currentValue"] == "75";

    print("smoke_settings_list: OK");
}
