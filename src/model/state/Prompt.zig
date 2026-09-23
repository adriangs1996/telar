const core = @import("telar-core");
const copy_mode_module = @import("../input/copy_mode.zig");
const History = @import("History.zig");
const name_prompt = @import("name_prompt.zig");
const WorkspaceForm = @import("WorkspaceForm.zig");
const command_palette = @import("command_palette.zig");
const Prompt = @This();

/// Stable for one opening, unlike the revision advanced by every edit.
generation: u64 = 0,

mode: union(enum) {
    rename_tab: core.TabId,
    create_workspace: WorkspaceForm,
    rename_workspace: core.WorkspaceLocation,
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
pub fn target(self: *const Prompt) name_prompt.Target {
    return switch (self.mode) {
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
pub fn selection(self: *const Prompt) u16 {
    return switch (self.mode) {
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
pub fn paletteMode(self: *const Prompt) command_palette.Prefix {
    return if (self.mode == .palette) command_palette.prefixOf(self.field.text()) else .goto;
}

/// The palette text without its prefix byte; the whole field otherwise.
/// Example: `collect(sources, prompt.paletteQuery(), &results);`.
pub fn paletteQuery(self: *const Prompt) []const u8 {
    return if (self.mode == .palette) command_palette.query(self.field.text()) else self.field.text();
}

/// The new-context form state, or null for every other target.
/// Example: `if (prompt.form()) |form| paintDirectory(form.focus);`.
pub fn form(self: *const Prompt) ?*const WorkspaceForm {
    return if (self.mode == .create_workspace) &self.mode.create_workspace else null;
}

/// Example: `const scope = prompt.mode.history.scope();`.
pub fn scope(self: *const Prompt) name_prompt.HistoryScope {
    return if (self.mode == .history) self.mode.history.scope else .global;
}

/// Example: `if (prompt.mode.history.inspecting()) renderDetails();`.
pub fn inspecting(self: *const Prompt) bool {
    return self.mode == .history and self.mode.history.inspecting;
}

/// Example: `const scroll = prompt.detailScroll();`.
pub fn detailScroll(self: *const Prompt) u32 {
    return if (self.mode == .history) self.mode.history.detail_scroll else 0;
}

pub fn setSelection(self: *Prompt, selected: u16) void {
    switch (self.mode) {
        .goto => |*picker| picker.selection = selected,
        .history => |*history| history.selection = selected,
        .create_workspace => |*form_state| form_state.selection = selected,
        .palette => |*palette| palette.selection = selected,
        else => {},
    }
}
