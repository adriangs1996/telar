const core = @import("telar-core");
const AgentKey = @import("../agents/AgentKey.zig");
const copy_mode = @import("../input/copy_mode.zig");
const command_palette = @import("command_palette.zig");

pub const PromptBegin = union(enum) {
    copy_search: copy_mode.Direction,
    rename_tab: struct {
        tab_id: core.TabId,
        label: []const u8,
    },
    create_workspace,
    rename_workspace: struct {
        workspace: core.WorkspaceLocation,
        name: []const u8,
    },
    goto_picker,
    history_palette,
    suggest_palette,
    path_picker,
    /// Opens the palette with the prefix already typed.
    palette: command_palette.Prefix,
    peek: AgentKey,
};
