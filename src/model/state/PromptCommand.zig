const FieldReplacement = @import("FieldReplacement.zig");
const WorkspaceForm = @import("WorkspaceForm.zig");

pub const PromptCommand = union(enum) {
    focus_field: WorkspaceForm.Focus,
    select_range: [2]u32,
    select_all,
    replace_range: FieldReplacement,
    paste_start,
    paste_end,
    insert: []const u8,
    move_up,
    move_down,
    /// Tab: cycles the history scope, moves the new-context form from the
    /// name to the directory or asks for the selected path completion.
    tab,
    /// Shift+Tab: moves the new-context form back to the previous field.
    back_tab,
    remove_entry,
    toggle_inspection,
    page_up,
    page_down,
    submit,
    submit_alternate,
    cancel,
    backspace,
    delete,
    move_left: bool,
    move_right: bool,
    home: bool,
    end: bool,
};
