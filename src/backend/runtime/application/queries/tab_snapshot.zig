//! Application query for deciding whether a tab has a live snapshot.

const std = @import("std");
const core = @import("telar-core");

const schema = core.schema;

pub const Request = struct {
    location: schema.TabLocation,
};

pub const Result = struct {
    location: schema.TabLocation,
};

pub const Source = struct {
    context: *anyopaque,
    contains_tab: *const fn (*anyopaque, schema.TabLocation) bool,
    running_panes: *const fn (*anyopaque, schema.TabLocation) u16,
};

pub const Executor = struct {
    context: *anyopaque,
    execute_fn: *const fn (*anyopaque, Request) anyerror!Result,

    /// Executes the tab-snapshot query through its bound handler.
    ///
    /// ```zig
    /// const snapshot = try executor.execute(.{ .location = location });
    /// ```
    pub fn execute(executor: Executor, request: Request) !Result {
        return executor.execute_fn(executor.context, request);
    }
};

pub const Handler = struct {
    source: Source,

    /// Returns a snapshot reference only while both its tab and at least one
    /// running pane exist. The later encoder owns materializing pane details.
    ///
    /// ```zig
    /// const snapshot = try handler.execute(.{ .location = location });
    /// ```
    pub fn execute(handler: *Handler, request: Request) !Result {
        if (!handler.source.contains_tab(handler.source.context, request.location)) {
            return error.TabNotFound;
        }

        if (handler.source.running_panes(handler.source.context, request.location) == 0) {
            return error.TabNotFound;
        }

        return .{ .location = request.location };
    }

    /// Exposes this handler through the query interface used by controllers.
    ///
    /// ```zig
    /// const executor = handler.executor();
    /// ```
    pub fn executor(handler: *Handler) Executor {
        return .{ .context = handler, .execute_fn = executeErased };
    }

    fn executeErased(context: *anyopaque, request: Request) !Result {
        const handler: *Handler = @ptrCast(@alignCast(context));
        return handler.execute(request);
    }
};

const SourceCapture = struct {
    contains: bool,
    pane_count: u16,
    contains_calls: usize = 0,
    pane_calls: usize = 0,
    last_location: ?schema.TabLocation = null,

    fn source(capture: *SourceCapture) Source {
        return .{
            .context = capture,
            .contains_tab = containsTab,
            .running_panes = runningPanes,
        };
    }

    fn containsTab(context: *anyopaque, location: schema.TabLocation) bool {
        const capture: *SourceCapture = @ptrCast(@alignCast(context));
        capture.contains_calls += 1;
        capture.last_location = location;
        return capture.contains;
    }

    fn runningPanes(context: *anyopaque, location: schema.TabLocation) u16 {
        const capture: *SourceCapture = @ptrCast(@alignCast(context));
        capture.pane_calls += 1;
        capture.last_location = location;
        return capture.pane_count;
    }
};

fn testingLocation() !schema.TabLocation {
    return .{
        .workspace = .{ .workspace = try schema.id.workspace(3) },
        .tab_id = try schema.id.tab(7),
    };
}

test "Handler returns the requested live tab snapshot reference" {
    const location = try testingLocation();
    var source_capture: SourceCapture = .{ .contains = true, .pane_count = 2 };
    var handler: Handler = .{ .source = source_capture.source() };

    const result = try handler.executor().execute(.{ .location = location });

    try std.testing.expectEqualDeep(location, result.location);
    try std.testing.expectEqual(@as(usize, 1), source_capture.contains_calls);
    try std.testing.expectEqual(@as(usize, 1), source_capture.pane_calls);
    try std.testing.expectEqualDeep(location, source_capture.last_location.?);
}

test "Handler rejects an absent tab without consulting panes" {
    var source_capture: SourceCapture = .{ .contains = false, .pane_count = 4 };
    var handler: Handler = .{ .source = source_capture.source() };

    try std.testing.expectError(error.TabNotFound, handler.execute(.{
        .location = try testingLocation(),
    }));

    try std.testing.expectEqual(@as(usize, 1), source_capture.contains_calls);
    try std.testing.expectEqual(@as(usize, 0), source_capture.pane_calls);
}

test "Handler rejects a tab without a running pane" {
    var source_capture: SourceCapture = .{ .contains = true, .pane_count = 0 };
    var handler: Handler = .{ .source = source_capture.source() };

    try std.testing.expectError(error.TabNotFound, handler.execute(.{
        .location = try testingLocation(),
    }));

    try std.testing.expectEqual(@as(usize, 1), source_capture.contains_calls);
    try std.testing.expectEqual(@as(usize, 1), source_capture.pane_calls);
}
