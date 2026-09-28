//! Application policy for opening one bounded name prompt from current client
//! authority and canonical model state.
const core = @import("telar-core");
const model_data = @import("model");

pub const Intent = union(enum) {
    create_workspace,
    rename_workspace,
    rename_active_tab,
    rename_tab: core.TabId,
    /// Copy-mode search input; the only prompt allowed while copy mode is
    /// active, and meaningless outside it.
    copy_search: model_data.CopyModeDirection,
    goto_picker,
    history_palette,
    suggest_palette,
    path_picker,
    /// The command palette with its prefix already typed.
    palette: model_data.CommandPalettePrefix,
    /// A peek at one agent, opened from its task card.
    peek: model_data.AgentKey,
};

pub fn renameTab(tab_id: core.TabId, label: []const u8) model_data.PromptBegin {
    return .{ .rename_tab = .{
        .tab_id = tab_id,
        .label = label,
    } };
}
