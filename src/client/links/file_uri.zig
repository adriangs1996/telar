//! Converts a local file URI into an owned path suitable for an argv entry.

const std = @import("std");
const TargetType = @import("LinkTarget.zig");
const FilePath = @import("FilePath.zig");

pub fn validateEscapes(text: []const u8) !void {
    var index: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, index, '%')) |percent| {
        if (text.len - percent < 3 or !std.ascii.isHex(text[percent + 1]) or !std.ascii.isHex(text[percent + 2])) {
            return error.InvalidFileLink;
        }

        index = percent + 3;
    }
}

test "file paths decode local URIs and reject remote authority" {
    const target = try TargetType.init("file://localhost/tmp/a%20b.txt");
    const path = try FilePath.init(&target);

    try std.testing.expectEqualStrings("/tmp/a b.txt", path.slice());

    const remote = try TargetType.init("file://server/tmp/a.txt");
    try std.testing.expectError(error.RemoteFileLink, FilePath.init(&remote));
}

test "file paths reject query fragments malformed escapes and null bytes" {
    const query = try TargetType.init("file:///tmp/a?line=2");
    const malformed = try TargetType.init("file:///tmp/a%xx");
    const null_byte = try TargetType.init("file:///tmp/a%00b");

    try std.testing.expectError(error.InvalidFileLink, FilePath.init(&query));
    try std.testing.expectError(error.InvalidFileLink, FilePath.init(&malformed));
    try std.testing.expectError(error.InvalidFileLink, FilePath.init(&null_byte));
}
