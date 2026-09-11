const std = @import("std");
const TerminalSizeType = @import("telar-core").TerminalSize;
const PipelineType = @import("telar-backend").Pipeline;
const builtin = @import("builtin");
const main = @import("main.zig");
const max_image_bytes_per_screen_module = @import("telar-core").max_image_bytes_per_screen;
const max_encoded_chunk_bytes_module = @import("telar-core").max_encoded_chunk_bytes;
const StatsType = @import("telar-backend").Stats;
const Sink = @import("Sink.zig");
const freezeSharedPixels_module = @import("telar-backend").freezeSharedPixels;
/// One terminal-browser style frame at 4K crossing the runtime: the child
/// publishes a shared object, the media pipeline folds the envelope and lets
/// Ghostty VT copy and unlink it, and the attachment freezes the resident
/// generation for a local client. Each stage is timed on its own so the
/// child's publish cost can be subtracted from the ingest figure.
const SharedFrameContext = @This();

const width = 3840;
const height = 2160;
const raw_len = width * height * 4;
const control = "\x1b[?2026h\x1b[H\x1b_Ga=T,f=32,s=3840,v=2160,t=s,i=7,p=1,C=1,q=2;";
const trailer = "\x1b\\\x1b[?2026l";

io: std.Io,
gpa: std.mem.Allocator,
pixels: []u8,
size: TerminalSizeType,
/// Heap-allocated: the emulator stream keeps pointers into its terminal,
/// so the pipeline must never move after `init`.
pipeline: *PipelineType,
sequence: u64 = 0,
name: [64]u8 = undefined,
name_len: usize = 0,
envelope: [256]u8 = undefined,
envelope_len: usize = 0,

pub fn init(io: std.Io, gpa: std.mem.Allocator) !SharedFrameContext {
    if (comptime builtin.os.tag == .windows or !builtin.link_libc) {
        return error.SharedMemoryUnavailable;
    }
    const pixels = try gpa.alloc(u8, raw_len);
    errdefer gpa.free(pixels);
    for (pixels, 0..) |*byte, index| byte.* = @truncate(index % 251);

    const size: TerminalSizeType = .{
        .cols = main.cols,
        .rows = main.rows,
        .cell_width_px = width / main.cols,
        .cell_height_px = height / main.rows,
    };
    const pipeline = try gpa.create(PipelineType);
    errdefer gpa.destroy(pipeline);
    const context: SharedFrameContext = .{
        .io = io,
        .gpa = gpa,
        .pixels = pixels,
        .size = size,
        .pipeline = pipeline,
    };
    try pipeline.init(.{
        .io = io,
        .allocator = gpa,
        .size = size,
        .storage_limit = max_image_bytes_per_screen_module,
        .payload_limit = max_encoded_chunk_bytes_module,
        .write_pty = null,
    });
    return context;
}

pub fn deinit(context: *SharedFrameContext) void {
    context.pipeline.deinit();
    context.gpa.destroy(context.pipeline);
    context.gpa.free(context.pixels);
}

/// The child's side of one frame: a fresh object, its size, one memcpy.
pub fn publish(context: *SharedFrameContext) !void {
    context.sequence += 1;
    const name = try std.fmt.bufPrintZ(
        &context.name,
        "/tlrbench{x}-{x}",
        .{ @as(u32, @bitCast(std.c.getpid())), context.sequence },
    );
    context.name_len = name.len;
    const fd = std.c.shm_open(
        name,
        @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true })),
        @as(u16, 0o600),
    );
    if (std.posix.errno(fd) != .SUCCESS) {
        return error.SharedMemoryUnavailable;
    }
    defer _ = std.c.close(fd);
    if (std.c.ftruncate(fd, @intCast(raw_len)) != 0) {
        return error.SharedMemoryUnavailable;
    }
    const map = try std.posix.mmap(
        null,
        raw_len,
        .{ .READ = true, .WRITE = true },
        std.c.MAP{ .TYPE = .SHARED },
        fd,
        0,
    );
    defer std.posix.munmap(map);
    @memcpy(map[0..raw_len], context.pixels);

    const Encoder = std.base64.standard.Encoder;
    var encoded: [128]u8 = undefined;
    const payload = Encoder.encode(encoded[0..Encoder.calcSize(name.len)], name);
    const envelope = try std.fmt.bufPrint(&context.envelope, "{s}{s}{s}", .{ control, payload, trailer });
    context.envelope_len = envelope.len;
}

pub fn unpublish(context: *SharedFrameContext) void {
    _ = std.c.shm_unlink(context.name[0..context.name_len :0]);
}

/// The runtime's media actor for one batch holding the published frame.
pub fn ingest(context: *SharedFrameContext) !u64 {
    context.pipeline.queueOutput(context.envelope[0..context.envelope_len]);
    if (!context.pipeline.seal()) {
        return error.MediaBatchEmpty;
    }
    var stats: StatsType = .{};
    var sink: Sink = .{ .pipeline = context.pipeline };
    context.pipeline.processSealed(.{ .current_size = context.size, .stats = &stats }, &sink);
    context.pipeline.finishSealed();
    if (stats.forwarded_frames != 1 or stats.failed) {
        return error.SharedFrameNotForwarded;
    }
    const image = context.pipeline.terminal.screens.active.kitty_images.imageById(7) orelse
        return error.KgpImageMissing;
    return image.generation + image.data.len();
}

/// The freeze the send loop performs for a local client, then the unlink
/// Ghostty would do after consuming it.
pub fn freeze(context: *SharedFrameContext) !u64 {
    const name = freezeSharedPixels_module(context.pixels) orelse
        return error.SharedMemoryUnavailable;
    _ = std.c.shm_unlink(name.sliceZ());
    return name.slice().len;
}
