const bytecodec = @import("bytecodec");
const std = @import("std");
const FindPaths = @import("FindPaths.zig");
const PathResults = @import("PathResults.zig");
const PathResultsView = @import("PathResultsView.zig");
const PathMatch = @import("../PathMatch.zig");
const Encoder = bytecodec.Encoder;
const Decoder = bytecodec.Decoder;
const codec = @import("../codec.zig");
const tags = @import("tags.zig");
const types = @import("../types.zig");
const id = @import("../id.zig");

pub fn encodeFindPaths(buffer: []u8, message: FindPaths) ![]const u8 {
    try message.validateWire();

    var encoder = Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ClientTag.find_paths));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeSized16(message.root);
    try encoder.writeSized16(message.query);
    try encoder.writeByte(@intFromEnum(message.kind));
    try encoder.writeInt(u16, message.limit);
    try encoder.writeByte(@intFromBool(message.refresh));
    return encoder.finish();
}

pub fn decodeFindPaths(decoder: *Decoder) !FindPaths {
    const message: FindPaths = .{
        .request_id = try id.request(try decoder.readInt(u64)),
        .root = try decoder.readSized16(),
        .query = try decoder.readSized16(),
        .kind = std.enums.fromInt(types.PathKindFilter, try decoder.readByte()) orelse return error.InvalidPathKind,
        .limit = try decoder.readInt(u16),
        .refresh = try decoder.readBool(),
    };
    try message.validateWire();
    return message;
}

pub fn encodePathResults(buffer: []u8, message: PathResults) ![]const u8 {
    try codec.validateRequestId(message.request_id);
    try validateRoot(message.root);
    if (message.matches.len > types.max_path_results) {
        return error.TooManyPathResults;
    }

    var encoder = Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.path_results));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeSized16(message.root);
    try encoder.writeInt(u32, message.scanned);
    try encoder.writeByte(@intFromBool(message.complete));
    try encoder.writeByte(@intFromBool(message.truncated));
    try encoder.writeInt(u16, @intCast(message.matches.len));
    for (message.matches) |match| {
        try validateMatch(match);
        try encoder.writeSized16(match.path);
        try encoder.writeByte(@intFromEnum(match.kind));
        try encoder.writeByte(@intCast(match.positions.len));
        for (match.positions) |position| {
            try encoder.writeInt(u16, position);
        }
    }

    return encoder.finish();
}

pub fn decodePathResults(decoder: *Decoder) !PathResultsView {
    const request_id = try id.request(try decoder.readInt(u64));
    const root = try decoder.readSized16();
    try validateRoot(root);

    const scanned = try decoder.readInt(u32);
    const complete = try decoder.readBool();
    const truncated = try decoder.readBool();
    const match_count = try decoder.readInt(u16);
    if (match_count > types.max_path_results) {
        return error.TooManyPathResults;
    }

    const start = decoder.index;
    var storage: [types.max_path_query_bytes]u16 = undefined;
    for (0..match_count) |_| {
        _ = try decodePathMatch(decoder, &storage);
    }

    return .{
        .request_id = request_id,
        .root = root,
        .scanned = scanned,
        .complete = complete,
        .truncated = truncated,
        .match_count = match_count,
        .encoded_matches = decoder.consumed(start),
    };
}

/// Reads and validates one match; its positions land in `storage`.
/// Example: `const match = try decodePathMatch(&decoder, &storage);`
pub fn decodePathMatch(decoder: *Decoder, storage: *[types.max_path_query_bytes]u16) !PathMatch {
    const path = try decoder.readSized16();
    const kind = std.enums.fromInt(types.PathKind, try decoder.readByte()) orelse return error.InvalidPathKind;
    const count = try decoder.readByte();
    if (count > storage.len) {
        return error.InvalidPathMatch;
    }

    for (storage[0..count]) |*position| {
        position.* = try decoder.readInt(u16);
    }

    const match: PathMatch = .{
        .path = path,
        .kind = kind,
        .positions = storage[0..count],
    };
    try validateMatch(match);
    return match;
}

fn validateRoot(root: []const u8) !void {
    try codec.validateBytes(
        root,
        types.max_cwd_bytes,
        false,
    );
    if (root[0] != '/' or std.mem.indexOfScalar(
        u8,
        root,
        0,
    ) != null) {
        return error.InvalidPathRoot;
    }
}

/// A match is printable UTF-8 a pane can receive as a paste: no control
/// bytes, a directory ends in `/`, and positions rise inside the path.
fn validateMatch(match: PathMatch) !void {
    try codec.validateBytes(
        match.path,
        types.max_path_match_bytes,
        false,
    );
    if (!std.unicode.utf8ValidateSlice(match.path)) {
        return error.InvalidUtf8;
    }

    for (match.path) |byte| {
        if (std.ascii.isControl(byte)) {
            return error.InvalidPathMatch;
        }
    }

    if ((match.kind == .directory) != (match.path[match.path.len - 1] == '/')) {
        return error.InvalidPathMatch;
    }

    if (match.positions.len > types.max_path_query_bytes) {
        return error.InvalidPathMatch;
    }

    var next: usize = 0;
    for (match.positions) |position| {
        if (position < next or position >= match.path.len) {
            return error.InvalidPathMatch;
        }

        next = @as(usize, position) + 1;
    }
}
