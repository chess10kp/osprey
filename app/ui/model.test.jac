"""Behavior tests for the OSP UI model."""


def _literal_renderer(text: str, calls: list[int]) -> any {
    def render(_node: UiNode, _width: int) -> list[str] {
        calls[0] += 1;
        return [text];
    }
    return render;
}


def _signal_renderer(source: SignalNode, calls: list[int]) -> any {
    def render(_node: UiNode, _width: int) -> list[str] {
        calls[0] += 1;
        return [str(read_signal(source))];
    }
    return render;
}


def _dynamic_renderer(
    choose_a: SignalNode,
    source_a: SignalNode,
    source_b: SignalNode,
) -> any {
    def render(_node: UiNode, _width: int) -> list[str] {
        if bool(read_signal(choose_a)) {
            return [str(read_signal(source_a))];
        }
        return [str(read_signal(source_b))];
    }
    return render;
}


test "ordered Child edges project through the component adapter" {
    reset_ui_runtime();
    a_calls = [0];
    b_calls = [0];
    a = view(_literal_renderer("a", a_calls), kind="text", key="a");
    b = view(_literal_renderer("b", b_calls), kind="text", key="b");
    tree = column([a, b]);
    component = project(tree);

    assert component.render(80.0) == ["a", "b"];
    assert component.render(80.0) == ["a", "b"];
    assert [n.key for n in ordered_children(tree)] == ["a", "b"];
    assert a_calls[0] == 1;
    assert b_calls[0] == 1;

    move(b, 0);
    assert component.render(80.0) == ["b", "a"];
    assert [n.key for n in ordered_children(tree)] == ["b", "a"];
    assert a_calls[0] == 1;
    assert b_calls[0] == 1;

    dispose_tree(tree);
    assert registered_view_count() == 0;
}


test "signal writes invalidate one leaf path and coalesce render requests" {
    reset_ui_runtime();
    requests: list[int] = [];
    request = lambda { requests.append(1); };
    set_render_request_hook(request);

    left_signal = signal("left-0");
    right_signal = signal("right-0");
    left_calls = [0];
    right_calls = [0];
    left = view(_signal_renderer(left_signal, left_calls), key="left");
    right = view(_signal_renderer(right_signal, right_calls), key="right");
    tree = column([left, right]);
    own_signal(tree, left_signal);
    own_signal(tree, right_signal);

    assert project(tree).render(80.0) == ["left-0", "right-0"];
    assert left_calls[0] == 1;
    assert right_calls[0] == 1;

    set_signal(left_signal, "left-1");
    set_signal(left_signal, "left-2");
    assert len(requests) == 1;
    assert left.dirty;
    assert tree.dirty;
    assert not right.dirty;

    assert render_node(tree, 80) == ["left-2", "right-0"];
    assert left_calls[0] == 2;
    assert right_calls[0] == 1;

    set_signal(right_signal, "right-0");
    assert len(requests) == 1;
    dispose_tree(tree);
}


test "dynamic reads replace Feeds edges exactly" {
    reset_ui_runtime();
    choose_a = signal(True);
    source_a = signal("a");
    source_b = signal("b");
    leaf = view(_dynamic_renderer(choose_a, source_a, source_b), key="dynamic");
    tree = column([leaf]);
    own_signal(tree, choose_a);
    own_signal(tree, source_a);
    own_signal(tree, source_b);

    assert render_node(tree, 80) == ["a"];
    assert choose_a in [leaf <-:Feeds:<-];
    assert source_a in [leaf <-:Feeds:<-];
    assert source_b not in [leaf <-:Feeds:<-];

    set_signal(choose_a, False);
    assert render_node(tree, 80) == ["b"];
    assert source_a not in [leaf <-:Feeds:<-];
    assert source_b in [leaf <-:Feeds:<-];

    set_signal(source_a, "stale");
    assert not leaf.dirty;
    set_signal(source_b, "fresh");
    assert leaf.dirty;
    assert render_node(tree, 80) == ["fresh"];

    dispose_tree(tree);
}


test "projected input mutates signals without renderer-specific state" {
    reset_ui_runtime();
    text = signal("");

    def render_input(_node: UiNode, _width: int) -> list[str] {
        return [str(read_signal(text))];
    }

    def accept_input(_node: UiNode, data: str) {
        set_signal(text, str(read_signal(text)) + data);
    }

    input_view = view(render_input, accept_input, kind="input");
    own_signal(input_view, text);
    component = project(input_view);

    assert component.render(40.0) == [""];
    component.focused = True;
    component.handleInput("x");
    assert component.render(40.0) == ["x"];
    component.invalidate();
    assert input_view.dirty;

    dispose_tree(input_view);
}


test "dispose runs cleanups and disconnects an unowned signal" {
    reset_ui_runtime();
    requests: list[int] = [];
    set_render_request_hook(lambda { requests.append(1); });
    source = signal("live");
    calls = [0];
    cleaned = [0];
    leaf = view(_signal_renderer(source, calls), key="leaf");
    cleanup = lambda { cleaned.__setitem__(0, cleaned[0] + 1); };
    on_cleanup(leaf, cleanup);

    assert render_node(leaf, 80) == ["live"];
    assert registered_view_count() == 1;
    dispose_tree(leaf);
    assert cleaned[0] == 1;
    assert registered_view_count() == 0;
    assert len([source ->:Feeds:->]) == 0;

    set_signal(source, "after-dispose");
    assert len(requests) == 0;
    assert calls[0] == 1;
    dispose_signal(source);
}
