//! Workspace aggregate and its tab entities.

const Workspace = @import("Workspace.zig");
const std = @import("std");
const workspace_module = @import("telar-core").workspace;
const tab_module = @import("telar-core").tab;
const max_cwd_bytes_module = @import("telar-core").max_cwd_bytes;
const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const max_tabs_per_workspace = @import("telar-core").max_tabs_per_workspace;
const TabDescriptorType = @import("telar-core").TabDescriptor;

fn testingWorkspace() !Workspace {
    const path = try std.testing.allocator.dupe(u8, "/work/telar");
    errdefer std.testing.allocator.free(path);

    return Workspace.init(.{
        .id = try workspace_module(1),
        .path = path,
        .default_tab_id = try tab_module(1),
    });
}

test "workspace derives its name from its path until explicitly renamed" {
    var workspace = try testingWorkspace();
    defer workspace.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("telar", workspace.name());
    const renamed = try workspace.rename("agents");
    try std.testing.expectEqualStrings("agents", workspace.name());
    try std.testing.expectEqualStrings("agents", renamed.nameSlice());

    try std.testing.expectError(error.InvalidWorkspaceName, workspace.rename(""));
    try std.testing.expectEqualStrings("agents", workspace.name());
}

test "workspace uses its root path as a non-empty derived name" {
    const path = try std.testing.allocator.dupe(u8, "/");
    var workspace = try Workspace.init(.{
        .id = try workspace_module(1),
        .path = path,
        .default_tab_id = try tab_module(1),
    });
    defer workspace.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("/", workspace.name());
}

test "workspace rejects paths that cannot cross the runtime protocol" {
    const workspace_id = try workspace_module(1);
    const tab_id = try tab_module(1);
    const invalid_paths = [_][]const u8{
        "",
        "bad\x00path",
    };

    for (invalid_paths) |invalid| {
        const path = try std.testing.allocator.dupe(u8, invalid);
        defer std.testing.allocator.free(path);

        try std.testing.expectError(error.InvalidWorkspacePath, Workspace.init(.{
            .id = workspace_id,
            .path = path,
            .default_tab_id = tab_id,
        }));
    }

    const oversized_source: [max_cwd_bytes_module + 1]u8 = @splat('x');
    const oversized = try std.testing.allocator.dupe(u8, &oversized_source);
    defer std.testing.allocator.free(oversized);

    try std.testing.expectError(error.InvalidWorkspacePath, Workspace.init(.{
        .id = workspace_id,
        .path = oversized,
        .default_tab_id = tab_id,
    }));
}

test "workspace explicit names follow the request label limit" {
    var workspace = try testingWorkspace();
    defer workspace.deinit(std.testing.allocator);
    const accepted: [max_tab_label_bytes_module]u8 = @splat('a');
    const oversized: [max_tab_label_bytes_module + 1]u8 = @splat('x');

    const renamed = try workspace.rename(&accepted);

    try std.testing.expectEqualSlices(u8, &accepted, workspace.name());
    try std.testing.expectEqualSlices(u8, &accepted, renamed.nameSlice());
    try std.testing.expectError(error.InvalidWorkspaceName, workspace.rename(&oversized));
    try std.testing.expectEqualSlices(u8, &accepted, workspace.name());
}

test "renameTab validates and mutates only the requested tab" {
    var workspace = try testingWorkspace();
    defer workspace.deinit(std.testing.allocator);
    const logs_id = try tab_module(2);
    _ = try workspace.createTab(logs_id, "logs");

    const renamed = try workspace.renameTab(logs_id, "server");
    try std.testing.expectEqualStrings("server", workspace.tabLabel(logs_id).?);
    try std.testing.expectEqualStrings("", workspace.tabLabel(try tab_module(1)).?);
    try std.testing.expectEqualStrings("server", renamed.labelSlice());
    try std.testing.expectEqual(logs_id, renamed.location.tab_id);

    try std.testing.expectError(error.InvalidTabLabel, workspace.renameTab(logs_id, ""));
    try std.testing.expectEqualStrings("server", workspace.tabLabel(logs_id).?);

    var oversized: [max_tab_label_bytes_module + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidTabLabel, workspace.renameTab(logs_id, &oversized));
    try std.testing.expectEqualStrings("server", workspace.tabLabel(logs_id).?);

    try std.testing.expectError(error.TabNotFound, workspace.renameTab(try tab_module(999), "missing"));

    _ = try workspace.renameTab(logs_id, "api");
    try std.testing.expectEqualStrings("server", renamed.labelSlice());
}

test "tabs are created moved described and removed through the aggregate" {
    var workspace = try testingWorkspace();
    defer workspace.deinit(std.testing.allocator);
    const logs_id = try tab_module(2);
    const generated_id = try tab_module(3);

    const logs = try workspace.createTab(logs_id, "logs");
    const generated = try workspace.createTab(generated_id, "");
    try std.testing.expectEqual(@as(u16, 1), logs.position);
    try std.testing.expectEqual(@as(u16, 2), generated.position);
    try std.testing.expectEqual(logs_id, logs.location.tab_id);
    try std.testing.expectEqualStrings("logs", logs.labelSlice());
    try std.testing.expectEqualStrings("", generated.labelSlice());
    try std.testing.expectEqualStrings("", workspace.tabLabel(generated_id).?);

    const moved = workspace.moveTab(logs_id, .{ .direction = .previous }).?;
    try std.testing.expectEqual(@as(u16, 0), moved.position);
    try std.testing.expectEqual(logs_id, moved.location.tab_id);
    try std.testing.expectEqual(logs_id, workspace.defaultTab());

    var descriptors: [max_tabs_per_workspace]TabDescriptorType = undefined;
    const snapshot = workspace.writeDescriptors(&descriptors);
    try std.testing.expectEqual(@as(usize, 3), snapshot.len);
    try std.testing.expectEqualStrings("logs", snapshot[0].label);
    try std.testing.expectEqualStrings("", snapshot[1].label);
    try std.testing.expectEqualStrings("", snapshot[2].label);

    try std.testing.expect(workspace.removeTab(logs_id));
    try std.testing.expect(!workspace.removeTab(logs_id));
    try std.testing.expectEqual(@as(usize, 2), workspace.tabCount());
}

test "renaming an automatic tab records names matching former defaults as explicit" {
    var workspace = try testingWorkspace();
    defer workspace.deinit(std.testing.allocator);
    const first_id = try tab_module(1);
    const second_id = try tab_module(2);
    _ = try workspace.createTab(second_id, "");

    _ = try workspace.renameTab(first_id, "main");
    _ = try workspace.renameTab(second_id, "tab 2");

    var descriptors: [max_tabs_per_workspace]TabDescriptorType = undefined;
    const snapshot = workspace.writeDescriptors(&descriptors);
    try std.testing.expectEqualStrings("main", snapshot[0].label);
    try std.testing.expectEqualStrings("tab 2", snapshot[1].label);
}

test "workspace rejects tabs beyond its fixed capacity without mutation" {
    var workspace = try testingWorkspace();
    defer workspace.deinit(std.testing.allocator);

    for (2..max_tabs_per_workspace + 1) |raw_id| {
        _ = try workspace.createTab(try tab_module(raw_id), "tab");
    }

    try std.testing.expectEqual(max_tabs_per_workspace, workspace.tabCount());
    try std.testing.expectError(
        error.TabLimitReached,
        workspace.createTab(try tab_module(max_tabs_per_workspace + 1), "overflow"),
    );
    try std.testing.expectEqual(max_tabs_per_workspace, workspace.tabCount());
}

test "anchored tab moves preserve the order and identity of every intervening tab" {
    const cases = .{
        .{ 1, 4, .previous, .{ 2, 3, 1, 4 }, 2 },
        .{ 1, 4, .next, .{ 2, 3, 4, 1 }, 3 },
        .{ 4, 1, .previous, .{ 4, 1, 2, 3 }, 0 },
        .{ 4, 1, .next, .{ 1, 4, 2, 3 }, 1 },
        .{ 2, 3, .next, .{ 1, 3, 2, 4 }, 2 },
        .{ 3, 2, .previous, .{ 1, 3, 2, 4 }, 1 },
        .{ 2, 3, .previous, .{ 1, 2, 3, 4 }, 1 },
        .{ 2, 2, .next, .{ 1, 2, 3, 4 }, 1 },
    };
    inline for (cases) |case| {
        var workspace = try testingWorkspace();
        defer workspace.deinit(std.testing.allocator);
        for (2..5) |id| {
            _ = try workspace.createTab(try tab_module(id), "");
        }

        const moved = workspace.moveTab(try tab_module(case[0]), .{ .relative_to = try tab_module(case[1]), .direction = case[2] }).?;
        try std.testing.expectEqual(@as(u16, case[4]), moved.position);
        var storage: [max_tabs_per_workspace]TabDescriptorType = undefined;
        const tabs = workspace.writeDescriptors(&storage);
        try std.testing.expectEqual(@as(usize, 4), tabs.len);
        inline for (case[3], 0..) |id, index| {
            try std.testing.expectEqual(try tab_module(id), tabs[index].tab_id);
        }
    }
}

test "missing insertion anchor leaves the workspace untouched" {
    var workspace = try testingWorkspace();
    defer workspace.deinit(std.testing.allocator);
    _ = try workspace.createTab(try tab_module(2), "logs");
    try std.testing.expect(workspace.moveTab(try tab_module(1), .{ .relative_to = try tab_module(99), .direction = .next }) == null);
    try std.testing.expectEqual(try tab_module(1), workspace.defaultTab());
    try std.testing.expectEqual(@as(usize, 2), workspace.tabCount());
}
