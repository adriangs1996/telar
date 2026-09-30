//! Seeds for the HTTP/1 fuzz targets, written as the typed values a target
//! draws and encoded at compile time in `std.testing.Smith`'s input form.
//!
//! Only the fuzz roots import this file; no suite and no library root does.
//! The encoding follows Zig 0.16.0's `Smith.value`: an integer, bool or enum
//! is a little-endian u64, a `[N]u8` is its raw bytes, an array of anything
//! else and a struct are their elements in order, and a tagged union is its
//! tag followed by its payload. `slice` is `Smith.slice`'s u32 length and
//! bytes. A crash the fuzzer saves has the same form, so it can join a
//! corpus as it is.

const std = @import("std");

/// Bytes `Smith.value(T)` reads back as `shape`.
///
/// ```zig
/// const seed = fuzz_corpus.value(HeadShape, .{ .kind = .request, ... });
/// ```
pub fn value(comptime T: type, comptime shape: T) []const u8 {
    comptime {
        @setEvalBranchQuota(1_000_000);
        const encoded = valueBytes(T, shape)[0..].*;
        return &encoded;
    }
}

/// Bytes `Smith.slice` reads back as `bytes`.
///
/// ```zig
/// const seed = fuzz_corpus.value(BodyShape, shape) ++ fuzz_corpus.slice("payload");
/// ```
pub fn slice(comptime bytes: []const u8) []const u8 {
    comptime {
        var length: [@sizeOf(u32)]u8 = undefined;
        std.mem.writeInt(u32, &length, bytes.len, .little);
        const encoded = length ++ bytes[0..bytes.len].*;
        return &encoded;
    }
}

fn valueBytes(comptime T: type, comptime shape: T) []const u8 {
    return switch (@typeInfo(T)) {
        .void => "",
        .bool => int(@intFromBool(shape)),
        .int => |info| int(@as(@Int(.unsigned, info.bits), @bitCast(shape))),
        .@"enum" => int(@intFromEnum(shape)),
        .array => |array| if (array.child == u8) &shape else elements: {
            var encoded: []const u8 = "";
            for (shape) |element| {
                encoded = encoded ++ valueBytes(array.child, element);
            }

            break :elements encoded;
        },
        .@"struct" => |layout| fields: {
            var encoded: []const u8 = "";
            for (layout.fields) |field| {
                encoded = encoded ++ valueBytes(field.type, @field(shape, field.name));
            }

            break :fields encoded;
        },
        .@"union" => switch (shape) {
            inline else => |payload, tag| int(@intFromEnum(tag)) ++ valueBytes(@TypeOf(payload), payload),
        },
        else => @compileError("Smith does not draw " ++ @typeName(T)),
    };
}

fn int(comptime number: u64) []const u8 {
    var encoded: [@sizeOf(u64)]u8 = undefined;
    std.mem.writeInt(u64, &encoded, number, .little);
    const constant = encoded;
    return &constant;
}
