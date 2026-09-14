const TabIdType = @import("telar-core").TabId;
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const copy_mode_module = @import("../input/copy_mode.zig");
const History = @import("History.zig");
const name_prompt = @import("name_prompt.zig");
const WorkspaceForm = @import("WorkspaceForm.zig");
const command_palette = @import("command_palette.zig");
const Prompt = @This();

mode: union(enum) {
    rename_tab: TabIdType,
    create_workspace: WorkspaceForm,
    rename_workspace: WorkspaceLocationType,
    copy_search: copy_mode_module.Direction,
    goto: struct { selection: u16 = 0 },
    history: History,
    suggest,
    palette: struct { selection: u16 = 0 },
},
field: name_prompt.Field,
/// Working directory of the new-context form; unused by other targets.
directory: name_prompt.DirectoryField = .{},
pasting: bool = false,

/// Example: `switch (prompt.target()) { ... }`.
pub fn target(prompt: *const Prompt) name_prompt.Target {
    return switch (prompt.mode) {
        .rename_tab => |id| .{ .rename_tab = id },
        .create_workspace => .create_workspace,
        .rename_workspace => |location| .{ .rename_workspace = location },
        .copy_search => |direction| .{ .copy_search = direction },
        .goto => .goto,
        .history => .history,
        .suggest => .suggest,
        .palette => .palette,
    };
}

/// Example: `const selected = prompt.selection();`.
pub fn selection(prompt: *const Prompt) u16 {
    return switch (prompt.mode) {
        .goto => |picker| picker.selection,
        .history => |history| history.selection,
        .create_workspace => |form_state| form_state.selection,
        .palette => |palette| palette.selection,
        else => 0,
    };
}

/// Which list the palette field currently drives; `.goto` for every other
/// target so callers can treat the plain picker and `@` alike.
/// Example: `if (prompt.paletteMode() == .actions) listActions();`.
pub fn paletteMode(prompt: *const Prompt) command_palette.Prefix {
    return if (prompt.mode == .palette) command_palette.prefixOf(prompt.field.text()) else .goto;
}

/// The palette text without its prefix byte; the whole field otherwise.
/// Example: `collect(sources, prompt.paletteQuery(), &results);`.
pub fn paletteQuery(prompt: *const Prompt) []const u8 {
    return if (prompt.mode == .palette) command_palette.query(prompt.field.text()) else prompt.field.text();
}

/// The new-context form state, or null for every other target.
/// Example: `if (prompt.form()) |form| paintDirectory(form.focus);`.
pub fn form(prompt: *const Prompt) ?*const WorkspaceForm {
    return if (prompt.mode == .create_workspace) &prompt.mode.create_workspace else null;
}

/// Example: `const scope = prompt.mode.history.scope();`.
pub fn scope(prompt: *const Prompt) name_prompt.HistoryScope {
    return if (prompt.mode == .history) prompt.mode.history.scope else .global;
}

/// Example: `if (prompt.mode.history.inspecting()) renderDetails();`.
pub fn inspecting(prompt: *const Prompt) bool {
    return prompt.mode == .history and prompt.mode.history.inspecting;
}

/// Example: `const scroll = prompt.detailScroll();`.
pub fn detailScroll(prompt: *const Prompt) u32 {
    return if (prompt.mode == .history) prompt.mode.history.detail_scroll else 0;
}

pub fn setSelection(prompt: *Prompt, selected: u16) void {
    switch (prompt.mode) {
        .goto => |*picker| picker.selection = selected,
        .history => |*history| history.selection = selected,
        .create_workspace => |*form_state| form_state.selection = selected,
        .palette => |*palette| palette.selection = selected,
        else => {},
    }
}
