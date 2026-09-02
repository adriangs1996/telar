//! Runtime fixtures shared only by backend unit and vertical tests.

const std = @import("std");
const core = @import("telar-core");
const agent_mod = @import("../../agent/root.zig");
const history = @import("../../history/root.zig");
const pane_mod = @import("../../pane/root.zig");
const pty = @import("../../pty/root.zig");
const attachment_mod = @import("../attachment/root.zig");
const telemetry_mod = @import("../observability/root.zig").telemetry;

const schema = core.schema;

pub const PaneFixture = struct {
    pub const initial_size: schema.TerminalSize = .{ .cols = 20, .rows = 5 };
    pub const location: schema.TabLocation = .{
        .workspace = .{ .workspace = @enumFromInt(2) },
        .tab_id = @enumFromInt(5),
    };

    pane_allocator: std.testing.FailingAllocator = undefined,
    attachment_allocator: std.testing.FailingAllocator = undefined,
    history_service: history.Service = undefined,
    budget: pane_mod.GraphicsBudget = undefined,
    pane: *pane_mod.Pane = undefined,
    attachments: attachment_mod.AttachmentStore = .{},
    agents: agent_mod.Tracker = .{},
    metrics: telemetry_mod.RuntimeMetrics = .{ .started_ns = 0 },

    /// Creates one running pane and one client attachment with independently
    /// injectable allocators.
    ///
    /// ```zig
    /// var fixture: PaneFixture = .{};
    /// try fixture.init();
    /// defer fixture.deinit();
    /// ```
    pub fn init(fixture: *PaneFixture) !void {
        const io = std.testing.io;

        fixture.* = .{};
        fixture.pane_allocator = .init(std.testing.allocator, .{});
        fixture.attachment_allocator = .init(std.testing.allocator, .{});
        fixture.history_service = try history.Service.init(std.testing.allocator, .{ .database_path = ":memory:" });
        errdefer {
            fixture.history_service.stop(io);
            fixture.history_service.deinit(io);
        }

        fixture.budget = pane_mod.GraphicsBudget.init(core.graphics.max_image_bytes_global);
        fixture.pane = try fixture.createPane(try schema.id.pane(7));
        errdefer {
            fixture.pane.session.shutdown();
            fixture.pane.destroy();
        }

        _ = try fixture.attachments.attach(fixture.attachment_allocator.allocator(), fixture.pane);
    }

    /// Releases attachments before destroying their panes and backing services.
    ///
    /// ```zig
    /// fixture.deinit();
    /// ```
    pub fn deinit(fixture: *PaneFixture) void {
        const io = std.testing.io;

        fixture.attachments.deinit();
        fixture.pane.session.shutdown();
        fixture.pane.destroy();
        fixture.history_service.stop(io);
        fixture.history_service.deinit(io);
    }

    /// Creates another running pane in the fixture's tab without attaching it.
    ///
    /// ```zig
    /// const second = try fixture.createPane(try schema.id.pane(8));
    /// ```
    pub fn createPane(fixture: *PaneFixture, pane_id: schema.PaneId) !*pane_mod.Pane {
        const arguments = [_][*:0]const u8{ "/bin/sleep", "600" };
        const command = try pty.Command.fromArgv(&arguments);
        const pane = try pane_mod.Pane.create(.{
            .io = std.testing.io,
            .gpa = fixture.pane_allocator.allocator(),
            .history_service = &fixture.history_service,
            .graphics_budget = &fixture.budget,
        }, .{
            .identity = .{ .id = pane_id, .generation = schema.id.raw(pane_id) },
            .location = location,
            .command = &command,
            .launch_cwd = "/",
            .workspace_path = "/work/telar",
            .size = initial_size,
            .graphics_limits = .{},
        });
        pane.commitLaunch("/bin/sleep");
        return pane;
    }

    /// Makes the pane allocator reject its next allocation or resize attempt.
    ///
    /// ```zig
    /// fixture.failNextPaneAllocation();
    /// ```
    pub fn failNextPaneAllocation(fixture: *PaneFixture) void {
        fixture.pane_allocator.fail_index = fixture.pane_allocator.alloc_index;
        fixture.pane_allocator.resize_fail_index = fixture.pane_allocator.resize_index;
    }

    /// Makes the attachment allocator reject its next allocation or resize.
    ///
    /// ```zig
    /// fixture.failNextAttachmentAllocation();
    /// ```
    pub fn failNextAttachmentAllocation(fixture: *PaneFixture) void {
        fixture.attachment_allocator.fail_index = fixture.attachment_allocator.alloc_index;
        fixture.attachment_allocator.resize_fail_index = fixture.attachment_allocator.resize_index;
    }

    /// Adds one complete RGBA image to the fixture's media terminal.
    ///
    /// ```zig
    /// try fixture.addRgbaImage(7);
    /// ```
    pub fn addRgbaImage(fixture: *PaneFixture, image_id: u32) !void {
        const media = fixture.pane.media_allocator.allocator();
        const pixels = try media.dupe(u8, &[_]u8{ 1, 2, 3, 255 });
        const screen = fixture.pane.media.terminal.screens.active;
        try screen.kitty_images.addImage(std.testing.io, media, screen, .{
            .id = image_id,
            .width = 1,
            .height = 1,
            .format = .rgba,
            .data = .{ .complete = pixels },
        });
    }
};
