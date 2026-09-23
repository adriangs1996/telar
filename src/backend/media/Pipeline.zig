const core = @import("telar-core");
const vt = @import("ghostty-vt");
const std = @import("std");
const Batch = @import("Batch.zig");
const media = @import("media.zig");
const Initialization = @import("Initialization.zig");
const png = @import("png.zig");
const Processing = @import("Processing.zig");
const FrameResource = @import("FrameResource.zig");
const shared_transfer = @import("shared_transfer.zig");
const Pipeline = @This();

terminal: vt.Terminal,
stream: vt.TerminalStream,
allocator: std.mem.Allocator,
write_pty: ?*const fn (*vt.TerminalStream.Handler, [:0]const u8) void,
payload_limit: usize,
storage_limit: usize,
batches: [2]Batch = .{ .{}, .{} },
/// Batch bytes with answered file queries removed, when any were.
scratch: [media.batch_bytes]u8 = undefined,
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
pub fn init(self: *Pipeline, initialization: Initialization) !void {
    png.install();

    const io = initialization.io;
    const allocator = initialization.allocator;
    const size = initialization.size;
    const storage_limit = initialization.storage_limit;
    const payload_limit = initialization.payload_limit;
    const write_pty = initialization.write_pty;

    self.allocator = allocator;
    self.write_pty = write_pty;
    self.payload_limit = payload_limit;
    self.storage_limit = storage_limit;
    self.terminal = try .init(io, allocator, .{
        .cols = size.cols,
        .rows = size.rows,
        .kitty_image_storage_limit = storage_limit,
        .kitty_image_loading_limits = media.image_loading_limits,
    });
    errdefer self.terminal.deinit(allocator);
    self.stream = self.newStream();
    errdefer self.stream.deinit();
    try self.stream.handler.resize(media.vtResize(size));
    self.batches = .{ .{}, .{} };
    self.active = 0;
    self.worker = null;
    self.enabled = true;
    self.dropped_events = 0;
    self.dropped_bytes = 0;
    self.queue_event_high_water = 0;
    self.queue_byte_high_water = 0;
    self.resets = 0;
    self.failures = 0;
}

pub fn deinit(self: *Pipeline) void {
    if (self.worker) |index| {
        self.batches[index].reset();
    }
    self.worker = null;
    if (self.enabled) {
        self.stream.deinit();
    }
    self.terminal.deinit(self.allocator);
}

pub fn queueOutput(self: *Pipeline, bytes: []const u8) void {
    if (bytes.len > media.batch_bytes) {
        self.dropActive(bytes.len, 1);
        return;
    }
    var batch = &self.batches[self.active];
    if (!batch.pushOutput(bytes)) {
        self.dropActive(bytes.len, 1);
        batch = &self.batches[self.active];
        _ = batch.pushOutput(bytes);
    }
    self.observeQueueDepth();
}

pub fn queueResize(self: *Pipeline, size: core.TerminalSize) void {
    var batch = &self.batches[self.active];
    if (!batch.pushResize(size)) {
        self.dropActive(0, 1);
        batch = &self.batches[self.active];
        _ = batch.pushResize(size);
    }
    self.observeQueueDepth();
}

pub fn hasPending(self: *const Pipeline) bool {
    return self.worker == null and self.batches[self.active].event_count != 0;
}

pub fn seal(self: *Pipeline) bool {
    if (!self.hasPending()) {
        return false;
    }
    const sealed = self.active;
    self.active ^= 1;
    std.debug.assert(self.batches[self.active].event_count == 0);
    self.worker = sealed;
    return true;
}

/// Reports whether ingestion state must be reset before replaying the seal.
/// Example: `if (pipeline.sealedRequiresReset()) resetIngestion();`.
pub fn sealedRequiresReset(self: *const Pipeline) bool {
    return self.batches[self.worker.?].reset_before;
}

pub fn finishSealed(self: *Pipeline) void {
    const index = self.worker orelse unreachable;
    self.batches[index].reset();
    self.worker = null;
}

/// Replays one sealed media batch through a sink exposing
/// `observe([]const u8)` after folding obsolete shared-memory frames.
///
/// ```zig
/// pipeline.processSealed(.{ .current_size = size, .stats = stats }, &sink);
/// ```
pub fn processSealed(self: *Pipeline, processing: Processing, sink: anytype) void {
    const current_size = processing.current_size;
    const stats = processing.stats;

    const batch = &self.batches[self.worker orelse return];
    if (batch.reset_before or !self.enabled) {
        self.resetState(current_size) catch {
            self.failures +|= 1;
            stats.failed = true;
            return;
        };
        self.resets +|= 1;
        stats.reset = true;
    }

    for (batch.events[0..batch.event_count]) |event| switch (event) {
        .output => |output| {
            const start: usize = output.offset;
            const bytes = batch.bytes[start..][0..output.len];
            const remaining = media.stripFileQueries(bytes, &self.scratch, sink);
            const filtered = media.filterAtomicSharedFrames(.{
                .bytes = remaining,
                .storage_limit = self.storage_limit,
            }, sink, SharedMemoryAvailability{});
            stats.discarded_frames +|= filtered.discarded;
            stats.unavailable_frames +|= filtered.unavailable;
            stats.forwarded_frames +|= filtered.forwarded;
            stats.direct_frames +|= filtered.direct;
            stats.file_frames +|= filtered.file;
            stats.output_bytes +|= bytes.len;
        },
        .resize => |size| self.stream.handler.resize(media.vtResize(size)) catch {
            self.failures +|= 1;
            stats.failed = true;
        },
    };
}

fn dropActive(self: *Pipeline, incoming_bytes: usize, incoming_events: usize) void {
    const batch = &self.batches[self.active];
    self.dropped_events +|= batch.event_count + incoming_events;
    self.dropped_bytes +|= batch.len + incoming_bytes;
    batch.reset();
    batch.reset_before = true;
}

fn observeQueueDepth(self: *Pipeline) void {
    var events: usize = 0;
    var bytes: usize = 0;
    for (&self.batches) |*batch| {
        events += batch.event_count;
        bytes += batch.len;
    }
    self.queue_event_high_water = @max(self.queue_event_high_water, events);
    self.queue_byte_high_water = @max(self.queue_byte_high_water, bytes);
}

fn resetState(self: *Pipeline, size: core.TerminalSize) !void {
    if (self.enabled) {
        self.stream.deinit();
    }
    self.enabled = false;
    self.terminal.fullReset();
    self.stream = self.newStream();
    errdefer self.stream.deinit();
    try self.stream.handler.resize(media.vtResize(size));
    self.enabled = true;
}

fn newStream(self: *Pipeline) vt.TerminalStream {
    var handler = self.terminal.vtHandler();
    handler.apc_handler.max_bytes.put(.kitty, self.payload_limit);
    handler.apc_handler.enable(.glyph, false);
    handler.effects.write_pty = self.write_pty;
    return .init(.{ .allocator = self.allocator, .handler = handler });
}

const SharedMemoryAvailability = struct {
    pub fn available(_: SharedMemoryAvailability, resource: FrameResource) bool {
        return switch (resource.medium) {
            .shared => media.sharedFrameAvailable(resource),
            .file => resource.byte_len <= resource.limit and
                shared_transfer.validateChildFile(resource.encoded_name, resource.byte_len),
        };
    }
};
