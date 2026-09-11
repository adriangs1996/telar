const ModelType = @import("../../model/Model.zig");
const WorkspaceCreationGate = @import("WorkspaceCreationGate.zig");
const name_prompt_opening = @import("name_prompt_opening.zig");
const name_prompt = @import("../../model/name_prompt.zig");
const OpenNamePromptHandler = @This();

model: *ModelType,
workspace_creation: WorkspaceCreationGate,

/// Opens one prompt only when input is unowned and its canonical target
/// exists. Workspace creation additionally requires an actionable launch
/// source and no request already in flight.
///
/// ```zig
/// if (!handler.execute(.rename_active_tab)) return;
/// ```
pub fn execute(handler: *OpenNamePromptHandler, intent: name_prompt_opening.Intent) bool {
    if (handler.model.panePasteActive()) {
        return false;
    }
    if (intent == .copy_search) {
        if (!handler.model.copyModeActive()) {
            return false;
        }

        handler.model.name_prompt.begin(.{ .copy_search = intent.copy_search });
        return true;
    }
    if (handler.model.copyModeActive()) {
        return false;
    }

    const command: name_prompt.Begin = switch (intent) {
        .create_workspace => create: {
            if (handler.workspace_creation.pending(handler.workspace_creation.context)) {
                return false;
            }
            if (handler.model.planWorkspaceCreation() == null) {
                return false;
            }

            break :create .create_workspace;
        },
        .rename_workspace => rename: {
            const workspace = handler.model.workspaceLocation() orelse return false;
            break :rename .{ .rename_workspace = .{
                .workspace = workspace,
                .name = handler.model.workspace.workspaceName(),
            } };
        },
        .rename_active_tab => rename: {
            const active = handler.model.workspace.activeConst() orelse return false;
            break :rename name_prompt_opening.renameTab(active.location.tab_id, active.labelSlice());
        },
        .rename_tab => |tab_id| rename: {
            const tab = handler.model.workspace.find(tab_id) orelse return false;
            break :rename name_prompt_opening.renameTab(tab_id, tab.labelSlice());
        },
        .goto_picker => .goto_picker,
        .history_palette => .history_palette,
        .suggest_palette => .suggest_palette,
        .copy_search => unreachable,
    };

    handler.model.name_prompt.begin(command);
    return true;
}
