const std = @import("std");
const Char = @import("Char.zig");
const GenericBinding = @import("GenericBinding.zig").Type;
const GenericTable = @import("GenericTable.zig").Type;
const Key = @import("Key.zig");
const chord = @import("chord.zig");
const keybind = @import("keybind.zig");

const TestAction = enum { first, second };
const Binding = GenericBinding(TestAction, 4);
const lease_capacity = 2;

test "chords parse modifiers in any case and normalize terminal forms" {
    const prefix = try chord.parseKey("ctrl+b");
    try std.testing.expect(prefix.isCtrl('b'));

    const shouted = try chord.parseKey("Control+B");
    try std.testing.expectEqual(std.math.Order.eq, keybind.keyOrder(prefix, shouted));

    const back_tab = try chord.parseKey("shift+tab");
    try std.testing.expectEqual(Key.Code.back_tab, back_tab.code);
    try std.testing.expect(!back_tab.mods.shift);
}

test "malformed chords are rejected" {
    try std.testing.expectError(error.EmptyKey, chord.parseKey(""));
    try std.testing.expectError(error.EmptyKeyPart, chord.parseKey("ctrl++"));
    try std.testing.expectError(error.DuplicateModifier, chord.parseKey("alt+alt+x"));
    try std.testing.expectError(error.ModifierAfterKey, chord.parseKey("x+ctrl"));
    try std.testing.expectError(error.MissingKey, chord.parseKey("ctrl"));
}

test "keys order by modifiers before codes and by text within characters" {
    const a = Key.plain(.{ .char = Char.init("a") });
    const b = Key.plain(.{ .char = Char.init("b") });
    const ctrl_a = try chord.parseKey("ctrl+a");

    try std.testing.expectEqual(std.math.Order.lt, keybind.keyOrder(a, b));
    try std.testing.expectEqual(std.math.Order.lt, keybind.keyOrder(b, ctrl_a));
    try std.testing.expectEqual(std.math.Order.lt, keybind.sequenceOrder(&.{a}, &.{ a, b }));
    try std.testing.expectEqual(@as(usize, 1), keybind.commonPrefix(&.{ a, b }, &.{ a, a }));
    try std.testing.expect(keybind.isPlainEscape(.plain(.escape)));
    try std.testing.expect(!keybind.isPlainEscape(try chord.parseKey("alt+escape")));
}

test "bindings conflict when one sequence prefixes the other" {
    const prefix = try Binding.parse(&.{"ctrl+b"}, .first);
    const split = try Binding.parse(&.{ "ctrl+b", "%" }, .second);
    const other = try Binding.parse(&.{ "ctrl+a", "%" }, .second);

    try std.testing.expect(prefix.conflictsWith(&split));
    try std.testing.expect(!split.conflictsWith(&other));
    try std.testing.expect(split.sameSequence(&split));
    try std.testing.expectError(error.EmptySequence, Binding.parse(&.{}, .first));
    try std.testing.expectError(error.SequenceTooLong, Binding.parse(&.{ "a", "b", "c", "d", "e" }, .first));
}

test "semantic key owns its scalar after the input buffer changes" {
    var bytes = [_]u8{ 0xc3, 0xb1 };
    const key = Key.plain(.{ .char = Char.init(&bytes) });
    @memset(&bytes, 0);

    try std.testing.expectEqualStrings("ñ", key.code.char.slice());
}

test "physical leases replace stale owners and count overflow" {
    var leases: GenericTable(TestAction, lease_capacity) = .{};

    try std.testing.expect(leases.acquire(.{ .value = 1 }, .first));
    try std.testing.expect(leases.acquire(.{ .value = 1 }, .second));
    try std.testing.expectEqual(@as(?TestAction, .second), leases.owner(.{ .value = 1 }));

    try std.testing.expect(leases.acquire(.{ .value = 2 }, .first));
    try std.testing.expect(!leases.acquire(.{ .value = 3 }, .first));
    try std.testing.expectEqual(@as(u64, 1), leases.overflowCount());

    try std.testing.expectEqual(@as(?TestAction, .second), leases.release(.{ .value = 1 }));
    try std.testing.expectEqual(@as(usize, 1), leases.count());
    try std.testing.expect(leases.release(.{ .value = 1 }) == null);
}
