//! Bounded content decoding for completed captures.

const std = @import("std");

const c = @cImport({
    @cInclude("brotli/decode.h");
});

pub const Options = struct {
    input: []const u8,
    encoding: []const u8,
    max_bytes: usize,
};

pub const Result = struct {
    bytes: []u8,
    decoded: bool,
    truncated: bool,
    failed: bool = false,

    /// Erases and releases decoded output owned by this result.
    ///
    /// ```zig
    /// defer result.deinit(gpa);
    /// ```
    pub fn deinit(result: *Result, gpa: std.mem.Allocator) void {
        std.crypto.secureZero(u8, result.bytes);
        gpa.free(result.bytes);
        result.* = .{ .bytes = &.{}, .decoded = false, .truncated = false };
    }
};

/// Applies at most two content codings in reverse order under one output cap.
///
/// ```zig
/// var result = try decode(gpa, options);
/// defer result.deinit(gpa);
/// ```
pub fn decode(gpa: std.mem.Allocator, options: Options) !Result {
    if (options.max_bytes == 0) {
        return error.InvalidDecodeLimit;
    }

    var codings: [2][]const u8 = undefined;
    var coding_count: usize = 0;
    var tokens = std.mem.splitScalar(u8, options.encoding, ',');
    while (tokens.next()) |token| {
        const coding = std.mem.trim(u8, token, " \t");
        if (coding.len == 0 or coding_count == codings.len) {
            return fallback(gpa, options, true);
        }

        codings[coding_count] = coding;
        coding_count += 1;
    }

    if (coding_count == 0 or
        (coding_count == 1 and std.ascii.eqlIgnoreCase(codings[0], "identity")))
    {
        var result = try raw(gpa, options.input, options.max_bytes);
        result.decoded = true;
        return result;
    }

    var current = options.input;
    var owned: ?Result = null;
    var index = coding_count;
    while (index != 0) {
        index -= 1;
        if (std.ascii.eqlIgnoreCase(codings[index], "identity")) {
            continue;
        }

        const next = decodeOne(gpa, .{
            .input = current,
            .coding = codings[index],
            .max_bytes = options.max_bytes,
        }) catch |err| {
            if (owned) |*result| {
                result.deinit(gpa);
            }

            return fallback(gpa, options, err != error.UnknownEncoding);
        };
        if (owned) |*result| {
            result.deinit(gpa);
        }

        current = next.bytes;
        owned = next;
        if (next.truncated and index != 0) {
            if (owned) |*result| {
                result.deinit(gpa);
            }

            return fallback(gpa, options, true);
        }
    }

    return owned orelse fallback(gpa, options, false);
}

/// Copies a bounded raw prefix when no supported decoding can be applied.
///
/// ```zig
/// var result = try raw(gpa, input, max_bytes);
/// defer result.deinit(gpa);
/// ```
pub fn raw(gpa: std.mem.Allocator, input: []const u8, max_bytes: usize) !Result {
    const accepted = @min(input.len, max_bytes);
    return .{
        .bytes = try gpa.dupe(u8, input[0..accepted]),
        .decoded = false,
        .truncated = accepted != input.len,
    };
}

const DecodeInput = struct {
    input: []const u8,
    coding: []const u8,
    max_bytes: usize,
};

fn decodeOne(gpa: std.mem.Allocator, input: DecodeInput) !Result {
    if (std.ascii.eqlIgnoreCase(input.coding, "gzip")) {
        return decodeFlate(gpa, input, .gzip);
    }

    if (std.ascii.eqlIgnoreCase(input.coding, "deflate")) {
        return decodeFlate(gpa, input, .zlib);
    }

    if (std.ascii.eqlIgnoreCase(input.coding, "zstd")) {
        var source: std.Io.Reader = .fixed(input.input);
        var decoder: std.compress.zstd.Decompress = .init(&source, &.{}, .{});
        return collectZstd(gpa, &decoder.reader, input.max_bytes);
    }

    if (std.ascii.eqlIgnoreCase(input.coding, "br")) {
        return decodeBrotli(gpa, input);
    }

    return error.UnknownEncoding;
}

fn decodeFlate(gpa: std.mem.Allocator, input: DecodeInput, container: std.compress.flate.Container) !Result {
    var source: std.Io.Reader = .fixed(input.input);
    var decoder: std.compress.flate.Decompress = .init(&source, container, &.{});
    return collect(gpa, &decoder.reader, .{ .max_bytes = input.max_bytes });
}

fn decodeBrotli(gpa: std.mem.Allocator, input: DecodeInput) !Result {
    const capacity = try cappedCapacity(input.max_bytes);
    const temporary = try gpa.alloc(u8, capacity);
    defer {
        std.crypto.secureZero(u8, temporary);
        gpa.free(temporary);
    }
    const state = c.BrotliDecoderCreateInstance(null, null, null) orelse return error.BrotliOutOfMemory;
    defer c.BrotliDecoderDestroyInstance(state);
    var available_in = input.input.len;
    var next_in: [*c]const u8 = input.input.ptr;
    var available_out = capacity;
    var next_out: [*c]u8 = temporary.ptr;
    var total_out: usize = 0;
    const status = c.BrotliDecoderDecompressStream(
        state,
        &available_in,
        &next_in,
        &available_out,
        &next_out,
        &total_out,
    );
    const truncated = status == c.BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT and available_out == 0;
    if (status != c.BROTLI_DECODER_RESULT_SUCCESS and !truncated) {
        return error.InvalidBrotli;
    }

    const output_len = capacity - available_out;
    const result_len = @min(output_len, input.max_bytes);
    return .{
        .bytes = try gpa.dupe(u8, temporary[0..result_len]),
        .decoded = true,
        .truncated = truncated or output_len > input.max_bytes,
    };
}

const CollectOptions = struct {
    max_bytes: usize,
};

fn collect(gpa: std.mem.Allocator, reader: *std.Io.Reader, options: CollectOptions) !Result {
    const logical_capacity = try cappedCapacity(options.max_bytes);
    const temporary = try gpa.alloc(u8, logical_capacity);
    defer {
        std.crypto.secureZero(u8, temporary);
        gpa.free(temporary);
    }
    var writer: std.Io.Writer = .fixed(temporary);
    var total: usize = 0;

    while (total < logical_capacity) {
        const written = reader.stream(&writer, .limited(logical_capacity - total)) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (written == 0) {
            return error.InvalidCompressedStream;
        }

        total = writer.end;
    }

    const result_len = @min(total, options.max_bytes);
    return .{
        .bytes = try gpa.dupe(u8, temporary[0..result_len]),
        .decoded = true,
        .truncated = total > options.max_bytes,
    };
}

fn collectZstd(gpa: std.mem.Allocator, reader: *std.Io.Reader, max_bytes: usize) !Result {
    const logical_capacity = try cappedCapacity(max_bytes);
    const capacity = @max(logical_capacity, std.compress.zstd.block_size_max);
    const temporary = try gpa.alloc(u8, capacity);
    defer {
        std.crypto.secureZero(u8, temporary);
        gpa.free(temporary);
    }
    var writer: std.Io.Writer = .fixed(temporary);
    var overflow = false;
    _ = reader.streamRemaining(&writer) catch |err| switch (err) {
        error.WriteFailed => overflow = true,
        else => return err,
    };

    const result_len = @min(writer.end, max_bytes);
    return .{
        .bytes = try gpa.dupe(u8, temporary[0..result_len]),
        .decoded = true,
        .truncated = overflow or writer.end > max_bytes,
    };
}

fn cappedCapacity(max_bytes: usize) !usize {
    return std.math.add(usize, max_bytes, 1) catch error.InvalidDecodeLimit;
}

fn fallback(gpa: std.mem.Allocator, options: Options, failed: bool) !Result {
    var result = try raw(gpa, options.input, options.max_bytes);
    result.failed = failed;
    return result;
}

const gzip_body = &[_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0xb6, 0x3e, 0x99, 0x6a, 0x00, 0x03,
    0x4b, 0x4e, 0x2c, 0x28, 0x29, 0x2d, 0x4a, 0x4d, 0x51, 0x48,
    0xca, 0x4f, 0xa9, 0x04, 0x00, 0xb7, 0x62, 0xbd, 0x2b, 0x0d,
    0x00, 0x00, 0x00,
};

const brotli_body = &[_]u8{
    0x1f, 0x0c, 0x00, 0xf8, 0xa5, 0x40, 0xc8, 0xaa,
    0x10, 0x49, 0x8a, 0x05, 0x4d, 0x7c, 0x00,
};

const zstd_body = &[_]u8{
    0x28, 0xb5, 0x2f, 0xfd, 0x04, 0x58, 0x69, 0x00,
    0x00, 0x63, 0x61, 0x70, 0x74, 0x75, 0x72, 0x65,
    0x64, 0x20, 0x62, 0x6f, 0x64, 0x79, 0xc7, 0xac,
    0xaf, 0xcb,
};

test "gzip brotli and zstd decode within a shared output cap" {
    const cases = .{
        .{ "gzip", gzip_body },
        .{ "br", brotli_body },
        .{ "zstd", zstd_body },
    };

    inline for (cases) |case| {
        var complete = try decode(std.testing.allocator, .{
            .input = case[1],
            .encoding = case[0],
            .max_bytes = 64,
        });
        defer complete.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("captured body", complete.bytes);
        try std.testing.expect(complete.decoded);
        try std.testing.expect(!complete.truncated);

        var capped = try decode(std.testing.allocator, .{
            .input = case[1],
            .encoding = case[0],
            .max_bytes = 4,
        });
        defer capped.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("capt", capped.bytes);
        try std.testing.expect(capped.decoded);
        try std.testing.expect(capped.truncated);
    }
}

test "unknown and malformed encodings preserve bounded wire bytes" {
    var unknown = try decode(std.testing.allocator, .{
        .input = "wire bytes",
        .encoding = "future",
        .max_bytes = 4,
    });
    defer unknown.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("wire", unknown.bytes);
    try std.testing.expect(!unknown.decoded);
    try std.testing.expect(!unknown.failed);
    try std.testing.expect(unknown.truncated);

    var malformed = try decode(std.testing.allocator, .{
        .input = "not gzip",
        .encoding = "gzip",
        .max_bytes = 32,
    });
    defer malformed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("not gzip", malformed.bytes);
    try std.testing.expect(!malformed.decoded);
    try std.testing.expect(malformed.failed);
}
