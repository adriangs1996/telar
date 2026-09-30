//! One bound telar enforces, named once beside the constant that sets it.
//! The name is the constant's stable identifier (`bars.max_bar_actions`),
//! the noun says what it counts and the value is the bound itself.
const std = @import("std");
const Limit = @This();

/// Bytes of the longest limit name a report may carry.
pub const max_name_bytes = 64;
/// Bytes of the longest noun a report may carry.
pub const max_noun_bytes = 32;

name: []const u8,
noun: []const u8 = "",
value: u64,

/// Checks what a report from another process carries: a name of letters,
/// digits, `.`, `_` and `-`, and a noun of printable ASCII.
///
/// ```zig
/// try limit.validate();
/// ```
pub fn validate(self: Limit) !void {
    if (self.name.len == 0 or self.name.len > max_name_bytes) {
        return error.InvalidLimitName;
    }

    for (self.name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-') {
            return error.InvalidLimitName;
        }
    }

    if (self.noun.len > max_noun_bytes) {
        return error.InvalidLimitNoun;
    }

    for (self.noun) |byte| {
        if (byte < 0x20 or byte >= 0x7f) {
            return error.InvalidLimitNoun;
        }
    }
}

test "limit names are identifiers and nouns are printable" {
    try (Limit{ .name = "bars.max_bar_actions", .noun = "click actions", .value = 4 }).validate();
    try std.testing.expectError(error.InvalidLimitName, (Limit{ .name = "", .value = 1 }).validate());
    try std.testing.expectError(error.InvalidLimitName, (Limit{ .name = "bars max", .value = 1 }).validate());
    try std.testing.expectError(error.InvalidLimitNoun, (Limit{ .name = "a", .noun = "\x1b[31m", .value = 1 }).validate());
}
