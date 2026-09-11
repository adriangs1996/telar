const HistoryScopeType = @import("telar-client").HistoryScope;
const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const ListSnapshot = @This();

kind: enum { none, goto, history, suggest } = .none,
selection: u16 = 0,
scope: HistoryScopeType = .global,
alternate: bool = false,
text: [max_tab_label_bytes_module]u8 = undefined,
len: u8 = 0,

pub fn textSlice(snapshot: *const ListSnapshot) []const u8 {
    return snapshot.text[0..snapshot.len];
}
