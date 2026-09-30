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

/// Declares a limit beside its constant; a name or noun a report could not
/// carry fails the build instead of every report at run time.
///
/// ```zig
/// pub const max_bar_actions = 4;
/// pub const bar_actions_limit = Limit.declare("bars.max_bar_actions", "click actions", max_bar_actions);
/// ```
pub fn declare(comptime name: []const u8, comptime noun: []const u8, value: u64) Limit {
    comptime {
        const declared: Limit = .{
            .name = name,
            .noun = noun,
            .value = 0,
        };
        declared.validate() catch |err| @compileError("limit '" ++ name ++ "': " ++ @errorName(err));
    }

    return .{
        .name = name,
        .noun = noun,
        .value = value,
    };
}

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
    try declare("bars.max_bar_actions", "click actions", 4).validate();

    const empty: Limit = .{
        .name = "",
        .value = 1,
    };
    try std.testing.expectError(error.InvalidLimitName, empty.validate());

    const spaced: Limit = .{
        .name = "bars max",
        .value = 1,
    };
    try std.testing.expectError(error.InvalidLimitName, spaced.validate());

    const escaped: Limit = .{
        .name = "a",
        .noun = "\x1b[31m",
        .value = 1,
    };
    try std.testing.expectError(error.InvalidLimitNoun, escaped.validate());
}
