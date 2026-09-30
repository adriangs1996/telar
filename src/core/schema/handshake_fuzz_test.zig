//! Native fuzzing of `decodeClientHello`, the only fuzz target so far.
//!
//! This root imports the handshake as a module and runs only through
//! `zig build test-handshake`. The ordinary suites, and the coverage build
//! that compiles them with `-ffuzz`, never reach a `std.testing.fuzz` call:
//! Zig 0.16.0's test runner does not compile one in Debug with error return
//! traces, and segfaults on one in an instrumented binary run without
//! `--fuzz`.

const std = @import("std");
const handshake = @import("handshake");

/// Magic followed by the one-byte message tag.
const header_size = handshake.magic.len + @sizeOf(handshake.Tag);

/// Room for a whole ClientHello followed by any other handshake message, so
/// the fuzzer reaches lengths on both sides of the exact one.
const payload_capacity = handshake.client_hello_size + handshake.max_message_size;

/// A payload the fuzzer starts from and what `decodeClientHello` answers for
/// it; a null outcome is an accepted hello.
const ClientHelloSeed = struct {
    payload: []const u8,
    outcome: ?handshake.DecodeError,
};

const valid_client_hello = encodedClientHello(handshake.schema_id);

const client_hello_seeds = [_]ClientHelloSeed{
    .{
        .payload = &valid_client_hello,
        .outcome = null,
    },
    .{
        .payload = &encodedClientHello(@splat('0')),
        .outcome = null,
    },
    .{
        .payload = "",
        .outcome = error.InvalidLength,
    },
    .{
        .payload = valid_client_hello[0 .. header_size - 1],
        .outcome = error.InvalidLength,
    },
    .{
        .payload = valid_client_hello[0 .. handshake.client_hello_size - 1],
        .outcome = error.InvalidLength,
    },
    .{
        .payload = &(valid_client_hello ++ handshake.magic),
        .outcome = error.InvalidLength,
    },
    .{
        .payload = &withByte(valid_client_hello, 0, handshake.magic[0] ^ 1),
        .outcome = error.InvalidMagic,
    },
    .{
        .payload = &withByte(valid_client_hello, handshake.magic.len, @intFromEnum(handshake.Tag.server_reject) + 1),
        .outcome = error.UnknownMessage,
    },
    .{
        .payload = &withByte(valid_client_hello, handshake.magic.len, std.math.maxInt(u8)),
        .outcome = error.UnknownMessage,
    },
    .{
        .payload = &withByte(valid_client_hello, handshake.magic.len, @intFromEnum(handshake.Tag.server_accept)),
        .outcome = error.UnexpectedMessage,
    },
    .{
        .payload = &encodedServerReject(),
        .outcome = error.UnexpectedMessage,
    },
};

/// The seeds in `std.testing.Smith` input form: one `slice` call reads a
/// little-endian u32 length and then that many bytes. A crash the fuzzer
/// saves has the same form, so it can join this corpus as it is.
const client_hello_corpus = corpus: {
    var entries: [client_hello_seeds.len][]const u8 = undefined;
    for (client_hello_seeds, &entries) |seed, *entry| {
        entry.* = smithSlice(seed.payload);
    }

    break :corpus entries;
};

fn encodedClientHello(schema: handshake.SchemaId) [handshake.client_hello_size]u8 {
    var buffer: [handshake.client_hello_size]u8 = undefined;
    _ = handshake.encodeClientHello(&buffer, .{ .schema = schema }) catch unreachable;
    return buffer;
}

fn encodedServerReject() [handshake.server_reject_size]u8 {
    var buffer: [handshake.server_reject_size]u8 = undefined;
    _ = handshake.encodeServerResponse(
        &buffer,
        handshake.negotiate(@splat('0'), handshake.schema_id),
    ) catch unreachable;
    return buffer;
}

fn withByte(bytes: [handshake.client_hello_size]u8, index: usize, byte: u8) [handshake.client_hello_size]u8 {
    var changed = bytes;
    changed[index] = byte;
    return changed;
}

fn smithSlice(comptime payload: []const u8) []const u8 {
    comptime {
        var length: [@sizeOf(u32)]u8 = undefined;
        std.mem.writeInt(u32, &length, payload.len, .little);
        const entry = length ++ payload[0..payload.len].*;
        return &entry;
    }
}

/// The error `decodeClientHello` owes `payload`, in the order it validates:
/// header length, magic, known tag, ClientHello tag, then exact length.
fn expectedClientHelloError(payload: []const u8) ?handshake.DecodeError {
    if (payload.len < header_size) {
        return error.InvalidLength;
    }

    if (!std.mem.eql(u8, payload[0..handshake.magic.len], &handshake.magic)) {
        return error.InvalidMagic;
    }

    const tag = std.enums.fromInt(handshake.Tag, payload[handshake.magic.len]) orelse return error.UnknownMessage;
    if (tag != .client_hello) {
        return error.UnexpectedMessage;
    }

    if (payload.len != handshake.client_hello_size) {
        return error.InvalidLength;
    }

    return null;
}

/// A broken property panics instead of returning its error: Zig 0.16.0's
/// fuzzer saves the failing input on an abort, but leaves it empty when the
/// test returns an error and the runner exits.
fn decodeFuzzedClientHello(_: void, smith: *std.testing.Smith) anyerror!void {
    expectClientHelloDecoding(smith) catch |err| std.debug.panic("ClientHello property failed: {t}", .{err});
}

/// Decodes one fuzzed payload of at most `payload_capacity` bytes. A
/// rejection must be the error its bytes call for; an accepted hello must
/// re-encode to exactly the payload, which pins its length, magic, tag and
/// schema.
fn expectClientHelloDecoding(smith: *std.testing.Smith) anyerror!void {
    var buffer: [payload_capacity]u8 = undefined;
    const payload = buffer[0..smith.slice(&buffer)];

    const hello = handshake.decodeClientHello(payload) catch |err| {
        const rejection: ?handshake.DecodeError = err;
        return std.testing.expectEqual(expectedClientHelloError(payload), rejection);
    };

    try std.testing.expectEqual(null, expectedClientHelloError(payload));

    var encoded: [handshake.client_hello_size]u8 = undefined;
    try std.testing.expectEqualSlices(u8, payload, try handshake.encodeClientHello(&encoded, hello));
}

test "every client hello fuzz seed reaches its decoder outcome" {
    for (client_hello_seeds, client_hello_corpus) |seed, entry| {
        const outcome: ?handshake.DecodeError = if (handshake.decodeClientHello(seed.payload)) |_| null else |err| err;
        try std.testing.expectEqual(seed.outcome, outcome);
        try std.testing.expectEqual(seed.outcome, expectedClientHelloError(seed.payload));

        var smith: std.testing.Smith = .{ .in = entry };
        var buffer: [payload_capacity]u8 = undefined;
        try std.testing.expectEqualSlices(u8, seed.payload, buffer[0..smith.slice(&buffer)]);
    }
}

test "fuzz client hello decoding" {
    try std.testing.fuzz({}, decodeFuzzedClientHello, .{
        .corpus = &client_hello_corpus,
    });
}
