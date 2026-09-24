const core = @import("telar-core");
const std = @import("std");
const Service = @import("../../history/Service.zig");
const GraphicsBudget = @import("../../media/GraphicsBudget.zig");
const Pane = @import("../../pane/Pane.zig");
const AttachmentStore = @import("../attachment/AttachmentStore.zig");
const Tracker = @import("../../agent/Tracker.zig");
const RuntimeMetrics = @import("../observability/RuntimeMetrics.zig");
const pty = @import("pty");
const Command = pty.Command;
const support = @import("support.zig");
const PaneFixture = @This();

pub const initial_size: core.TerminalSize = .{ .cols = 20, .rows = 5 };
pub const location: core.TabLocation = .{
    .workspace = .{ .workspace = @enumFromInt(2) },
    .tab_id = @enumFromInt(5),
};

pane_allocator: std.testing.FailingAllocator = undefined,
attachment_allocator: std.testing.FailingAllocator = undefined,
history_service: Service = undefined,
budget: GraphicsBudget = undefined,
pane: *Pane = undefined,
attachments: AttachmentStore = .{},
agents: Tracker = .{},
metrics: RuntimeMetrics = .{ .started_ns = 0 },

/// Creates one running pane and one client attachment with independently
/// injectable allocators.
///
/// ```zig
/// var fixture: PaneFixture = .{};
/// try fixture.init();
/// defer fixture.deinit();
/// ```
pub fn init(self: *PaneFixture) !void {
    const io = std.testing.io;

    self.* = .{};
    self.pane_allocator = .init(std.testing.allocator, .{});
    self.attachment_allocator = .init(std.testing.allocator, .{});
    self.history_service = try Service.init(std.testing.allocator, .{ .database_path = ":memory:" });
    errdefer {
        self.history_service.stop(io);
        self.history_service.deinit(io);
    }

    self.budget = GraphicsBudget.init(core.max_image_bytes_global);
    self.pane = try self.createPane(try core.pane(7));
    errdefer {
        self.pane.session.shutdown();
        self.pane.destroy();
    }

    _ = try self.attachments.attach(self.attachment_allocator.allocator(), self.pane);
}

/// Releases attachments before destroying their panes and backing services.
///
/// ```zig
/// fixture.deinit();
/// ```
pub fn deinit(self: *PaneFixture) void {
    const io = std.testing.io;

    self.attachments.deinit();
    self.pane.session.shutdown();
    self.pane.destroy();
    self.history_service.stop(io);
    self.history_service.deinit(io);
}

/// Creates another running pane in the fixture's tab without attaching it.
///
/// ```zig
/// const second = try fixture.createPane(try schema.id.pane(8));
/// ```
pub fn createPane(self: *PaneFixture, pane_id: core.PaneId) !*Pane {
    const arguments = [_][*:0]const u8{ "/bin/sleep", "600" };
    const command = try Command.fromArgv(&arguments);
    const pane = try Pane.create(.{
        .io = std.testing.io,
        .gpa = self.pane_allocator.allocator(),
        .history_service = &self.history_service,
        .graphics_budget = &self.budget,
    }, .{
        .identity = .{ .id = pane_id, .generation = core.raw(pane_id) },
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
pub fn failNextPaneAllocation(self: *PaneFixture) void {
    self.pane_allocator.fail_index = self.pane_allocator.alloc_index;
    self.pane_allocator.resize_fail_index = self.pane_allocator.resize_index;
}

/// Makes the attachment allocator reject its next allocation or resize.
///
/// ```zig
/// fixture.failNextAttachmentAllocation();
/// ```
pub fn failNextAttachmentAllocation(self: *PaneFixture) void {
    self.attachment_allocator.fail_index = self.attachment_allocator.alloc_index;
    self.attachment_allocator.resize_fail_index = self.attachment_allocator.resize_index;
}

/// Adds one complete RGBA image to the fixture's media terminal.
///
/// ```zig
/// try fixture.addRgbaImage(7);
/// ```
/// Executes a queued media turn deterministically, with the production borrow.
/// Example: `fixture.processMedia();`.
pub fn processMedia(self: *PaneFixture) void {
    support.processMediaTurn(self.pane);
}

pub fn addRgbaImage(self: *PaneFixture, image_id: u32) !void {
    const media = self.pane.media_allocator.allocator();
    const pixels = try media.dupe(u8, &[_]u8{ 1, 2, 3, 255 });
    const screen = self.pane.media.terminal.screens.active;
    try screen.kitty_images.addImage(std.testing.io, media, screen, .{
        .id = image_id,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = .{ .complete = pixels },
    });
}
