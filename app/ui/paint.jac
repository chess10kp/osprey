"""Retired: region paint now lives in ui.renderer (OSPUI-P0-PLAN Unit 6).

The legacy flat compose_layout / paint_frame path depended on renderer state
stored on UiNode fields. Retained layout + damage rendering replaced it.
"""

def paint_frame(root_view: any, width: int, write: any) -> list {
    _ = (root_view, width, write);
    raise NotImplementedError(
        "ui.paint is retired; use ui.renderer.render_frame"
    );
}
