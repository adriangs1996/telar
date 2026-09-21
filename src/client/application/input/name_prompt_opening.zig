//! Application policy for opening one bounded name prompt from current client
//! authority and canonical model state.

const TabIdType = @import("telar-core").TabId;
const copy_mode = @import("../../input/copy_mode.zig");
const name_prompt = @import("../../model/name_prompt.zig");
const ModelType = @import("../../model/Model.zig");
const command_palette = @import("../../model/command_palette.zig");
const std = @import("std");

pub const Intent = union(enum) {
    create_workspace,
    rename_workspace,
    rename_active_tab,
    rename_tab: TabIdType,
    /// Copy-mode search input; the only prompt allowed while copy mode is
    /// active, and meaningless outside it.
    copy_search: copy_mode.Direction,
    goto_picker,
    history_palette,
    suggest_palette,
    /// The command palette with its prefix already typed.
    palette: command_palette.Prefix,
};

pub fn renameTab(tab_id: TabIdType, label: []const u8) name_prompt.Begin {
    return .{ .rename_tab = .{
        .tab_id = tab_id,
        .label = label,
    } };
}

fn cancelPrompt(model: *ModelType) !void {
    if (model.name_prompt.apply(.cancel) != .cancelled) {
        return error.PromptNotCancelled;
    }
}
