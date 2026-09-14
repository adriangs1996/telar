//! The same bounded provisional value drives glyphs and native caret queries.
const GenericField = @import("telar-client").GenericField;
const FieldView = @import("FieldView.zig");
const Preedit = @import("Preedit.zig");
const Display = @This();

field: GenericField(8192),
provisional: bool = false,

/// Surrounding text remains untouched; only this local display copy changes.
/// Example: `var display = EditorDisplay.capture(committed, preedit);`
pub fn capture(committed: FieldView, preedit: ?*const Preedit) Display {
    var display: Display = .{ .field = .init(committed.text) };
    _ = display.field.selectRange(.{ committed.anchor, committed.head });
    if (preedit) |edit| {
        if (edit.replacement[0] <= edit.replacement[1] and committed.validRange(edit.replacement)) {
            _ = display.field.replace(edit.replacement, edit.text());
            _ = display.field.selectRange(.{ edit.replacement[0] + edit.selection[0], edit.replacement[0] + edit.selection[1] });
            display.provisional = true;
        }
    }

    return display;
}
