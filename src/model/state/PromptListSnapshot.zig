const name_prompt = @import("name_prompt.zig");
const core = @import("telar-core");
const PromptListSnapshot = @This();

/// `actions` is the palette's `>` list; the palette's `@` and `?` modes
/// snapshot as `goto` and `suggest` because they finish the same way.
kind: enum { none, goto, history, suggest, actions } = .none,
selection: u16 = 0,
scope: name_prompt.HistoryScope = .global,
alternate: bool = false,
text: [core.max_tab_label_bytes]u8 = undefined,
len: u8 = 0,

/// Borrows the prompt text captured before submission.
/// Example: `const text = snapshot.textSlice();`
pub fn textSlice(self: *const PromptListSnapshot) []const u8 {
    return self.text[0..self.len];
}
