//! Application use cases for requesting and confirming a tab rename.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../root.zig").model;

pub const schema = core.schema;

pub const RequestRenameTab = @import("RequestRenameTab.zig");

pub const TabRenameIntent = @import("TabRenameIntent.zig");

pub const TabOperationGate = @import("RenameTabTabOperationGate.zig");

pub const RenameRequestEffects = @import("RenameRequestEffects.zig");

pub const RequestRenameTabHandler = @import("RequestRenameTabHandler.zig");

pub const ConfirmTabRename = client_model.RenameTab;

pub const ConfirmTabRenameHandler = @import("ConfirmTabRenameHandler.zig");

pub fn validateLabel(label: []const u8) !void {
    if (label.len == 0 or label.len > schema.max_tab_label_bytes) {
        return error.InvalidTabLabel;
    }
    if (!std.unicode.utf8ValidateSlice(label)) {
        return error.InvalidUtf8;
    }
    for (label) |byte| {
        if (byte < 0x20 or byte == 0x7f) {
            return error.InvalidTabLabel;
        }
    }
}

const RequestCapture = @import("RenameTabRequestCapture.zig");

const TestingModel = @import("RenameTabTestingModel.zig");

test "tab rename request resolves an inactive target without mutation" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RequestCapture = .{};
    var handler: RequestRenameTabHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.effects(),
    };

    try std.testing.expect(try handler.execute(.{
        .tab_id = testing.second.tab_id,
        .label = "server",
    }));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualDeep(testing.second, capture.location.?);
    try std.testing.expectEqualStrings("server", capture.labelSlice());
    try std.testing.expectEqualStrings("logs", testing.model.workspace.find(testing.second.tab_id).?.labelSlice());
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "tab rename request suppresses blocked and missing targets" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RequestCapture = .{ .blocked = true };
    var handler: RequestRenameTabHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.effects(),
    };

    try std.testing.expect(!try handler.execute(.{
        .tab_id = testing.second.tab_id,
        .label = "blocked",
    }));
    capture.blocked = false;
    try std.testing.expect(!try handler.execute(.{
        .tab_id = @enumFromInt(9),
        .label = "missing",
    }));

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "tab rename request rejects invalid labels before delivery" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RequestCapture = .{};
    var handler: RequestRenameTabHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.effects(),
    };
    const invalid_utf8 = [_]u8{0xff};
    const too_long = [_]u8{'x'} ** (schema.max_tab_label_bytes + 1);

    try std.testing.expectError(error.InvalidTabLabel, handler.execute(.{
        .tab_id = testing.first.tab_id,
        .label = "",
    }));
    try std.testing.expectError(error.InvalidTabLabel, handler.execute(.{
        .tab_id = testing.first.tab_id,
        .label = "bad\nlabel",
    }));
    try std.testing.expectError(error.InvalidTabLabel, handler.execute(.{
        .tab_id = testing.first.tab_id,
        .label = &too_long,
    }));
    try std.testing.expectError(error.InvalidUtf8, handler.execute(.{
        .tab_id = testing.first.tab_id,
        .label = &invalid_utf8,
    }));

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "tab rename request propagates delivery failure without mutation" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RequestCapture = .{ .failure = error.DeliveryFailed };
    var handler: RequestRenameTabHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.effects(),
    };

    try std.testing.expectError(error.DeliveryFailed, handler.execute(.{
        .tab_id = testing.first.tab_id,
        .label = "server",
    }));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualStrings("main", testing.model.workspace.find(testing.first.tab_id).?.labelSlice());
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "tab rename confirmation commits the canonical label without changing active identity" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var handler: ConfirmTabRenameHandler = .{ .model = testing.model };

    const change = try handler.execute(.{
        .location = testing.second,
        .label = "canonical",
    });

    try std.testing.expectEqual(client_model.Change.changed, change);
    try std.testing.expectEqualStrings("canonical", testing.model.workspace.find(testing.second.tab_id).?.labelSlice());
    try std.testing.expectEqualDeep(testing.first, testing.model.activeTabLocation().?);
    try std.testing.expectEqual(@as(u64, 1), testing.model.version().tabs);
    try std.testing.expectEqual(@as(u64, 0), testing.model.version().active_tab);
}

test "tab rename confirmation preserves the version for a canonical no-op" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var handler: ConfirmTabRenameHandler = .{ .model = testing.model };

    const change = try handler.execute(.{
        .location = testing.second,
        .label = "logs",
    });

    try std.testing.expectEqual(client_model.Change.unchanged, change);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "tab rename confirmation rejects invalid canonical state without mutation" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var handler: ConfirmTabRenameHandler = .{ .model = testing.model };
    const other_workspace: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(9) },
        .tab_id = testing.second.tab_id,
    };
    const missing_tab: schema.TabLocation = .{
        .workspace = testing.first.workspace,
        .tab_id = @enumFromInt(9),
    };

    try std.testing.expectError(error.UnexpectedWorkspace, handler.execute(.{
        .location = other_workspace,
        .label = "canonical",
    }));
    try std.testing.expectError(error.TabNotFound, handler.execute(.{
        .location = missing_tab,
        .label = "canonical",
    }));
    try std.testing.expectError(error.InvalidTabLabel, handler.execute(.{
        .location = testing.second,
        .label = "",
    }));

    try std.testing.expectEqualStrings("logs", testing.model.workspace.find(testing.second.tab_id).?.labelSlice());
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}
