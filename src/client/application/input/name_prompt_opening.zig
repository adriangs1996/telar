//! Application policy for opening one bounded name prompt from current client
//! authority and canonical model state.

const TabIdType = @import("telar-core").TabId;
const copy_mode = @import("../../input/copy_mode.zig");
const name_prompt = @import("../../model/name_prompt.zig");
const ModelType = @import("../../model/Model.zig");
const NamePromptOpeningTestingModel = @import("NamePromptOpeningTestingModel.zig");
const GateCapture = @import("GateCapture.zig");
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

test "OpenNamePromptHandler copies every canonical opening target" {
    var testing = try NamePromptOpeningTestingModel.init();
    defer testing.deinit();
    var capture: GateCapture = .{};
    var handler = capture.handler(testing.model);

    try std.testing.expect(handler.execute(.create_workspace));
    try std.testing.expect(testing.model.name_prompt.currentConst().?.target() == .create_workspace);
    try std.testing.expectEqualStrings("", testing.model.name_prompt.currentConst().?.field.text());
    try cancelPrompt(testing.model);

    try std.testing.expect(handler.execute(.rename_workspace));
    try std.testing.expectEqualDeep(
        name_prompt.Target{ .rename_workspace = testing.workspace },
        testing.model.name_prompt.currentConst().?.target(),
    );
    try std.testing.expectEqualStrings("project", testing.model.name_prompt.currentConst().?.field.text());
    try cancelPrompt(testing.model);

    try std.testing.expect(handler.execute(.rename_active_tab));
    try std.testing.expectEqualDeep(
        name_prompt.Target{ .rename_tab = testing.first.tab_id },
        testing.model.name_prompt.currentConst().?.target(),
    );
    try std.testing.expectEqualStrings("main", testing.model.name_prompt.currentConst().?.field.text());
    try cancelPrompt(testing.model);

    try std.testing.expect(handler.execute(.{ .rename_tab = testing.second.tab_id }));
    try std.testing.expectEqualDeep(
        name_prompt.Target{ .rename_tab = testing.second.tab_id },
        testing.model.name_prompt.currentConst().?.target(),
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
        .history_palette,
        .suggest_palette,
    };

    var copy = try NamePromptOpeningTestingModel.init();
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

    var paste = try NamePromptOpeningTestingModel.init();
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
    var testing = try NamePromptOpeningTestingModel.init();
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
    var testing = try NamePromptOpeningTestingModel.init();
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
    var testing = try NamePromptOpeningTestingModel.init();
    defer testing.deinit();
    var capture: GateCapture = .{ .blocked = true };
    var handler = capture.handler(testing.model);

    try std.testing.expect(handler.execute(.goto_picker));
    const prompt = testing.model.name_prompt.currentConst().?;
    try std.testing.expect(prompt.target() == .goto);
    try std.testing.expectEqualStrings("", prompt.field.text());
    try std.testing.expectEqual(@as(u16, 0), prompt.selection());
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
}
