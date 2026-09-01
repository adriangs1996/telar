//! Application policy for detaching every tab owned by one client.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../model.zig");

const schema = core.schema;

pub const Effects = struct {
    context: *anyopaque,
    detach_tab: *const fn (*anyopaque, schema.TabLocation) anyerror!void,
};

pub const DetachClientHandler = struct {
    model: *client_model.Model,
    effects: Effects,

    /// Captures every current tab in stable order before delivering its
    /// retirement. A failure stops delivery without revisiting earlier tabs.
    ///
    /// ```zig
    /// try handler.execute();
    /// ```
    pub fn execute(handler: *DetachClientHandler) !void {
        var locations: [schema.max_tabs_per_workspace]schema.TabLocation = undefined;
        var location_count: usize = 0;
        var tabs = handler.model.workspace.tabIterator();
        while (tabs.next()) |tab| {
            std.debug.assert(location_count < locations.len);
            locations[location_count] = tab.location;
            location_count += 1;
        }

        for (locations[0..location_count]) |location| {
            try handler.effects.detach_tab(handler.effects.context, location);
        }
    }
};

const Capture = struct {
    locations: [schema.max_tabs_per_workspace]schema.TabLocation = undefined,
    location_count: usize = 0,
    fail_at: ?usize = null,

    fn effects(capture: *Capture) Effects {
        return .{ .context = capture, .detach_tab = detachTab };
    }

    fn detachTab(raw_context: *anyopaque, location: schema.TabLocation) !void {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        capture.locations[capture.location_count] = location;
        capture.location_count += 1;

        if (capture.fail_at == capture.location_count) {
            return error.DetachmentFailed;
        }
    }

    fn slice(capture: *const Capture) []const schema.TabLocation {
        return capture.locations[0..capture.location_count];
    }
};

const TestingModel = struct {
    model: *client_model.Model,
    locations: [3]schema.TabLocation,

    fn init(tab_count: usize) !TestingModel {
        std.debug.assert(tab_count <= 3);
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();
        const workspace: schema.WorkspaceLocation = .{ .workspace = @enumFromInt(1) };
        const locations = [3]schema.TabLocation{
            .{ .workspace = workspace, .tab_id = @enumFromInt(1) },
            .{ .workspace = workspace, .tab_id = @enumFromInt(2) },
            .{ .workspace = workspace, .tab_id = @enumFromInt(3) },
        };

        if (tab_count > 0) {
            try model.workspace.bootstrap(@enumFromInt(1), locations[0], .{ .cols = 20, .rows = 5 });
        }
        var index: usize = 1;
        while (index < tab_count) : (index += 1) {
            _ = try model.workspace.addCreated(.{
                .location = locations[index],
                .position = @intCast(index),
                .label = "tab",
                .root_pane_id = @enumFromInt(index + 1),
            }, .{ .cols = 20, .rows = 5 });
        }

        return .{ .model = model, .locations = locations };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }
};

test "DetachClientHandler delivers every captured tab in stable order" {
    var testing = try TestingModel.init(3);
    defer testing.deinit();
    var capture: Capture = .{};
    var handler: DetachClientHandler = .{
        .model = testing.model,
        .effects = capture.effects(),
    };
    const version = testing.model.version();

    try handler.execute();

    try std.testing.expectEqualSlices(schema.TabLocation, &testing.locations, capture.slice());
    try std.testing.expectEqualDeep(version, testing.model.version());
}

test "DetachClientHandler accepts an empty client without effects" {
    var testing = try TestingModel.init(0);
    defer testing.deinit();
    var capture: Capture = .{};
    var handler: DetachClientHandler = .{
        .model = testing.model,
        .effects = capture.effects(),
    };

    try handler.execute();

    try std.testing.expectEqual(@as(usize, 0), capture.location_count);
}

test "DetachClientHandler stops after the first failed tab retirement" {
    var testing = try TestingModel.init(3);
    defer testing.deinit();
    var capture: Capture = .{ .fail_at = 2 };
    var handler: DetachClientHandler = .{
        .model = testing.model,
        .effects = capture.effects(),
    };

    try std.testing.expectError(error.DetachmentFailed, handler.execute());

    try std.testing.expectEqualSlices(schema.TabLocation, testing.locations[0..2], capture.slice());
}
