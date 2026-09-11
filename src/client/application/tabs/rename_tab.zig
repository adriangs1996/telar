//! Application use cases for requesting and confirming a tab rename.

const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const std = @import("std");
const RenameTabTestingModel = @import("RenameTabTestingModel.zig");
const RenameTabRequestCapture = @import("RenameTabRequestCapture.zig");
const RequestRenameTabHandler = @import("RequestRenameTabHandler.zig");
const VersionType = @import("../../model/Version.zig");
const ConfirmTabRenameHandler = @import("ConfirmTabRenameHandler.zig");
const types = @import("../../model/types.zig");
const TabLocationType = @import("telar-core").TabLocation;

pub fn validateLabel(label: []const u8) !void {
    if (label.len == 0 or label.len > max_tab_label_bytes_module) {
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

test "tab rename request resolves an inactive target without mutation" {
    var testing = try RenameTabTestingModel.init();
    defer testing.deinit();
    var capture: RenameTabRequestCapture = .{};
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
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "tab rename request suppresses blocked and missing targets" {
    var testing = try RenameTabTestingModel.init();
    defer testing.deinit();
    var capture: RenameTabRequestCapture = .{ .blocked = true };
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
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "tab rename request rejects invalid labels before delivery" {
    var testing = try RenameTabTestingModel.init();
    defer testing.deinit();
    var capture: RenameTabRequestCapture = .{};
    var handler: RequestRenameTabHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.effects(),
    };
    const invalid_utf8 = [_]u8{0xff};
    const too_long = [_]u8{'x'} ** (max_tab_label_bytes_module + 1);

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
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "tab rename request propagates delivery failure without mutation" {
    var testing = try RenameTabTestingModel.init();
    defer testing.deinit();
    var capture: RenameTabRequestCapture = .{ .failure = error.DeliveryFailed };
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
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "tab rename confirmation commits the canonical label without changing active identity" {
    var testing = try RenameTabTestingModel.init();
    defer testing.deinit();
    var handler: ConfirmTabRenameHandler = .{ .model = testing.model };

    const change = try handler.execute(.{
        .location = testing.second,
        .label = "canonical",
    });

    try std.testing.expectEqual(types.Change.changed, change);
    try std.testing.expectEqualStrings("canonical", testing.model.workspace.find(testing.second.tab_id).?.labelSlice());
    try std.testing.expectEqualDeep(testing.first, testing.model.activeTabLocation().?);
    try std.testing.expectEqual(@as(u64, 1), testing.model.version().tabs);
    try std.testing.expectEqual(@as(u64, 0), testing.model.version().active_tab);
}

test "tab rename confirmation preserves the version for a canonical no-op" {
    var testing = try RenameTabTestingModel.init();
    defer testing.deinit();
    var handler: ConfirmTabRenameHandler = .{ .model = testing.model };

    const change = try handler.execute(.{
        .location = testing.second,
        .label = "logs",
    });

    try std.testing.expectEqual(types.Change.unchanged, change);
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "tab rename confirmation rejects invalid canonical state without mutation" {
    var testing = try RenameTabTestingModel.init();
    defer testing.deinit();
    var handler: ConfirmTabRenameHandler = .{ .model = testing.model };
    const other_workspace: TabLocationType = .{
        .workspace = .{ .workspace = @enumFromInt(9) },
        .tab_id = testing.second.tab_id,
    };
    const missing_tab: TabLocationType = .{
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
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}
