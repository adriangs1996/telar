//! What one prompt field shows: the visible text, its cursor column and
//! selection, and whether it owns input.
const EditorView = @This();

text: []const u8,
cursor: u16,
selection: ?[2]u16 = null,
focused: bool,

/// Fits one bounded prompt field to `width` columns. The text borrows the
/// field, so the field must outlive the paint that uses the view.
/// Example: `const view = EditorView.capture(&prompt.directory, row.w, true);`
pub fn capture(source: anytype, width: u16, focused: bool) EditorView {
    const view = source.view(width);
    return .{ .text = view.text, .cursor = view.cursor, .selection = view.selection, .focused = focused };
}
