const std = @import("std");
const id = @import("schema/id.zig");
const bytecodec = @import("bytecodec");
const CoordinatorReference = @This();

/// The runtime-generated pane session id already carried by agent snapshots.
/// Together with the exact pane generation it is independent of machine labels.
session_id: [16]u8,
pane_id: id.PaneId,
pane_generation: u64,

pub const max_text_bytes = 32 + 2 + 2 * 20;

/// Appends a validated identity without labels or connection authority.
/// Example: `try reference.encode(&encoder);`
pub fn encode(self: CoordinatorReference, encoder: *bytecodec.Encoder) !void {
    try self.validate();
    try encoder.writeBytes(&self.session_id);
    try encoder.writeInt(u64, id.raw(self.pane_id));
    try encoder.writeInt(u64, self.pane_generation);
}

/// Reads and validates a complete coordinator identity.
/// Example: `const reference = try CoordinatorReference.decode(&decoder);`
pub fn decode(decoder: *bytecodec.Decoder) !CoordinatorReference {
    const reference: CoordinatorReference = .{
        .session_id = (try decoder.readBytes(16))[0..16].*,
        .pane_id = @enumFromInt(try decoder.readInt(u64)),
        .pane_generation = try decoder.readInt(u64),
    };
    try reference.validate();
    return reference;
}

/// Rejects missing session identities and wildcard generations.
/// Example: `try coordinator.validate();`
pub fn validate(self: CoordinatorReference) !void {
    if (self.pane_id == .invalid or self.pane_generation == 0 or std.mem.allEqual(u8, &self.session_id, 0)) {
        return error.InvalidCoordinatorReference;
    }
}

/// Parses the bounded attribution passed between dispatching CLIs.
/// Example: `const reference = try CoordinatorReference.parse(text);`
pub fn parse(text: []const u8) !CoordinatorReference {
    if (text.len > max_text_bytes) {
        return error.InvalidCoordinatorReference;
    }

    var parts = std.mem.splitScalar(u8, text, ':');
    const session = parts.next() orelse return error.InvalidCoordinatorReference;
    if (session.len != 32) {
        return error.InvalidCoordinatorReference;
    }

    var reference: CoordinatorReference = .{
        // SAFETY: session has exactly 32 hex characters; hexToBytes fills all 16 bytes before validate or return, or returns an error.
        .session_id = undefined,
        .pane_id = @enumFromInt(std.fmt.parseUnsigned(u64, parts.next() orelse return error.InvalidCoordinatorReference, 10) catch return error.InvalidCoordinatorReference),
        .pane_generation = std.fmt.parseUnsigned(u64, parts.next() orelse return error.InvalidCoordinatorReference, 10) catch return error.InvalidCoordinatorReference,
    };
    _ = std.fmt.hexToBytes(&reference.session_id, session) catch return error.InvalidCoordinatorReference;
    if (parts.next() != null) {
        return error.InvalidCoordinatorReference;
    }

    try reference.validate();
    return reference;
}

/// Formats a reference for the internal `--coordinator` dispatch argument.
/// Example: `const text = try reference.format(&buffer);`
pub fn format(self: CoordinatorReference, buffer: []u8) ![]const u8 {
    try self.validate();
    const session = std.fmt.bytesToHex(self.session_id, .lower);
    return std.fmt.bufPrint(buffer, "{s}:{d}:{d}", .{ session, id.raw(self.pane_id), self.pane_generation });
}
