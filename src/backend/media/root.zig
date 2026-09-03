//! Bounded Kitty graphics pipeline for one pane.
//!
//! The interactive terminal ignores Kitty APCs. This pipeline consumes a
//! copy of the same PTY output on a separate actor and owns the terminal whose
//! only durable product is graphics storage. Feeding all output, not only APC
//! payloads, keeps cursor-relative placements and scroll pins equivalent to
//! the interactive terminal without sharing mutable emulator state.

const std = @import("std");
const builtin = @import("builtin");
const vt = @import("ghostty-vt");
const core = @import("telar-core");

const shared_transfer = @import("../pane/shared_transfer.zig");

const Io = std.Io;
const schema = core.schema;

pub const batch_bytes = 4 * 16 * 1024;
pub const batch_events = 64;

/// Raw pixels may cross the local child/runtime boundary through POSIX shared
/// memory. The emulator's own path-based media stays disabled so it can never
/// open an arbitrary file; complete file frames and file capability queries
/// are answered by the pane, which validates the file first.
pub const image_loading_limits: vt.kitty.graphics.LoadingImage.Limits = .{
    .file = false,
    .temporary_file = .disabled,
    .shared_memory = true,
};

/// Where a complete frame's pixels live before the runtime copies them.
pub const Medium = enum { shared, file };

pub const Stats = struct {
    output_bytes: u64 = 0,
    /// Shared frames folded because a newer frame of the same placement was
    /// available in the batch: latest-wins working as designed.
    discarded_frames: u64 = 0,
    /// Shared frames dropped because no frame of their placement passed the
    /// availability probe: the producer's object was gone or over the limit.
    /// Sustained growth here means the pane shows a stale image.
    unavailable_frames: u64 = 0,
    /// Shared frames actually fed to the media terminal. Together with the
    /// two counters above this partitions every frame, so `forwarded` moving
    /// while the graphics revision stays still isolates a silent load
    /// failure inside the emulator.
    forwarded_frames: u64 = 0,
    /// Wall time the media actor spent on this batch, including every shared
    /// frame it mapped, copied into pane storage and unlinked.
    elapsed_ns: u64 = 0,
    /// Generations the actor froze into runtime-owned shared objects for
    /// local clients to adopt without another copy.
    prepared_frames: u64 = 0,
    /// Shared frames copied once, from the child's object straight into the
    /// runtime-owned object that then serves as emulator storage.
    direct_frames: u64 = 0,
    /// The subset of `direct_frames` whose pixels came from a child file.
    file_frames: u64 = 0,
    reset: bool = false,
    failed: bool = false,
};

pub const Initialization = struct {
    io: Io,
    allocator: std.mem.Allocator,
    size: schema.TerminalSize,
    storage_limit: usize,
    payload_limit: usize,
    write_pty: ?*const fn (*vt.TerminalStream.Handler, [:0]const u8) void,
};

pub const Processing = struct {
    current_size: schema.TerminalSize,
    stats: *Stats,
};

pub const PlacementSource = struct {
    key: vt.kitty.graphics.ImageStorage.PlacementKey,
    placement: vt.kitty.graphics.ImageStorage.Placement,
    image: vt.kitty.graphics.Image,
};

const atomic_shared_prefix = "\x1b[?2026h\x1b[H\x1b_G";
const atomic_shared_suffix = "\x1b\\\x1b[?2026l";

const SharedFrameKey = struct {
    image_id: u32,
    placement_id: u32,
};

const SharedFrame = struct {
    start: usize,
    end: usize,
    /// The KGP command inside the envelope, APC introducer to terminator.
    apc_start: usize,
    apc_end: usize,
    payload_start: usize,
    payload_end: usize,
    key: SharedFrameKey,
    byte_len: usize,
    format: core.graphics.Format,
    width: u32,
    height: u32,
    medium: Medium,
};

/// One complete shared-memory frame the filter selected, handed to a sink
/// that can load it without the emulator's parser. `bytes` spans the whole
/// synchronized envelope; the APC command sits at `apc_start..apc_end`.
///
/// ```zig
/// pub fn observeSharedFrame(sink: *Sink, frame: SharedFrameView) bool
/// ```
pub const SharedFrameView = struct {
    bytes: []const u8,
    apc_start: usize,
    apc_end: usize,
    encoded_name: []const u8,
    image_id: u32,
    placement_id: u32,
    format: core.graphics.Format,
    width: u32,
    height: u32,
    byte_len: usize,
    medium: Medium,
};

/// A `a=q,t=f` capability query the pane answers itself, since the emulator
/// never opens child paths. `bytes` is the whole APC command.
///
/// ```zig
/// pub fn observeFileQuery(sink: *Sink, query: FileQueryView) bool
/// ```
pub const FileQueryView = struct {
    bytes: []const u8,
    encoded_path: []const u8,
    image_id: u32,
    byte_len: usize,
};

const SelectedSharedFrame = struct {
    key: SharedFrameKey,
    recent_starts: [8]usize = undefined,
    recent_count: u4,
    start: ?usize = null,
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
        if (bytes.len > batch.bytes.len - batch.len) {
            return false;
        }
        const offset = batch.len;
        @memcpy(batch.bytes[offset..][0..bytes.len], bytes);
        batch.len += bytes.len;

        // Output slices are one byte stream. Merge adjacent PTY reads so the
        // event bound measures output/resize ordering rather than scheduler
        // granularity; TerminalStream is required to be slice-independent.
        if (batch.event_count != 0) {
            switch (batch.events[batch.event_count - 1]) {
                .output => |output| {
                    if (@as(usize, output.offset) + output.len == offset) {
                        batch.events[batch.event_count - 1].output.len += @intCast(bytes.len);
                        return true;
                    }
                },
                .resize => {},
            }
        }
        if (batch.event_count == batch.events.len) {
            batch.len = offset;
            return false;
        }
        batch.events[batch.event_count] = .{ .output = .{
            .offset = @intCast(offset),
            .len = @intCast(bytes.len),
        } };
        batch.event_count += 1;
        return true;
    }

    fn pushResize(batch: *Batch, size: schema.TerminalSize) bool {
        if (batch.event_count == batch.events.len) {
            return false;
        }
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
    storage_limit: usize,
    batches: [2]Batch = .{ .{}, .{} },
    /// Batch bytes with answered file queries removed, when any were.
    scratch: [batch_bytes]u8 = undefined,
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
            .kitty_image_loading_limits = image_loading_limits,
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
        pipeline.observeQueueDepth();
    }

    pub fn queueResize(pipeline: *Pipeline, size: schema.TerminalSize) void {
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
                const remaining = stripFileQueries(bytes, &pipeline.scratch, sink);
                const filtered = filterAtomicSharedFrames(.{
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

/// Terminal-browser publishes complete shared-memory replacements inside one
/// synchronized-output envelope. A busy media actor only needs the newest
/// replacement for each placement; mapping older frames would spend the pane
/// quota and then overwrite the result. Bytes outside this exact shape remain
/// untouched and therefore keep Ghostty as the sole terminal emulator.
pub const FilterStats = struct {
    discarded: u64 = 0,
    unavailable: u64 = 0,
    forwarded: u64 = 0,
    /// The subset of `forwarded` the sink loaded without the parser.
    direct: u64 = 0,
    /// The subset of `direct` whose pixels came from a child file.
    file: u64 = 0,
};

const FilterInput = struct {
    bytes: []const u8,
    storage_limit: usize,
};

const FrameResource = struct {
    encoded_name: []const u8,
    byte_len: usize,
    limit: usize,
    medium: Medium,
};

const SharedMemoryAvailability = struct {
    pub fn available(_: SharedMemoryAvailability, resource: FrameResource) bool {
        return switch (resource.medium) {
            .shared => sharedFrameAvailable(resource),
            .file => resource.byte_len <= resource.limit and
                shared_transfer.validateChildFile(resource.encoded_name, resource.byte_len),
        };
    }
};

/// Removes `a=q,t=f` queries the sink answered from `bytes`, so the emulator
/// never sees a file query it would refuse. Returns `bytes` untouched when
/// nothing was answered, otherwise the remaining bytes in `scratch`.
///
/// ```zig
/// const remaining = stripFileQueries(bytes, &pipeline.scratch, sink);
/// ```
fn stripFileQueries(bytes: []const u8, scratch: []u8, sink: anytype) []const u8 {
    var kept: usize = 0;
    var copied_until: usize = 0;
    var search_from: usize = 0;
    var stripped = false;
    while (std.mem.indexOfPos(u8, bytes, search_from, "\x1b_G")) |start| {
        const terminator = std.mem.indexOfPos(u8, bytes, start + 3, "\x1b\\") orelse break;
        const end = terminator + 2;
        search_from = end;
        const command = bytes[start + 3 .. terminator];
        const separator = std.mem.indexOfScalar(u8, command, ';') orelse continue;
        const query = parseFileQueryControl(command[0..separator]) orelse continue;
        if (separator + 1 == command.len) continue;
        const handled = sink.observeFileQuery(.{
            .bytes = bytes[start..end],
            .encoded_path = command[separator + 1 ..],
            .image_id = query.image_id,
            .byte_len = query.byte_len,
        });
        if (!handled) continue;
        const run = bytes[copied_until..start];
        @memcpy(scratch[kept..][0..run.len], run);
        kept += run.len;
        copied_until = end;
        stripped = true;
    }
    if (!stripped) return bytes;
    const tail = bytes[copied_until..];
    @memcpy(scratch[kept..][0..tail.len], tail);
    return scratch[0 .. kept + tail.len];
}

const FileQueryControl = struct {
    image_id: u32,
    byte_len: usize,
};

fn parseFileQueryControl(control: []const u8) ?FileQueryControl {
    var image_id: ?u32 = null;
    var format: ?u8 = null;
    var width: ?u32 = null;
    var height: ?u32 = null;
    var query = false;
    var file = false;
    var fields = std.mem.splitScalar(u8, control, ',');
    while (fields.next()) |field| {
        const equals = std.mem.indexOfScalar(u8, field, '=') orelse return null;
        if (equals != 1 or equals + 1 == field.len) return null;
        const value = field[equals + 1 ..];
        switch (field[0]) {
            'a' => {
                if (query or !std.mem.eql(u8, value, "q")) return null;
                query = true;
            },
            't' => {
                if (file or !std.mem.eql(u8, value, "f")) return null;
                file = true;
            },
            'i' => image_id = parseUniqueU32(image_id, value) orelse return null,
            'f' => {
                if (format != null) return null;
                const parsed = std.fmt.parseUnsigned(u8, value, 10) catch return null;
                if (parsed != 24 and parsed != 32) return null;
                format = parsed;
            },
            's' => width = parseUniqueU32(width, value) orelse return null,
            'v' => height = parseUniqueU32(height, value) orelse return null,
            'q' => {},
            else => return null,
        }
    }
    if (!query or !file) return null;
    const bpp: usize = if ((format orelse 32) == 24) 3 else 4;
    const pixels = std.math.mul(
        usize,
        @as(usize, width orelse return null),
        @as(usize, height orelse return null),
    ) catch return null;
    return .{
        .image_id = image_id orelse return null,
        .byte_len = std.math.mul(usize, pixels, bpp) catch return null,
    };
}

fn filterAtomicSharedFrames(input: FilterInput, sink: anytype, availability: anytype) FilterStats {
    const bytes = input.bytes;
    const storage_limit = input.storage_limit;

    var emitted_until: usize = 0;
    var search_from: usize = 0;
    var filtered: FilterStats = .{};

    while (findSharedFrame(bytes, search_from)) |first| {
        var selected: [core.graphics.max_placements_per_pane]SelectedSharedFrame = undefined;
        var selected_count: usize = 0;
        var group_end = first.end;
        var overflow = !recordSharedFrame(&selected, &selected_count, first);
        while (sharedFrameAt(bytes, group_end)) |frame| {
            if (!recordSharedFrame(&selected, &selected_count, frame)) overflow = true;
            group_end = frame.end;
        }

        if (!overflow) {
            for (selected[0..selected_count]) |*entry| {
                var recent = entry.recent_count;
                while (recent != 0) {
                    recent -= 1;
                    const frame = sharedFrameAt(bytes, entry.recent_starts[recent]) orelse
                        unreachable;
                    if (!availability.available(.{
                        .encoded_name = bytes[frame.payload_start..frame.payload_end],
                        .byte_len = frame.byte_len,
                        .limit = storage_limit,
                        .medium = frame.medium,
                    })) continue;
                    entry.start = frame.start;
                    break;
                }
            }

            observeNonEmpty(sink, bytes[emitted_until..first.start]);
            var frame_start = first.start;
            while (frame_start < group_end) {
                const frame = sharedFrameAt(bytes, frame_start) orelse unreachable;
                const chosen = selectedFrameStart(selected[0..selected_count], frame.key);
                if (chosen == frame.start) {
                    // A sink that loads the object itself skips the parser's
                    // copy; otherwise the emulator parses the command as is.
                    const direct = sink.observeSharedFrame(.{
                        .bytes = bytes[frame.start..frame.end],
                        .apc_start = frame.apc_start - frame.start,
                        .apc_end = frame.apc_end - frame.start,
                        .encoded_name = bytes[frame.payload_start..frame.payload_end],
                        .image_id = frame.key.image_id,
                        .placement_id = frame.key.placement_id,
                        .format = frame.format,
                        .width = frame.width,
                        .height = frame.height,
                        .byte_len = frame.byte_len,
                        .medium = frame.medium,
                    });
                    if (direct) {
                        filtered.direct +|= 1;
                        filtered.file +|= @intFromBool(frame.medium == .file);
                        filtered.forwarded +|= 1;
                    } else if (frame.medium == .file) {
                        // The emulator refuses file media; the pane keeps its
                        // current image for this batch.
                        filtered.unavailable +|= 1;
                    } else {
                        sink.observe(bytes[frame.start..frame.end]);
                        filtered.forwarded +|= 1;
                    }
                } else if (chosen == null) {
                    // No frame of this placement survived the availability
                    // probe; the pane keeps its stale image this batch.
                    filtered.unavailable +|= 1;
                } else {
                    filtered.discarded +|= 1;
                }
                frame_start = frame.end;
            }
            emitted_until = group_end;
        }
        search_from = group_end;
    }

    observeNonEmpty(sink, bytes[emitted_until..]);
    return filtered;
}

fn observeNonEmpty(sink: anytype, bytes: []const u8) void {
    if (bytes.len != 0) {
        sink.observe(bytes);
    }
}

fn recordSharedFrame(selected: []SelectedSharedFrame, selected_count: *usize, frame: SharedFrame) bool {
    for (selected[0..selected_count.*]) |*entry| {
        if (!std.meta.eql(entry.key, frame.key)) continue;
        if (entry.recent_count == entry.recent_starts.len) {
            std.mem.copyForwards(
                usize,
                entry.recent_starts[0 .. entry.recent_starts.len - 1],
                entry.recent_starts[1..],
            );
            entry.recent_count -= 1;
        }
        entry.recent_starts[entry.recent_count] = frame.start;
        entry.recent_count += 1;
        return true;
    }
    if (selected_count.* == selected.len) return false;
    selected[selected_count.*] = .{
        .key = frame.key,
        .recent_count = 1,
    };
    selected[selected_count.*].recent_starts[0] = frame.start;
    selected_count.* += 1;
    return true;
}

fn selectedFrameStart(selected: []const SelectedSharedFrame, key: SharedFrameKey) ?usize {
    for (selected) |entry| if (std.meta.eql(entry.key, key)) return entry.start;
    return null;
}

fn sharedFrameAvailable(resource: FrameResource) bool {
    if (resource.byte_len > resource.limit) {
        return false;
    }
    if (comptime builtin.os.tag == .windows or builtin.abi.isAndroid() or !builtin.link_libc)
        return false;

    const Decoder = std.base64.standard.Decoder;
    const name_len = Decoder.calcSizeForSlice(resource.encoded_name) catch return false;
    if (name_len == 0 or name_len > std.fs.max_path_bytes) return false;
    var name_buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    Decoder.decode(name_buffer[0..name_len], resource.encoded_name) catch return false;
    if (std.mem.indexOfScalar(u8, name_buffer[0..name_len], 0) != null) return false;
    name_buffer[name_len] = 0;
    const name: [:0]const u8 = name_buffer[0..name_len :0];
    const fd = std.c.shm_open(
        name,
        @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })),
        @as(u16, 0),
    );
    if (std.posix.errno(fd) != .SUCCESS) return false;
    _ = std.c.close(fd);
    return true;
}

fn findSharedFrame(bytes: []const u8, from: usize) ?SharedFrame {
    var search_from = from;
    while (std.mem.indexOfPos(u8, bytes, search_from, atomic_shared_prefix)) |start| {
        if (sharedFrameAt(bytes, start)) |frame| return frame;
        search_from = start + atomic_shared_prefix.len;
    }
    return null;
}

fn sharedFrameAt(bytes: []const u8, start: usize) ?SharedFrame {
    if (start > bytes.len or
        !std.mem.startsWith(u8, bytes[start..], atomic_shared_prefix)) return null;
    const command_start = start + atomic_shared_prefix.len;
    const terminator = std.mem.indexOfPos(u8, bytes, command_start, "\x1b\\") orelse return null;
    if (!std.mem.startsWith(u8, bytes[terminator..], atomic_shared_suffix)) return null;
    const command = bytes[command_start..terminator];
    const separator = std.mem.indexOfScalar(u8, command, ';') orelse return null;
    const parsed = parseSharedFrameControl(command[0..separator]) orelse return null;
    if (separator + 1 == command.len) return null;
    return .{
        .start = start,
        .end = terminator + atomic_shared_suffix.len,
        .apc_start = command_start - "\x1b_G".len,
        .apc_end = terminator + "\x1b\\".len,
        .payload_start = command_start + separator + 1,
        .payload_end = terminator,
        .key = parsed.key,
        .byte_len = parsed.byte_len,
        .format = parsed.format,
        .width = parsed.width,
        .height = parsed.height,
        .medium = parsed.medium,
    };
}

const SharedFrameControl = struct {
    key: SharedFrameKey,
    byte_len: usize,
    format: core.graphics.Format,
    width: u32,
    height: u32,
    medium: Medium,
};

fn parseSharedFrameControl(control: []const u8) ?SharedFrameControl {
    var image_id: ?u32 = null;
    var placement_id: ?u32 = null;
    var format: ?u8 = null;
    var width: ?u32 = null;
    var height: ?u32 = null;
    var transmit = false;
    var medium: ?Medium = null;
    var cursor_static = false;
    var quiet = false;
    var fields = std.mem.splitScalar(u8, control, ',');
    while (fields.next()) |field| {
        const equals = std.mem.indexOfScalar(u8, field, '=') orelse return null;
        if (equals != 1 or equals + 1 == field.len) return null;
        const value = field[equals + 1 ..];
        switch (field[0]) {
            'a' => {
                if (transmit or !std.mem.eql(u8, value, "T")) return null;
                transmit = true;
            },
            't' => {
                if (medium != null) return null;
                medium = if (std.mem.eql(u8, value, "s")) .shared else if (std.mem.eql(u8, value, "f")) .file else return null;
            },
            'i' => image_id = parseUniqueU32(image_id, value) orelse return null,
            'p' => placement_id = parseUniqueU32(placement_id, value) orelse return null,
            'f' => {
                if (format != null) return null;
                const parsed = std.fmt.parseUnsigned(u8, value, 10) catch return null;
                if (parsed != 24 and parsed != 32) return null;
                format = parsed;
            },
            's' => width = parseUniqueU32(width, value) orelse return null,
            'v' => height = parseUniqueU32(height, value) orelse return null,
            'C' => {
                if (cursor_static or !std.mem.eql(u8, value, "1")) return null;
                cursor_static = true;
            },
            'q' => {
                if (quiet or !std.mem.eql(u8, value, "2")) return null;
                quiet = true;
            },
            // Chunked transmissions carry ordering state and are never folded.
            // Any other key (offsets, sizes, crops, z) means the frame is
            // not the plain full replacement this fold understands.
            else => return null,
        }
    }
    if (!transmit or !cursor_static or !quiet) return null;
    const image = image_id orelse return null;
    const placement = placement_id orelse return null;
    const depth = format orelse return null;
    const bpp: usize = if (depth == 24) 3 else 4;
    const pixels = std.math.mul(
        usize,
        @as(usize, width orelse return null),
        @as(usize, height orelse return null),
    ) catch return null;
    const byte_len = std.math.mul(usize, pixels, bpp) catch return null;
    return .{
        .key = .{ .image_id = image, .placement_id = placement },
        .byte_len = byte_len,
        .format = if (depth == 24) .rgb else .rgba,
        .width = width.?,
        .height = height.?,
        .medium = medium orelse return null,
    };
}

fn parseUniqueU32(current: ?u32, value: []const u8) ?u32 {
    if (current != null) return null;
    const parsed = std.fmt.parseUnsigned(u32, value, 10) catch return null;
    return if (parsed == 0) null else parsed;
}

/// Stable identity for a child placement. Anonymous placements use Ghostty's
/// internal namespace; explicit child IDs use the exterior namespace. Adding
/// one reserves zero as the invalid value in Telar's wire vocabulary.
///
/// ```zig
/// const virtual_id = placementVirtualId(key);
/// ```
pub fn placementVirtualId(key: vt.kitty.graphics.ImageStorage.PlacementKey) u64 {
    const tag: u64 = switch (key.placement_id.tag) {
        .internal => 0,
        .external => 1,
    };
    return ((tag << 32) | key.placement_id.id) + 1;
}

/// Converts Ghostty's pinned placement into pane-relative coordinates.
///
/// Both the runtime sync path and the reduced terminal-browser example use
/// this adapter. Keeping one implementation matters here: a second geometry
/// conversion in the example could hide the production bug it is meant to
/// isolate.
///
/// ```zig
/// const placement = placementValue(terminal, source) orelse return;
/// ```
pub fn placementValue(terminal: *vt.Terminal, source_value: PlacementSource) ?core.graphics.Placement {
    const pin = switch (source_value.placement.location) {
        .pin => |value| value,
        .virtual => return null,
    };
    if (pin.garbage) return null;
    const pages = &terminal.screens.active.pages;
    const screen_point = pages.pointFromPin(.screen, pin.*) orelse return null;
    const viewport = pages.pointFromPin(.screen, pages.getTopLeft(.viewport)) orelse return null;
    const source = source_value.placement.sourceRect(source_value.image);
    return .{
        .key = .{ .image_id = source_value.image.id, .generation = source_value.image.generation },
        .virtual_id = placementVirtualId(source_value.key),
        .placement_id = switch (source_value.key.placement_id.tag) {
            .internal => 0,
            .external => source_value.key.placement_id.id,
        },
        .x = @intCast(screen_point.screen.x),
        .y = @as(i32, @intCast(screen_point.screen.y)) -
            @as(i32, @intCast(viewport.screen.y)),
        .source_x = source.x,
        .source_y = source.y,
        .source_width = source.width,
        .source_height = source.height,
        .columns = source_value.placement.columns,
        .rows = source_value.placement.rows,
        .offset_x = source_value.placement.x_offset,
        .offset_y = source_value.placement.y_offset,
        .z_index = source_value.placement.z,
    };
}

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

const TestOutput = struct {
    bytes: [4096]u8 = undefined,
    len: usize = 0,
    direct: bool = false,
    direct_frames: usize = 0,
    last_direct: ?SharedFrameView = null,
    queries: usize = 0,
    last_query_id: u32 = 0,
    last_query_len: usize = 0,

    pub fn observe(output: *TestOutput, bytes: []const u8) void {
        @memcpy(output.bytes[output.len..][0..bytes.len], bytes);
        output.len += bytes.len;
    }

    pub fn observeSharedFrame(output: *TestOutput, frame: SharedFrameView) bool {
        if (!output.direct) return false;
        output.direct_frames += 1;
        output.last_direct = frame;
        return true;
    }

    pub fn observeFileQuery(output: *TestOutput, query: FileQueryView) bool {
        if (!output.direct) return false;
        output.queries += 1;
        output.last_query_id = query.image_id;
        output.last_query_len = query.byte_len;
        return true;
    }

    fn slice(output: *const TestOutput) []const u8 {
        return output.bytes[0..output.len];
    }
};

test "file frames parse like shared ones and are never handed to the emulator" {
    const frame = "\x1b[?2026h\x1b[H\x1b_Ga=T,f=32,s=2,v=1,t=f,i=7,p=1,C=1,q=2;L3RtcC9m\x1b\\\x1b[?2026l";
    var direct: TestOutput = .{ .direct = true };
    try std.testing.expectEqual(
        FilterStats{ .forwarded = 1, .direct = 1, .file = 1 },
        filterAtomicSharedFrames(.{ .bytes = frame, .storage_limit = 8 }, &direct, TestAvailability.all),
    );
    try std.testing.expectEqual(Medium.file, direct.last_direct.?.medium);

    var parser_only: TestOutput = .{};
    try std.testing.expectEqual(
        FilterStats{ .unavailable = 1 },
        filterAtomicSharedFrames(.{ .bytes = frame, .storage_limit = 8 }, &parser_only, TestAvailability.all),
    );
    try std.testing.expectEqualStrings("", parser_only.slice());
}

test "answered file queries are removed from what the emulator parses" {
    const query = "\x1b_Gi=300,a=q,t=f,f=32,s=1,v=1;L3RtcC9w\x1b\\";
    const input = "head" ++ query ++ "tail";
    var scratch: [256]u8 = undefined;

    var answering: TestOutput = .{ .direct = true };
    try std.testing.expectEqualStrings("headtail", stripFileQueries(input, &scratch, &answering));
    try std.testing.expectEqual(@as(usize, 1), answering.queries);
    try std.testing.expectEqual(@as(u32, 300), answering.last_query_id);
    try std.testing.expectEqual(@as(usize, 4), answering.last_query_len);

    var silent: TestOutput = .{};
    try std.testing.expectEqualStrings(input, stripFileQueries(input, &scratch, &silent));
    // Shared-memory queries stay with the emulator, which answers them.
    const shm_query = "\x1b_Gi=299,a=q,t=s,f=32,s=1,v=1;L3B4LXE=\x1b\\";
    try std.testing.expectEqualStrings(shm_query, stripFileQueries(shm_query, &scratch, &answering));
    try std.testing.expectEqual(@as(usize, 1), answering.queries);
}

test "a sink that loads shared frames itself receives the parsed frame instead of bytes" {
    const frame = "\x1b[?2026h\x1b[H\x1b_Ga=T,f=32,s=2,v=1,t=s,i=7,p=3,C=1,q=2;L3B4LTE=\x1b\\\x1b[?2026l";
    var output: TestOutput = .{ .direct = true };

    try std.testing.expectEqual(
        FilterStats{ .discarded = 0, .unavailable = 0, .forwarded = 1, .direct = 1 },
        filterAtomicSharedFrames(.{ .bytes = "head" ++ frame ++ "tail", .storage_limit = 8 }, &output, TestAvailability.all),
    );
    try std.testing.expectEqualStrings("headtail", output.slice());
    const view = output.last_direct.?;
    try std.testing.expectEqualStrings(frame, view.bytes);
    try std.testing.expectEqualStrings("\x1b[?2026h\x1b[H", view.bytes[0..view.apc_start]);
    try std.testing.expectEqualStrings("\x1b[?2026l", view.bytes[view.apc_end..]);
    try std.testing.expectEqualStrings("L3B4LTE=", view.encoded_name);
    try std.testing.expectEqual(@as(u32, 7), view.image_id);
    try std.testing.expectEqual(@as(u32, 3), view.placement_id);
    try std.testing.expectEqual(core.graphics.Format.rgba, view.format);
    try std.testing.expectEqual(@as(u32, 2), view.width);
    try std.testing.expectEqual(@as(usize, 8), view.byte_len);
}

test "shared frames with crop or offset keys are left to the emulator parser" {
    const cropped = "\x1b[?2026h\x1b[H\x1b_Ga=T,f=32,s=1,v=1,t=s,i=7,p=1,C=1,q=2,x=1;L3B4LTE=\x1b\\\x1b[?2026l";
    var output: TestOutput = .{ .direct = true };

    try std.testing.expectEqual(
        FilterStats{},
        filterAtomicSharedFrames(.{ .bytes = cropped, .storage_limit = 8 }, &output, TestAvailability.all),
    );
    try std.testing.expectEqualStrings(cropped, output.slice());
}

const TestAvailability = enum {
    all,
    first_only,
    none,

    pub fn available(availability: TestAvailability, resource: FrameResource) bool {
        return switch (availability) {
            .all => resource.byte_len <= resource.limit,
            .first_only => resource.byte_len <= resource.limit and std.mem.eql(u8, resource.encoded_name, "L3B4LTE="),
            .none => false,
        };
    }
};

test "atomic shared-memory frames are latest-wins per placement" {
    const first = "\x1b[?2026h\x1b[H\x1b_Ga=T,f=32,s=1,v=1,t=s,i=7,p=1,C=1,q=2;L3B4LTE=\x1b\\\x1b[?2026l";
    const other = "\x1b[?2026h\x1b[H\x1b_Ga=T,f=32,s=1,v=1,t=s,i=8,p=1,C=1,q=2;L3B4LTI=\x1b\\\x1b[?2026l";
    const latest = "\x1b[?2026h\x1b[H\x1b_Ga=T,f=32,s=1,v=1,t=s,i=7,p=1,C=1,q=2;L3B4LTM=\x1b\\\x1b[?2026l";
    const input = "head" ++ first ++ other ++ latest ++ "tail";
    var output: TestOutput = .{};

    try std.testing.expectEqual(
        FilterStats{ .discarded = 1, .unavailable = 0, .forwarded = 2 },
        filterAtomicSharedFrames(.{ .bytes = input, .storage_limit = 4 }, &output, TestAvailability.all),
    );
    try std.testing.expectEqualStrings("head" ++ other ++ latest ++ "tail", output.slice());
}

test "shared frame folding falls back to the newest available resource" {
    const first = "\x1b[?2026h\x1b[H\x1b_Ga=T,f=32,s=1,v=1,t=s,i=7,p=1,C=1,q=2;L3B4LTE=\x1b\\\x1b[?2026l";
    const latest = "\x1b[?2026h\x1b[H\x1b_Ga=T,f=32,s=1,v=1,t=s,i=7,p=1,C=1,q=2;L3B4LTM=\x1b\\\x1b[?2026l";
    var output: TestOutput = .{};

    try std.testing.expectEqual(
        FilterStats{ .discarded = 1, .unavailable = 0, .forwarded = 1 },
        filterAtomicSharedFrames(.{
            .bytes = "head" ++ first ++ latest ++ "tail",
            .storage_limit = 4,
        }, &output, TestAvailability.first_only),
    );
    try std.testing.expectEqualStrings("head" ++ first ++ "tail", output.slice());
}

test "unavailable shared frames cannot delete the current image" {
    const frame = "\x1b[?2026h\x1b[H\x1b_Ga=T,f=32,s=1,v=1,t=s,i=7,p=1,C=1,q=2;L3B4LTE=\x1b\\\x1b[?2026l";
    var output: TestOutput = .{};

    try std.testing.expectEqual(
        FilterStats{ .discarded = 0, .unavailable = 1, .forwarded = 0 },
        filterAtomicSharedFrames(.{
            .bytes = "head" ++ frame ++ "tail",
            .storage_limit = 4,
        }, &output, TestAvailability.none),
    );
    try std.testing.expectEqualStrings("headtail", output.slice());
}

test "media terminal preserves cursor-relative KGP placement" {
    const size: schema.TerminalSize = .{
        .cols = 40,
        .rows = 8,
        .cell_width_px = 10,
        .cell_height_px = 20,
    };
    var pipeline: Pipeline = undefined;
    try pipeline.init(.{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .size = size,
        .storage_limit = 1024 * 1024,
        .payload_limit = 64 * 1024,
        .write_pty = null,
    });
    defer pipeline.deinit();

    const limits = pipeline.terminal.screens.active.kitty_images.image_limits;
    try std.testing.expect(limits.shared_memory);
    try std.testing.expect(!limits.file);
    try std.testing.expect(limits.temporary_file == .disabled);

    const Feed = struct {
        pipeline: *Pipeline,

        pub fn observe(feed: *@This(), bytes: []const u8) void {
            feed.pipeline.stream.nextSlice(bytes);
        }

        pub fn observeSharedFrame(_: *@This(), _: SharedFrameView) bool {
            return false;
        }

        pub fn observeFileQuery(_: *@This(), _: FileQueryView) bool {
            return false;
        }
    };
    var feed: Feed = .{ .pipeline = &pipeline };
    pipeline.queueOutput(
        "abc" ++
            "\x1b_Ga=T,f=32,s=1,v=1,t=d,i=7,p=3,c=2,r=1;AQID/w==\x1b\\" ++
            "tail",
    );
    try std.testing.expect(pipeline.seal());
    var stats: Stats = .{};
    pipeline.processSealed(.{ .current_size = size, .stats = &stats }, &feed);
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

test "media terminal loads KGP pixels from POSIX shared memory" {
    if (comptime builtin.os.tag == .windows or builtin.abi.isAndroid())
        return error.SkipZigTest;

    const pixels = [_]u8{ 1, 2, 3, 255 };
    var name_buffer: [128]u8 = undefined;
    const name = try std.fmt.bufPrintZ(
        &name_buffer,
        "/telar-media-test-{d}",
        .{std.c.getpid()},
    );
    defer _ = std.c.shm_unlink(name);

    const fd = std.c.shm_open(
        name,
        @as(c_int, @bitCast(std.c.O{
            .ACCMODE = .RDWR,
            .CREAT = true,
            .EXCL = true,
        })),
        @as(u16, 0o600),
    );
    try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(fd));
    defer _ = std.c.close(fd);
    try std.testing.expectEqual(@as(c_int, 0), std.c.ftruncate(fd, pixels.len));

    const map = try std.posix.mmap(
        null,
        pixels.len,
        .{ .READ = true, .WRITE = true },
        std.c.MAP{ .TYPE = .SHARED },
        fd,
        0,
    );
    @memcpy(map[0..pixels.len], &pixels);
    std.posix.munmap(map);

    const size: schema.TerminalSize = .{
        .cols = 40,
        .rows = 8,
        .cell_width_px = 10,
        .cell_height_px = 20,
    };
    var pipeline: Pipeline = undefined;
    try pipeline.init(.{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .size = size,
        .storage_limit = 1024 * 1024,
        .payload_limit = 64 * 1024,
        .write_pty = null,
    });
    defer pipeline.deinit();

    var encoded_name_buffer: [256]u8 = undefined;
    const encoded_name = std.base64.standard.Encoder.encode(
        encoded_name_buffer[0..std.base64.standard.Encoder.calcSize(name.len)],
        name,
    );
    var command_buffer: [512]u8 = undefined;
    const command = try std.fmt.bufPrint(
        &command_buffer,
        "\x1b_Ga=T,f=32,s=1,v=1,t=s,i=9,p=1,C=1,q=2;{s}\x1b\\",
        .{encoded_name},
    );
    pipeline.stream.nextSlice(command);

    const storage = &pipeline.terminal.screens.active.kitty_images;
    try std.testing.expectEqual(@as(usize, 1), storage.images.count());
    try std.testing.expectEqual(@as(usize, 1), storage.placements.count());
    try std.testing.expectEqualSlices(
        u8,
        &pixels,
        storage.imageById(9).?.data.bytes().?,
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
    try pipeline.init(.{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .size = size,
        .storage_limit = 1024 * 1024,
        .payload_limit = 64 * 1024,
        .write_pty = null,
    });
    defer pipeline.deinit();
    const full: [batch_bytes]u8 = @splat('x');
    pipeline.queueOutput(&full);
    pipeline.queueOutput("latest");
    try std.testing.expect(pipeline.seal());
    try std.testing.expect(pipeline.dropped_events != 0);
    try std.testing.expect(pipeline.batches[pipeline.worker.?].reset_before);
    pipeline.finishSealed();
}

test "adjacent PTY reads use the byte bound instead of the event bound" {
    var batch: Batch = .{};
    const read: [1024]u8 = @splat('x');
    for (0..batch_bytes / read.len) |_| try std.testing.expect(batch.pushOutput(&read));

    try std.testing.expectEqual(batch_bytes, batch.len);
    try std.testing.expectEqual(@as(usize, 1), batch.event_count);
    try std.testing.expectEqual(@as(u32, batch_bytes), batch.events[0].output.len);
    try std.testing.expect(!batch.pushOutput(&read));
}

test "output coalescing preserves resize order" {
    var batch: Batch = .{};
    try std.testing.expect(batch.pushOutput("ab"));
    try std.testing.expect(batch.pushOutput("cd"));
    try std.testing.expect(batch.pushResize(.{ .cols = 40, .rows = 12 }));
    try std.testing.expect(batch.pushOutput("ef"));
    try std.testing.expect(batch.pushOutput("gh"));

    try std.testing.expectEqual(@as(usize, 3), batch.event_count);
    try std.testing.expectEqual(@as(u32, 4), batch.events[0].output.len);
    try std.testing.expectEqual(@as(u16, 40), batch.events[1].resize.cols);
    try std.testing.expectEqual(@as(u32, 4), batch.events[2].output.len);
}

test "graphics terminal answers KGP queries and rejects unsupported payloads" {
    const previous_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = previous_log_level;

    const Capture = struct {
        var bytes: [512]u8 = undefined;
        var len: usize = 0;

        fn reset() void {
            len = 0;
        }

        fn writePty(_: *vt.TerminalStream.Handler, response: [:0]const u8) void {
            if (len + response.len > bytes.len) {
                @panic("KGP test response overflow");
            }

            @memcpy(bytes[len..][0..response.len], response);
            len += response.len;
        }
    };

    var terminal = try vt.Terminal.init(std.testing.io, std.testing.allocator, .{
        .cols = 10,
        .rows = 5,
        .kitty_image_storage_limit = core.graphics.max_image_bytes_per_screen,
        .kitty_image_loading_limits = .direct,
    });
    defer terminal.deinit(std.testing.allocator);

    var handler = terminal.vtHandler();
    handler.apc_handler.max_bytes.put(.kitty, core.graphics.max_encoded_chunk_bytes);
    handler.effects.write_pty = Capture.writePty;
    var stream = vt.TerminalStream.init(.{
        .allocator = std.testing.allocator,
        .handler = handler,
    });
    defer stream.deinit();

    Capture.reset();
    stream.nextSlice("\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\");
    try std.testing.expectEqualStrings("\x1b_Gi=31;OK\x1b\\", Capture.bytes[0..Capture.len]);
    try std.testing.expectEqual(@as(usize, 0), terminal.screens.active.kitty_images.images.count());

    Capture.reset();
    stream.nextSlice("\x1b_Ga=t,f=32,o=z,s=1,v=1,t=d,i=7,m=1;eAFjZGL+\x1b\\");
    stream.nextSlice("\x1b_Gm=0;DwABEwEG\x1b\\");
    const image = terminal.screens.active.kitty_images.imageById(7).?;
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255 }, image.data.bytes().?);

    Capture.reset();
    stream.nextSlice("\x1b_Ga=q,f=32,o=z,s=1,v=1,t=d,i=8;eAFjZGIGAAANAAc=\x1b\\");
    try std.testing.expect(std.mem.indexOf(u8, Capture.bytes[0..Capture.len], "EINVAL: invalid data") != null);
    try std.testing.expect(terminal.screens.active.kitty_images.imageById(8) == null);

    Capture.reset();
    stream.nextSlice("\x1b_Ga=q,f=24,s=1,v=1,t=f,i=9;L3RtcC9pbWFnZQ==\x1b\\");
    try std.testing.expect(std.mem.indexOf(u8, Capture.bytes[0..Capture.len], "EINVAL: unsupported medium") != null);
}
