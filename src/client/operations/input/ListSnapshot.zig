const HistoryScopeType = @import("../../model/name_prompt.zig").HistoryScope;
const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const ListSnapshot = @This();

/// `actions` is the palette's `>` list; the palette's `@` and `?` modes
/// snapshot as `goto` and `suggest` because they finish the same way.
kind: enum { none, goto, history, suggest, actions } = .none,
selection: u16 = 0,
scope: HistoryScopeType = .global,
alternate: bool = false,
text: [max_tab_label_bytes_module]u8 = undefined,
len: u8 = 0,

pub fn textSlice(snapshot: *const ListSnapshot) []const u8 {
    return snapshot.text[0..snapshot.len];
}
