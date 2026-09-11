const vt = @import("ghostty-vt");
const std = @import("std");
const main = @import("main.zig");
const max_image_bytes_per_screen_module = @import("telar-core").max_image_bytes_per_screen;
const KgpIngestContext = @This();

const width = 1920;
const height = 1080;
const raw_len = width * height * 4;
const prefix = "\x1b_Ga=t,f=32,o=z,s=1920,v=1080,t=d,i=7,q=2,C=1;";
const suffix = "\x1b\\";

terminal: vt.Terminal,
stream: vt.TerminalStream,
gpa: std.mem.Allocator,
command: []u8,

pub fn init(io: std.Io, gpa: std.mem.Allocator) !KgpIngestContext {
    const raw = try gpa.alloc(u8, raw_len);
    defer gpa.free(raw);
    for (raw, 0..) |*byte, index| byte.* = @truncate(index % 251);

    const compressed_buffer = try gpa.alloc(u8, raw_len + 1024);
    defer gpa.free(compressed_buffer);
    var output: std.Io.Writer = .fixed(compressed_buffer);
    var compression_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(
        &output,
        &compression_buffer,
        .zlib,
        .fastest,
    );
    try compressor.writer.writeAll(raw);
    try compressor.finish();
    const compressed = output.buffered();

    const encoded_len = std.base64.standard.Encoder.calcSize(compressed.len);
    const command = try gpa.alloc(u8, prefix.len + encoded_len + suffix.len);
    errdefer gpa.free(command);
    @memcpy(command[0..prefix.len], prefix);
    _ = std.base64.standard.Encoder.encode(
        command[prefix.len..][0..encoded_len],
        compressed,
    );
    @memcpy(command[prefix.len + encoded_len ..], suffix);

    var terminal = try vt.Terminal.init(io, gpa, .{
        .cols = main.cols,
        .rows = main.rows,
        .kitty_image_storage_limit = max_image_bytes_per_screen_module,
        .kitty_image_loading_limits = .direct,
    });
    errdefer terminal.deinit(gpa);
    const stream = vt.TerminalStream.init(.{
        .allocator = gpa,
        .handler = terminal.vtHandler(),
    });
    return .{ .terminal = terminal, .stream = stream, .gpa = gpa, .command = command };
}

pub fn deinit(context: *KgpIngestContext) void {
    context.stream.deinit();
    context.terminal.deinit(context.gpa);
    context.gpa.free(context.command);
}
