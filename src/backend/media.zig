//! Bounded Kitty graphics pipeline for one pane.
//!
//! The interactive terminal ignores Kitty APCs. This pipeline consumes a
//! copy of the same PTY output on a separate actor and owns the terminal whose
//! only durable product is graphics storage. Feeding all output, not only APC
//! payloads, keeps cursor-relative placements and scroll pins equivalent to
//! the interactive terminal without sharing mutable emulator state.

const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");

const Io = std.Io;
const schema = core.schema;

pub const batch_bytes = 4 * 16 * 1024;
pub const batch_events = 64;

pub const Stats = struct {
    output_bytes: u64 = 0,
    reset: bool = false,
    failed: bool = false,
};

const Event = union(enum) {
    output: struct { offset: u32, len: u32 },
    resize: schema.TerminalSize,
};

const Batch = struct {
    bytes: [batch_bytes]u8 = undefined,
    len: usize = 0,
    events: [batch_events]Event = undefined,
    event_count: usize = 0,
    reset_before: bool = false,

    fn reset(batch: *Batch) void {
        batch.len = 0;
        batch.event_count = 0;
        batch.reset_before = false;
    }

    fn pushOutput(batch: *Batch, bytes: []const u8) bool {
        if (batch.event_count == batch.events.len or bytes.len > batch.bytes.len - batch.len)
            return false;
        const offset = batch.len;
        @memcpy(batch.bytes[offset..][0..bytes.len], bytes);
        batch.len += bytes.len;
        batch.events[batch.event_count] = .{ .output = .{
            .offset = @intCast(offset),
            .len = @intCast(bytes.len),
        } };
        batch.event_count += 1;
        return true;
    }

    fn pushResize(batch: *Batch, size: schema.TerminalSize) bool {
        if (batch.event_count == batch.events.len) return false;
        batch.events[batch.event_count] = .{ .resize = size };
        batch.event_count += 1;
        return true;
    }
};

pub const Pipeline = struct {
    terminal: vt.Terminal,
    stream: vt.TerminalStream,
    allocator: std.mem.Allocator,
    write_pty: ?*const fn (*vt.TerminalStream.Handler, [:0]const u8) void,
    payload_limit: usize,
    batches: [2]Batch = .{ .{}, .{} },
    active: u1 = 0,
    worker: ?u1 = null,
    enabled: bool,
    dropped_events: u64 = 0,
    dropped_bytes: u64 = 0,
    resets: u64 = 0,
    failures: u64 = 0,

    pub fn init(
        pipeline: *Pipeline,
        io: Io,
        allocator: std.mem.Allocator,
        size: schema.TerminalSize,
        storage_limit: usize,
        payload_limit: usize,
        write_pty: ?*const fn (*vt.TerminalStream.Handler, [:0]const u8) void,
    ) !void {
        pipeline.allocator = allocator;
        pipeline.write_pty = write_pty;
        pipeline.payload_limit = payload_limit;
        pipeline.terminal = try .init(io, allocator, .{
            .cols = size.cols,
            .rows = size.rows,
            .kitty_image_storage_limit = storage_limit,
            .kitty_image_loading_limits = .direct,
        });
        errdefer pipeline.terminal.deinit(allocator);
        pipeline.stream = pipeline.newStream();
        errdefer pipeline.stream.deinit();
        try pipeline.stream.handler.resize(vtResize(size));
        pipeline.batches = .{ .{}, .{} };
        pipeline.active = 0;
        pipeline.worker = null;
        pipeline.enabled = true;
        pipeline.dropped_events = 0;
        pipeline.dropped_bytes = 0;
        pipeline.resets = 0;
        pipeline.failures = 0;
    }

    pub fn deinit(pipeline: *Pipeline) void {
        if (pipeline.worker) |index| pipeline.batches[index].reset();
        pipeline.worker = null;
        if (pipeline.enabled) pipeline.stream.deinit();
        pipeline.terminal.deinit(pipeline.allocator);
    }

    pub fn queueOutput(pipeline: *Pipeline, bytes: []const u8) void {
        if (bytes.len > batch_bytes) {
            pipeline.dropActive(bytes.len, 1);
            return;
        }
        var batch = &pipeline.batches[pipeline.active];
        if (!batch.pushOutput(bytes)) {
            pipeline.dropActive(bytes.len, 1);
            batch = &pipeline.batches[pipeline.active];
            _ = batch.pushOutput(bytes);
        }
    }

    pub fn queueResize(pipeline: *Pipeline, size: schema.TerminalSize) void {
        var batch = &pipeline.batches[pipeline.active];
        if (!batch.pushResize(size)) {
            pipeline.dropActive(0, 1);
            batch = &pipeline.batches[pipeline.active];
            _ = batch.pushResize(size);
        }
    }

    pub fn hasPending(pipeline: *const Pipeline) bool {
        return pipeline.worker == null and pipeline.batches[pipeline.active].event_count != 0;
    }

    pub fn seal(pipeline: *Pipeline) bool {
        if (!pipeline.hasPending()) return false;
        const sealed = pipeline.active;
        pipeline.active ^= 1;
        std.debug.assert(pipeline.batches[pipeline.active].event_count == 0);
        pipeline.worker = sealed;
        return true;
    }

    pub fn finishSealed(pipeline: *Pipeline) void {
        const index = pipeline.worker orelse unreachable;
        pipeline.batches[index].reset();
        pipeline.worker = null;
    }

    pub fn processSealed(
        pipeline: *Pipeline,
        current_size: schema.TerminalSize,
        stats: *Stats,
        context: anytype,
        comptime observe_output: fn (@TypeOf(context), []const u8) void,
    ) void {
        const batch = &pipeline.batches[pipeline.worker orelse return];
        if (batch.reset_before or !pipeline.enabled) {
            pipeline.resetState(current_size) catch {
                pipeline.failures +|= 1;
                stats.failed = true;
                return;
            };
            pipeline.resets +|= 1;
            stats.reset = true;
        }

        for (batch.events[0..batch.event_count]) |event| switch (event) {
            .output => |output| {
                const start: usize = output.offset;
                const bytes = batch.bytes[start..][0..output.len];
                observe_output(context, bytes);
                stats.output_bytes +|= bytes.len;
            },
            .resize => |size| pipeline.stream.handler.resize(vtResize(size)) catch {
                pipeline.failures +|= 1;
                stats.failed = true;
            },
        };
    }

    fn dropActive(pipeline: *Pipeline, incoming_bytes: usize, incoming_events: usize) void {
        const batch = &pipeline.batches[pipeline.active];
        pipeline.dropped_events +|= batch.event_count + incoming_events;
        pipeline.dropped_bytes +|= batch.len + incoming_bytes;
        batch.reset();
        batch.reset_before = true;
    }

    fn resetState(pipeline: *Pipeline, size: schema.TerminalSize) !void {
        if (pipeline.enabled) pipeline.stream.deinit();
        pipeline.enabled = false;
        pipeline.terminal.fullReset();
        pipeline.stream = pipeline.newStream();
        errdefer pipeline.stream.deinit();
        try pipeline.stream.handler.resize(vtResize(size));
        pipeline.enabled = true;
    }

    fn newStream(pipeline: *Pipeline) vt.TerminalStream {
        var handler = pipeline.terminal.vtHandler();
        handler.apc_handler.max_bytes.put(.kitty, pipeline.payload_limit);
        handler.apc_handler.enable(.glyph, false);
        handler.effects.write_pty = pipeline.write_pty;
        return .init(.{ .allocator = pipeline.allocator, .handler = handler });
    }
};

fn vtResize(size: schema.TerminalSize) vt.Terminal.Resize {
    return .{
        .cols = size.cols,
        .rows = size.rows,
        .cell_size_px = if (size.cell_width_px != 0 and size.cell_height_px != 0) .{
            .width = size.cell_width_px,
            .height = size.cell_height_px,
        } else null,
    };
}

test "media terminal preserves cursor-relative KGP placement" {
    const size: schema.TerminalSize = .{
        .cols = 40,
        .rows = 8,
        .cell_width_px = 10,
        .cell_height_px = 20,
    };
    var pipeline: Pipeline = undefined;
    try pipeline.init(
        std.testing.io,
        std.testing.allocator,
        size,
        1024 * 1024,
        64 * 1024,
        null,
    );
    defer pipeline.deinit();

    const Feed = struct {
        fn output(active: *Pipeline, bytes: []const u8) void {
            active.stream.nextSlice(bytes);
        }
    };
    pipeline.queueOutput(
        "abc" ++
            "\x1b_Ga=T,f=32,s=1,v=1,t=d,i=7,p=3,c=2,r=1;AQID/w==\x1b\\" ++
            "tail",
    );
    try std.testing.expect(pipeline.seal());
    var stats: Stats = .{};
    pipeline.processSealed(size, &stats, &pipeline, Feed.output);
    pipeline.finishSealed();

    const storage = &pipeline.terminal.screens.active.kitty_images;
    try std.testing.expectEqual(@as(usize, 1), storage.images.count());
    try std.testing.expectEqual(@as(usize, 1), storage.placements.count());
    try std.testing.expectEqualSlices(
        u8,
        &.{ 1, 2, 3, 255 },
        storage.imageById(7).?.data.bytes().?,
    );
}

test "overflow replaces obsolete media and requests a reset" {
    const size: schema.TerminalSize = .{
        .cols = 40,
        .rows = 8,
        .cell_width_px = 0,
        .cell_height_px = 0,
    };
    var pipeline: Pipeline = undefined;
    try pipeline.init(
        std.testing.io,
        std.testing.allocator,
        size,
        1024 * 1024,
        64 * 1024,
        null,
    );
    defer pipeline.deinit();
    const full: [batch_bytes]u8 = @splat('x');
    pipeline.queueOutput(&full);
    pipeline.queueOutput("latest");
    try std.testing.expect(pipeline.seal());
    try std.testing.expect(pipeline.dropped_events != 0);
    try std.testing.expect(pipeline.batches[pipeline.worker.?].reset_before);
    pipeline.finishSealed();
}
