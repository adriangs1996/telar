const ListSnapshot = @This();
const prompt_state = @import("telar-client").model.name_prompt;
const source_namespace = @import("name_prompts.zig");
kind: enum { none, goto, history, suggest } = .none,
selection: u16 = 0,
scope: prompt_state.HistoryScope = .global,
alternate: bool = false,
text: [source_namespace.schema.max_tab_label_bytes]u8 = undefined,
len: u8 = 0,

pub fn textSlice(snapshot: *const ListSnapshot) []const u8 {
    return snapshot.text[0..snapshot.len];
}
