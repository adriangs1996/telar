const core = @import("telar-core");
const FieldReplacement = @import("FieldReplacement.zig");
const PromptHistoryScope = @import("PromptHistoryScope.zig").PromptHistoryScope;
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
    /// Shift+Tab: moves the new-context form back to the previous field or
    /// cycles the history author filter.
    back_tab,
    /// A chip click: one exact history scope instead of the Tab cycle.
    select_scope: PromptHistoryScope,
    /// A chip click: one exact history author filter.
    select_author: core.HistoryAuthorFilter,
    /// Shows only failed commands, or all of them again.
    toggle_failed,
    remove_entry,
    /// Ctrl+R: renames the selected machine of the palette's machine list.
    rename_entry,
    /// Puts the selected command on the host clipboard.
    copy_entry,
    /// Leaves the palette on the pane the selected command ran in.
    visit_pane,
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
