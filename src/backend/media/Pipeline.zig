const Pipeline = @This();
const vt = @import("ghostty-vt");
const std = @import("std");
const Batch = @import("Batch.zig");
const source_namespace = @import("root.zig");
const Initialization = @import("Initialization.zig");
const png = @import("png.zig");
const Processing = @import("Processing.zig");
const SharedMemoryAvailability = @import("SharedMemoryAvailability.zig");
terminal: vt.Terminal,
stream: vt.TerminalStream,
allocator: std.mem.Allocator,
write_pty: ?*const fn (*vt.TerminalStream.Handler, [:0]const u8) void,
payload_limit: usize,
storage_limit: usize,
batches: [2]Batch = .{ .{}, .{} },
/// Batch bytes with answered file queries removed, when any were.
scratch: [source_namespace.batch_bytes]u8 = undefined,
active: u1 = 0,
worker: ?u1 = null,
enabled: bool,
dropped_events: u64 = 0,
dropped_bytes: u64 = 0,
queue_event_high_water: usize = 0,
queue_byte_high_water: usize = 0,
resets: u64 = 0,
failures: u64 = 0,

/// Initializes the bounded graphics-only terminal for one pane.
///
/// ```zig
/// try pipeline.init(.{ .io = io, .allocator = allocator, .size = size, .storage_limit = storage_limit, .payload_limit = payload_limit, .write_pty = write_pty });
/// ```
pub fn init(pipeline: *Pipeline, initialization: Initialization) !void {
    png.install();

    const io = initialization.io;
    const allocator = initialization.allocator;
    const size = initialization.size;
    const storage_limit = initialization.storage_limit;
    const payload_limit = initialization.payload_limit;
    const write_pty = initialization.write_pty;

    pipeline.allocator = allocator;
    pipeline.write_pty = write_pty;
    pipeline.payload_limit = payload_limit;
    pipeline.storage_limit = storage_limit;
    pipeline.terminal = try .init(io, allocator, .{
        .cols = size.cols,
        .rows = size.rows,
        .kitty_image_storage_limit = storage_limit,
        .kitty_image_loading_limits = source_namespace.image_loading_limits,
    });
    errdefer pipeline.terminal.deinit(allocator);
    pipeline.stream = pipeline.newStream();
    errdefer pipeline.stream.deinit();
    try pipeline.stream.handler.resize(source_namespace.vtResize(size));
    pipeline.batches = .{ .{}, .{} };
    pipeline.active = 0;
    pipeline.worker = null;
    pipeline.enabled = true;
    pipeline.dropped_events = 0;
    pipeline.dropped_bytes = 0;
    pipeline.queue_event_high_water = 0;
    pipeline.queue_byte_high_water = 0;
    pipeline.resets = 0;
    pipeline.failures = 0;
}

pub fn deinit(pipeline: *Pipeline) void {
    if (pipeline.worker) |index| {
        pipeline.batches[index].reset();
    }
    pipeline.worker = null;
    if (pipeline.enabled) {
        pipeline.stream.deinit();
    }
    pipeline.terminal.deinit(pipeline.allocator);
}

pub fn queueOutput(pipeline: *Pipeline, bytes: []const u8) void {
    if (bytes.len > source_namespace.batch_bytes) {
        pipeline.dropActive(bytes.len, 1);
        return;
    }
    var batch = &pipeline.batches[pipeline.active];
    if (!batch.pushOutput(bytes)) {
        pipeline.dropActive(bytes.len, 1);
        batch = &pipeline.batches[pipeline.active];
        _ = batch.pushOutput(bytes);
    }
    pipeline.observeQueueDepth();
}

pub fn queueResize(pipeline: *Pipeline, size: source_namespace.schema.TerminalSize) void {
    var batch = &pipeline.batches[pipeline.active];
    if (!batch.pushResize(size)) {
        pipeline.dropActive(0, 1);
        batch = &pipeline.batches[pipeline.active];
        _ = batch.pushResize(size);
    }
    pipeline.observeQueueDepth();
}

pub fn hasPending(pipeline: *const Pipeline) bool {
    return pipeline.worker == null and pipeline.batches[pipeline.active].event_count != 0;
}

pub fn seal(pipeline: *Pipeline) bool {
    if (!pipeline.hasPending()) {
        return false;
    }
    const sealed = pipeline.active;
    pipeline.active ^= 1;
    std.debug.assert(pipeline.batches[pipeline.active].event_count == 0);
    pipeline.worker = sealed;
    return true;
}

/// Reports whether ingestion state must be reset before replaying the seal.
/// Example: `if (pipeline.sealedRequiresReset()) resetIngestion();`.
pub fn sealedRequiresReset(pipeline: *const Pipeline) bool {
    return pipeline.batches[pipeline.worker.?].reset_before;
}

pub fn finishSealed(pipeline: *Pipeline) void {
    const index = pipeline.worker orelse unreachable;
    pipeline.batches[index].reset();
    pipeline.worker = null;
}

/// Replays one sealed media batch through a sink exposing
/// `observe([]const u8)` after folding obsolete shared-memory frames.
///
/// ```zig
/// pipeline.processSealed(.{ .current_size = size, .stats = stats }, &sink);
/// ```
pub fn processSealed(pipeline: *Pipeline, processing: Processing, sink: anytype) void {
    const current_size = processing.current_size;
    const stats = processing.stats;

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
            const remaining = source_namespace.stripFileQueries(bytes, &pipeline.scratch, sink);
            const filtered = source_namespace.filterAtomicSharedFrames(.{
                .bytes = remaining,
                .storage_limit = pipeline.storage_limit,
            }, sink, SharedMemoryAvailability{});
            stats.discarded_frames +|= filtered.discarded;
            stats.unavailable_frames +|= filtered.unavailable;
            stats.forwarded_frames +|= filtered.forwarded;
            stats.direct_frames +|= filtered.direct;
            stats.file_frames +|= filtered.file;
            stats.output_bytes +|= bytes.len;
        },
        .resize => |size| pipeline.stream.handler.resize(source_namespace.vtResize(size)) catch {
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

fn observeQueueDepth(pipeline: *Pipeline) void {
    var events: usize = 0;
    var bytes: usize = 0;
    for (&pipeline.batches) |*batch| {
        events += batch.event_count;
        bytes += batch.len;
    }
    pipeline.queue_event_high_water = @max(pipeline.queue_event_high_water, events);
    pipeline.queue_byte_high_water = @max(pipeline.queue_byte_high_water, bytes);
}

fn resetState(pipeline: *Pipeline, size: source_namespace.schema.TerminalSize) !void {
    if (pipeline.enabled) {
        pipeline.stream.deinit();
    }
    pipeline.enabled = false;
    pipeline.terminal.fullReset();
    pipeline.stream = pipeline.newStream();
    errdefer pipeline.stream.deinit();
    try pipeline.stream.handler.resize(source_namespace.vtResize(size));
    pipeline.enabled = true;
}

fn newStream(pipeline: *Pipeline) vt.TerminalStream {
    var handler = pipeline.terminal.vtHandler();
    handler.apc_handler.max_bytes.put(.kitty, pipeline.payload_limit);
    handler.apc_handler.enable(.glyph, false);
    handler.effects.write_pty = pipeline.write_pty;
    return .init(.{ .allocator = pipeline.allocator, .handler = handler });
}
