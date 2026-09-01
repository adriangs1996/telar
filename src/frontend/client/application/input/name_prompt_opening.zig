//! Application policy for opening one bounded name prompt from current client
//! authority and canonical model state.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../model/root.zig");
const name_prompt = @import("../../model/name_prompt.zig");

const schema = core.schema;

pub const Intent = union(enum) {
    create_workspace,
    rename_workspace,
    rename_active_tab,
    rename_tab: schema.TabId,
    /// Copy-mode search input; the only prompt allowed while copy mode is
    /// active, and meaningless outside it.
    copy_search: name_prompt.Direction,
    goto_picker,
};

pub const WorkspaceCreationGate = struct {
    context: *anyopaque,
    pending: *const fn (*anyopaque) bool,
};

pub const OpenNamePromptHandler = struct {
    model: *client_model.Model,
    workspace_creation: WorkspaceCreationGate,

    /// Opens one prompt only when input is unowned and its canonical target
    /// exists. Workspace creation additionally requires an actionable launch
    /// source and no request already in flight.
    ///
    /// ```zig
    /// if (!handler.execute(.rename_active_tab)) return;
    /// ```
    pub fn execute(handler: *OpenNamePromptHandler, intent: Intent) bool {
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
                break :rename renameTab(active.location.tab_id, active.labelSlice());
            },
            .rename_tab => |tab_id| rename: {
                const tab = handler.model.workspace.find(tab_id) orelse return false;
                break :rename renameTab(tab_id, tab.labelSlice());
            },
            .goto_picker => .goto_picker,
            .copy_search => unreachable,
        };

        handler.model.name_prompt.begin(command);
        return true;
    }
};

fn renameTab(tab_id: schema.TabId, label: []const u8) name_prompt.Begin {
    return .{ .rename_tab = .{
        .tab_id = tab_id,
        .label = label,
    } };
}

const TestingModel = struct {
    model: *client_model.Model,
    workspace: schema.WorkspaceLocation,
    first: schema.TabLocation,
    second: schema.TabLocation,
    first_pane: schema.PaneId,

    fn init() !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();

        const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
        const first: schema.TabLocation = .{
            .workspace = workspace,
            .tab_id = @enumFromInt(1),
        };
        const second: schema.TabLocation = .{
            .workspace = workspace,
            .tab_id = @enumFromInt(2),
        };
        const first_pane: schema.PaneId = @enumFromInt(1);
        try model.workspace.bootstrap(first_pane, first, .{ .cols = 40, .rows = 10 });
        _ = try model.workspace.addCreated(.{
            .location = second,
            .position = 1,
            .label = "logs",
            .root_pane_id = @enumFromInt(2),
        }, .{ .cols = 40, .rows = 10 });
        if (!model.workspace.select(first.tab_id)) {
            return error.ActiveTabNotRestored;
        }

        _ = try model.reconcileWorkspace(.{
            .workspace = workspace,
            .name = "project",
            .tabs = &.{
                .{ .tab_id = first.tab_id, .pane_count = 1, .label = "main" },
                .{ .tab_id = second.tab_id, .pane_count = 1, .label = "logs" },
            },
        });

        return .{
            .model = model,
            .workspace = workspace,
            .first = first,
            .second = second,
            .first_pane = first_pane,
        };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }
};

const GateCapture = struct {
    blocked: bool = false,
    calls: usize = 0,

    fn handler(capture: *GateCapture, model: *client_model.Model) OpenNamePromptHandler {
        return .{
            .model = model,
            .workspace_creation = .{
                .context = capture,
                .pending = pending,
            },
        };
    }

    fn pending(context: *anyopaque) bool {
        const capture: *GateCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;

        return capture.blocked;
    }
};

fn cancelPrompt(model: *client_model.Model) !void {
    if (model.name_prompt.apply(.cancel) != .cancelled) {
        return error.PromptNotCancelled;
    }
}

test "OpenNamePromptHandler copies every canonical opening target" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: GateCapture = .{};
    var handler = capture.handler(testing.model);

    try std.testing.expect(handler.execute(.create_workspace));
    try std.testing.expect(testing.model.name_prompt.currentConst().?.target == .create_workspace);
    try std.testing.expectEqualStrings("", testing.model.name_prompt.currentConst().?.field.text());
    try cancelPrompt(testing.model);

    try std.testing.expect(handler.execute(.rename_workspace));
    try std.testing.expectEqualDeep(
        name_prompt.Target{ .rename_workspace = testing.workspace },
        testing.model.name_prompt.currentConst().?.target,
    );
    try std.testing.expectEqualStrings("project", testing.model.name_prompt.currentConst().?.field.text());
    try cancelPrompt(testing.model);

    try std.testing.expect(handler.execute(.rename_active_tab));
    try std.testing.expectEqualDeep(
        name_prompt.Target{ .rename_tab = testing.first.tab_id },
        testing.model.name_prompt.currentConst().?.target,
    );
    try std.testing.expectEqualStrings("main", testing.model.name_prompt.currentConst().?.field.text());
    try cancelPrompt(testing.model);

    try std.testing.expect(handler.execute(.{ .rename_tab = testing.second.tab_id }));
    try std.testing.expectEqualDeep(
        name_prompt.Target{ .rename_tab = testing.second.tab_id },
        testing.model.name_prompt.currentConst().?.target,
    );
    try std.testing.expectEqualStrings("logs", testing.model.name_prompt.currentConst().?.field.text());
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}

test "OpenNamePromptHandler rejects copy and pane-paste input authority" {
    const intents = [_]Intent{
        .create_workspace,
        .rename_workspace,
        .rename_active_tab,
        .{ .rename_tab = @enumFromInt(2) },
        .goto_picker,
    };

    var copy = try TestingModel.init();
    defer copy.deinit();
    try std.testing.expect(copy.model.enterCopyMode());
    const copy_version = copy.model.version();
    var copy_capture: GateCapture = .{};
    var copy_handler = copy_capture.handler(copy.model);
    for (intents) |intent| {
        try std.testing.expect(!copy_handler.execute(intent));
    }
    try std.testing.expect(!copy.model.name_prompt.active());
    try std.testing.expectEqualDeep(copy_version, copy.model.version());
    try std.testing.expectEqual(@as(usize, 0), copy_capture.calls);

    var paste = try TestingModel.init();
    defer paste.deinit();
    _ = paste.model.beginPanePaste().?;
    const paste_version = paste.model.version();
    var paste_capture: GateCapture = .{};
    var paste_handler = paste_capture.handler(paste.model);
    for (intents) |intent| {
        try std.testing.expect(!paste_handler.execute(intent));
    }
    try std.testing.expect(!paste.model.name_prompt.active());
    try std.testing.expectEqualDeep(paste_version, paste.model.version());
    try std.testing.expectEqual(@as(usize, 0), paste_capture.calls);
}

test "OpenNamePromptHandler gates only workspace creation availability" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: GateCapture = .{ .blocked = true };
    var handler = capture.handler(testing.model);

    try std.testing.expect(!handler.execute(.create_workspace));
    try std.testing.expect(!testing.model.name_prompt.active());
    try std.testing.expectEqual(@as(usize, 1), capture.calls);

    capture.blocked = false;
    testing.model.workspace.findPane(testing.first_pane).?.attached = false;
    try std.testing.expect(!handler.execute(.create_workspace));
    try std.testing.expectEqual(@as(usize, 2), capture.calls);

    try std.testing.expect(handler.execute(.rename_workspace));
    try std.testing.expectEqualStrings("project", testing.model.name_prompt.currentConst().?.field.text());
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
}

test "OpenNamePromptHandler rejects missing rename targets without mutation" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: GateCapture = .{};
    var handler = capture.handler(testing.model);
    const version = testing.model.version();

    try std.testing.expect(!handler.execute(.{ .rename_tab = @enumFromInt(9) }));
    try std.testing.expect(!testing.model.name_prompt.active());
    try std.testing.expectEqualDeep(version, testing.model.version());

    _ = testing.model.departWorkspace();
    const departed_version = testing.model.version();
    try std.testing.expect(!handler.execute(.rename_workspace));
    try std.testing.expect(!handler.execute(.rename_active_tab));
    try std.testing.expect(!testing.model.name_prompt.active());
    try std.testing.expectEqualDeep(departed_version, testing.model.version());
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
}

test "OpenNamePromptHandler opens the goto picker without extra gates" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: GateCapture = .{ .blocked = true };
    var handler = capture.handler(testing.model);

    try std.testing.expect(handler.execute(.goto_picker));
    const prompt = testing.model.name_prompt.currentConst().?;
    try std.testing.expect(prompt.target == .goto);
    try std.testing.expectEqualStrings("", prompt.field.text());
    try std.testing.expectEqual(@as(u16, 0), prompt.selection);
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
}
