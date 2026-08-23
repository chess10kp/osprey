"""Parity corpus driver: runs all cases via `jac run` (bypasses pytest)."""

import from ui.layout_corpus_cases {
    _case_content_matrix_parity_empty_ascii_cjk_emoji_overwide_overtall,
    _case_horizontal_row_container_parity,
    _case_nested_column_with_three_grow_children_uses_approved_lr_split,
    _case_overlay_placement_and_clip_parity,
    _case_shell_parity_holds_across_the_full_viewport_matrix,
    _case_wrapped_transcript_and_scroll_clamp_parity,
}

with entry {
    cases: list = [
        ("shell x viewport matrix",
         _case_shell_parity_holds_across_the_full_viewport_matrix),
        ("wrapped + scroll clamp",
         _case_wrapped_transcript_and_scroll_clamp_parity),
        ("content matrix",
         _case_content_matrix_parity_empty_ascii_cjk_emoji_overwide_overtall),
        ("horizontal row",
         _case_horizontal_row_container_parity),
        ("nested 3-grow LR",
         _case_nested_column_with_three_grow_children_uses_approved_lr_split),
        ("overlay placement/clip",
         _case_overlay_placement_and_clip_parity),
    ];
    for pair in cases {
        label = pair[1]();
        print("PASS", pair[0], "->", label);
    }
    print("CORPUS: all green");
}
