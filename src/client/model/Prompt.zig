const Prompt = @This();
const source_namespace = @import("name_prompt.zig");
const History = @import("History.zig");
mode: union(enum) {
    rename_tab: source_namespace.schema.TabId,
    create_workspace,
    rename_workspace: source_namespace.schema.WorkspaceLocation,
    copy_search: source_namespace.copy_mode.Direction,
    goto: struct { selection: u16 = 0 },
    history: History,
    suggest,
},
field: source_namespace.Field,
pasting: bool = false,

/// Example: `switch (prompt.target()) { ... }`.
pub fn target(prompt: *const Prompt) source_namespace.Target {
    return switch (prompt.mode) {
        .rename_tab => |id| .{ .rename_tab = id },
        .create_workspace => .create_workspace,
        .rename_workspace => |location| .{ .rename_workspace = location },
        .copy_search => |direction| .{ .copy_search = direction },
        .goto => .goto,
        .history => .history,
        .suggest => .suggest,
    };
}

/// Example: `const selected = prompt.selection();`.
pub fn selection(prompt: *const Prompt) u16 {
    return switch (prompt.mode) {
        .goto => |picker| picker.selection,
        .history => |history| history.selection,
        else => 0,
    };
}

/// Example: `const scope = prompt.mode.history.scope();`.
pub fn scope(prompt: *const Prompt) source_namespace.HistoryScope {
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
        else => {},
    }
}
