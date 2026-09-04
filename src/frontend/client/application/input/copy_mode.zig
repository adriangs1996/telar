//! Application boundary for client-owned copy mode.

const std = @import("std");
const core = @import("telar-core");
const input_capability = @import("../../../input/root.zig");
const client_model = @import("../../model/root.zig");
const link_capability = @import("../../../links/root.zig");
const set_pane_viewport = @import("../panes/set_pane_viewport.zig");

const keybind = input_capability.keybind;
const schema = core.schema;

pub const CopyModeEffects = struct {
    context: *anyopaque,
    copy: *const fn (*anyopaque, schema.CopySelection) anyerror!void,
    open_search: *const fn (*anyopaque, input_capability.copy_mode.Direction) anyerror!void,
    open_link: *const fn (*anyopaque, link_capability.Target) anyerror!void,
    viewport: set_pane_viewport.PaneViewportEffects,
};

pub const Outcome = enum {
    unchanged,
    changed,
    exited,
};

pub const CopyModeHandler = struct {
    model: *client_model.Model,
    effects: CopyModeEffects,

    /// Enters copy mode without performing runtime or presentation effects.
    ///
    /// ```zig
    /// if (handler.enter()) observe(handler.model.version());
    /// ```
    pub fn enter(handler: *CopyModeHandler) bool {
        return handler.model.enterCopyMode();
    }

    /// Delivers a requested selection before closing local state, then
    /// synchronizes a committed viewport. A failed copy keeps the mode open;
    /// a failed viewport leaves the semantic commit intact.
    ///
    /// ```zig
    /// const outcome = try handler.execute(.{ .key = key });
    /// ```
    pub fn execute(handler: *CopyModeHandler, command: client_model.CopyModeCommand) !Outcome {
        const plan = handler.model.planCopyMode(command) orelse return .unchanged;
        if (plan.open_link) |target| {
            try handler.effects.open_link(handler.effects.context, target);

            return .unchanged;
        }
        if (plan.selection) |selection| {
            try handler.effects.copy(handler.effects.context, selection);
        }

        const commit = handler.model.commitCopyMode(plan) orelse return .unchanged;
        if (commit.viewport) |viewport| {
            try handler.effects.viewport.sync(handler.effects.viewport.context, viewport);
        }
        if (plan.search) |direction| {
            try handler.effects.open_search(handler.effects.context, direction);
        }

        return if (commit.active) .changed else .exited;
    }
};

const TestingModel = struct {
    model: *client_model.Model,
    pane_id: schema.PaneId,

    fn init() !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();

        const location: schema.TabLocation = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        };
        const pane_id: schema.PaneId = @enumFromInt(1);
        try model.workspace.bootstrap(pane_id, location, .{ .cols = 10, .rows = 5 });
        const pane = model.workspace.findPane(pane_id).?;
        pane.scroll = .{ .total_rows = 15, .offset = 10 };
        pane.cursor = .{ .visible = true, .x = 0, .y = 4 };

        return .{ .model = model, .pane_id = pane_id };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }
};

const EffectsCapture = struct {
    model: *client_model.Model,
    copy_calls: usize = 0,
    viewport_calls: usize = 0,
    copy_observed_active: bool = false,
    viewport_observed_commit: bool = false,
    viewport_observed_active: bool = false,
    copied: ?schema.CopySelection = null,
    viewport: ?client_model.PaneViewportChange = null,
    fail_copy: bool = false,
    search_opened: ?input_capability.copy_mode.Direction = null,
    link_opened: ?link_capability.Target = null,
    fail_viewport: bool = false,

    fn port(capture: *EffectsCapture) CopyModeEffects {
        return .{
            .context = capture,
            .copy = copy,
            .open_search = openSearch,
            .open_link = openLink,
            .viewport = .{
                .context = capture,
                .sync = syncViewport,
            },
        };
    }

    fn openSearch(context: *anyopaque, direction: input_capability.copy_mode.Direction) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.search_opened = direction;
    }

    fn openLink(context: *anyopaque, target: link_capability.Target) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.link_opened = target;
    }

    fn copy(context: *anyopaque, selection: schema.CopySelection) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.copy_calls += 1;
        capture.copy_observed_active = capture.model.copyModeActive();
        capture.copied = selection;

        if (capture.fail_copy) {
            return error.CopyDeliveryFailed;
        }
    }

    fn syncViewport(context: *anyopaque, viewport: client_model.PaneViewportChange) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        const pane = capture.model.workspace.findPane(viewport.pane_id).?;
        capture.viewport_calls += 1;
        capture.viewport = viewport;
        capture.viewport_observed_commit = pane.scroll.offset == viewport.offset;
        capture.viewport_observed_active = capture.model.copyModeActive();

        if (capture.fail_viewport) {
            return error.ViewportSyncFailed;
        }
    }

    fn reset(capture: *EffectsCapture) void {
        capture.copy_calls = 0;
        capture.viewport_calls = 0;
        capture.copy_observed_active = false;
        capture.viewport_observed_commit = false;
        capture.viewport_observed_active = false;
        capture.copied = null;
        capture.viewport = null;
    }
};

test "CopyModeHandler copies before exit and synchronizes the committed viewport" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{ .model = testing.model };
    var handler: CopyModeHandler = .{ .model = testing.model, .effects = capture.port() };

    try std.testing.expect(handler.enter());
    try std.testing.expect(try handler.execute(.{ .key = try keybind.parseKey("v") }) == .changed);
    try std.testing.expect(try handler.execute(.{ .key = try keybind.parseKey("g") }) == .changed);
    try std.testing.expectEqual(@as(u32, 0), testing.model.workspace.findPane(testing.pane_id).?.scroll.offset);
    capture.reset();

    try std.testing.expect(try handler.execute(.{ .key = try keybind.parseKey("enter") }) == .exited);

    try std.testing.expectEqual(@as(usize, 1), capture.copy_calls);
    try std.testing.expect(capture.copy_observed_active);
    try std.testing.expectEqual(testing.pane_id, capture.copied.?.pane_id);
    try std.testing.expectEqual(@as(u32, 14), capture.copied.?.start_y);
    try std.testing.expectEqual(@as(u32, 0), capture.copied.?.end_y);
    try std.testing.expectEqual(@as(usize, 1), capture.viewport_calls);
    try std.testing.expect(capture.viewport_observed_commit);
    try std.testing.expect(!capture.viewport_observed_active);
    try std.testing.expectEqual(@as(u32, 10), capture.viewport.?.offset);
    try std.testing.expectEqual(@as(u64, 2), capture.viewport.?.viewport_revision);
    try std.testing.expectEqual(@as(u64, 2), testing.model.version().viewport);
    try std.testing.expect(!testing.model.copyModeActive());
}

test "CopyModeHandler retains selection and revision when copy delivery fails" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{ .model = testing.model, .fail_copy = true };
    var handler: CopyModeHandler = .{ .model = testing.model, .effects = capture.port() };
    try std.testing.expect(handler.enter());
    try std.testing.expect(try handler.execute(.{ .key = try keybind.parseKey("v") }) == .changed);
    const version = testing.model.version();

    try std.testing.expectError(
        error.CopyDeliveryFailed,
        handler.execute(.{ .key = try keybind.parseKey("enter") }),
    );

    try std.testing.expect(testing.model.copyModeActive());
    try std.testing.expectEqualDeep(version, testing.model.version());
    try std.testing.expectEqual(@as(usize, 1), capture.copy_calls);
    try std.testing.expectEqual(@as(usize, 0), capture.viewport_calls);
}

test "CopyModeHandler opens a link without committing or leaving copy mode" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const pane = testing.model.workspace.findPane(testing.pane_id).?;
    try pane.buffer.resize(40, 5);
    pane.buffer.fill(pane.buffer.area(), .{ .glyph = " ", .style = .{} });
    _ = pane.buffer.writeText(pane.buffer.area(), 0, 4, "https://example.com/path", .{});
    pane.cursor = .{ .visible = true, .x = 10, .y = 4 };

    var capture: EffectsCapture = .{ .model = testing.model };
    var handler: CopyModeHandler = .{ .model = testing.model, .effects = capture.port() };
    try std.testing.expect(handler.enter());
    const version = testing.model.version();

    try std.testing.expectEqual(Outcome.unchanged, try handler.execute(.{ .key = try keybind.parseKey("o") }));

    try std.testing.expectEqualStrings("https://example.com/path", capture.link_opened.?.uri());
    try std.testing.expect(testing.model.copyModeActive());
    try std.testing.expectEqualDeep(version, testing.model.version());
}

test "CopyModeHandler preserves a movement commit when viewport sync fails" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{ .model = testing.model, .fail_viewport = true };
    var handler: CopyModeHandler = .{ .model = testing.model, .effects = capture.port() };
    try std.testing.expect(handler.enter());
    const version = testing.model.version();

    try std.testing.expectError(
        error.ViewportSyncFailed,
        handler.execute(.{ .key = try keybind.parseKey("g") }),
    );

    try std.testing.expect(testing.model.copyModeActive());
    try std.testing.expectEqual(version.copy + 1, testing.model.version().copy);
    try std.testing.expectEqual(version.viewport + 1, testing.model.version().viewport);
    try std.testing.expectEqual(@as(u32, 0), testing.model.workspace.findPane(testing.pane_id).?.scroll.offset);
    try std.testing.expect(capture.viewport_observed_commit);
    try std.testing.expect(capture.viewport_observed_active);
}

test "CopyModeHandler suppresses boundary and unhandled no-ops" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: EffectsCapture = .{ .model = testing.model };
    var handler: CopyModeHandler = .{ .model = testing.model, .effects = capture.port() };
    try std.testing.expect(handler.enter());
    const version = testing.model.version();

    try std.testing.expect(try handler.execute(.{ .key = try keybind.parseKey("left") }) == .unchanged);
    try std.testing.expect(try handler.execute(.{ .key = try keybind.parseKey("z") }) == .unchanged);

    try std.testing.expectEqualDeep(version, testing.model.version());
    try std.testing.expectEqual(@as(usize, 0), capture.copy_calls);
    try std.testing.expectEqual(@as(usize, 0), capture.viewport_calls);
}
