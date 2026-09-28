//! How `telar --machine LABEL …` carries argv to another machine. OpenSSH
//! joins the remote command into one string for the remote login shell,
//! which may be sh, zsh or fish, each with its own quoting. Each argument
//! therefore travels as `a` followed by its unpadded base64url form: only
//! letters, digits, `-` and `_`, which no shell treats as syntax, and never
//! empty. `telar dispatch-argv` decodes them back on the other side.
const std = @import("std");

/// Marks an encoded argument, so an empty one still has a word.
const marker = 'a';
const codec = std.base64.url_safe_no_pad;

/// Bytes `encode` writes for an argument of `len` bytes.
pub fn encodedLength(len: usize) usize {
    return 1 + codec.Encoder.calcSize(len);
}

/// Writes the encoded form of `argument` into `buffer`.
///
/// ```zig
/// const word = dispatch_argv.encode("pane list", &buffer);
/// ```
pub fn encode(argument: []const u8, buffer: []u8) ![]const u8 {
    const len = encodedLength(argument.len);
    if (buffer.len < len) {
        return error.NoSpaceLeft;
    }

    buffer[0] = marker;
    _ = codec.Encoder.encode(buffer[1..len], argument);
    return buffer[0..len];
}

/// Decodes one word written by `encode` into a NUL-terminated argument the
/// caller owns.
///
/// ```zig
/// const argument = try dispatch_argv.decode(gpa, word);
/// defer gpa.free(argument);
/// ```
pub fn decode(gpa: std.mem.Allocator, word: []const u8) ![:0]u8 {
    if (word.len == 0 or word[0] != marker) {
        return error.InvalidDispatchArgument;
    }

    const len = codec.Decoder.calcSizeForSlice(word[1..]) catch return error.InvalidDispatchArgument;
    const argument = try gpa.allocSentinel(u8, len, 0);
    errdefer gpa.free(argument);

    codec.Decoder.decode(argument, word[1..]) catch return error.InvalidDispatchArgument;
    if (std.mem.indexOfScalar(u8, argument, 0) != null) {
        return error.InvalidDispatchArgument;
    }

    return argument;
}

test "arguments survive the trip whatever they contain" {
    const cases = [_][]const u8{ "", "pane", "it's a \"quote\"", "$(rm -rf ~)", "ünïcode", "a b\tc" };
    for (cases) |argument| {
        var buffer: [128]u8 = undefined;
        const word = try encode(argument, &buffer);

        for (word) |byte| {
            try std.testing.expect(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_');
        }

        const decoded = try decode(std.testing.allocator, word);
        defer std.testing.allocator.free(decoded);
        try std.testing.expectEqualStrings(argument, decoded);
    }
}

test "words not written by encode are refused" {
    for ([_][]const u8{ "", "b", "a!", "a" ++ "AA" }) |word| {
        const result = decode(std.testing.allocator, word);
        if (result) |argument| {
            std.testing.allocator.free(argument);
            return error.TestUnexpectedResult;
        } else |err| {
            try std.testing.expectEqual(error.InvalidDispatchArgument, err);
        }
    }
}
