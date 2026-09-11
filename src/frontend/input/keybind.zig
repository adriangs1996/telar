//! Key sequences between host terminal input and application actions.
//!
//! Configuration is deliberately outside this file. The Lua loader parses
//! strings into `Key` values and hands the resulting bindings to `Router.init`.
//! The router then owns a sorted, bounded copy. Routing performs no allocation
//! and never has to retain slices owned by the configuration parser.

const std = @import("std");
const key_lease = @import("telar-client").input.key_lease;
const term = @import("../presentation/root.zig").screen;

pub const Key = @import("telar-client").input.Key;

pub const Control = @import("telar-client").input.keybind.Control;

pub const default_escape_timeout_ns = @import("telar-client").input.keybind.default_escape_timeout_ns;
pub const default_sequence_timeout_ns = @import("telar-client").input.keybind.default_sequence_timeout_ns;
pub const default_prefix = @import("telar-client").input.keybind.default_prefix;
pub const max_physical_leases = @import("telar-client").input.keybind.max_physical_leases;

pub const RepeatPolicy = @import("telar-client").input.keybind.RepeatPolicy;

/// Parses one key chord from configuration syntax.
///
/// Examples are `ctrl+b`, `ctrl+shift+left`, `escape`, `space`, and `ñ`.
/// Sequences stay arrays at this layer so configuration can parse a prefix and
/// its suffixes without another string grammar.
pub const parseKey = @import("telar-client").input.chord.parseKey;

pub const Binding = @import("telar-client").input.keybind.Binding;

pub const Keymap = @import("telar-client").input.keybind.Keymap;

pub const RouterLimits = @import("telar-client").input.keybind.RouterLimits;

pub const Router = @import("GenericRouter.zig").Type;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

pub const TestAction = enum { detach, palette, next };
const TestBinding = Binding(TestAction, 4);
const TestRouter = Router(TestAction, .{ .max_bindings = 16, .max_keys = 4, .input_capacity = 64, .held_capacity = 32 });

const Capture = @import("Capture.zig");

const GreedyCapture = @import("GreedyCapture.zig");

const SemanticCapture = @import("SemanticCapture.zig");

test "terminal decoding and direct semantic input produce identical routing" {
    const shared = @import("telar-client").input.keybind;
    const DirectRouter = shared.Router(TestAction, .{ .max_bindings = 16, .max_keys = 4, .input_capacity = 64, .held_capacity = 32 }, struct {});
    const bindings = [_]TestBinding{
        try TestBinding.parse(&.{"up"}, .next),
        try TestBinding.parse(&.{ "left", "right" }, .detach),
    };
    var terminal = try TestRouter.init(&bindings);
    var direct = try DirectRouter.init(&bindings);
    var decoded: SemanticCapture = .{};
    var semantic: SemanticCapture = .{};

    _ = try terminal.feed(.{ .bytes = "\x1b[", .now_ns = 0 }, &decoded);
    _ = try terminal.feed(.{ .bytes = "A\x1b[D\x1b[B", .now_ns = 1 }, &decoded);
    const events = [_]Key{
        .{ .code = .up, .physical = .{ .value = 0x110001 } },
        .{ .code = .left, .physical = .{ .value = 0x110003 } },
        .{ .code = .down, .physical = .{ .value = 0x110002 } },
    };
    for (events) |key_value| {
        _ = try direct.routeEvent(.{ .key = key_value, .raw = "", .now_ns = 1 }, &semantic);
    }

    try std.testing.expectEqual(@as(usize, 1), semantic.action_count);
    try std.testing.expectEqual(decoded.action_count, semantic.action_count);
    try std.testing.expectEqualDeep(decoded.keys[0..decoded.key_count], semantic.keys[0..semantic.key_count]);
}

const MouseCapture = @import("MouseCapture.zig");

const TerminalResponseCapture = @import("TerminalResponseCapture.zig");

test "configuration keys parse into semantic chords" {
    const ctrl_b = try parseKey("Ctrl+B");
    try testing.expect(ctrl_b.isCtrl('b'));

    const shifted = try parseKey("ctrl+shift+left");
    try testing.expect(shifted.mods.ctrl);
    try testing.expect(shifted.mods.shift);
    try testing.expect(shifted.code == .left);

    const back_tab = try parseKey("shift+tab");
    try testing.expect(back_tab.code == .back_tab);
    try testing.expect(!back_tab.mods.shift);

    const enye = try parseKey("ñ");
    try testing.expect(enye.code.char.eql("ñ"));

    const alt_x = try parseKey("alt+x");
    try testing.expect(alt_x.mods.alt);
    try testing.expect(alt_x.code.char.eql("x"));

    const shifted_char = try parseKey("shift+a");
    try testing.expect(!shifted_char.mods.shift);
    try testing.expect(shifted_char.code.char.eql("A"));
}

test "an active editor receives keys before configured bindings" {
    const bindings = [_]TestBinding{try .parse(&.{"a"}, .palette)};
    var router = try TestRouter.init(&bindings);
    var capture: GreedyCapture = .{};

    _ = try router.feed(.{ .bytes = "a", .now_ns = 0 }, &capture);

    try testing.expectEqual(@as(usize, 1), capture.key_count);
    try testing.expectEqual(@as(usize, 0), capture.action_count);
    try testing.expectEqualDeep(Key{ .code = .{ .char = .init("a") } }, capture.keys[0]);
}

test "configuration rejects malformed keys" {
    try testing.expectError(error.EmptyKey, parseKey(""));
    try testing.expectError(error.MissingKey, parseKey("ctrl"));
    try testing.expectError(error.DuplicateModifier, parseKey("ctrl+ctrl+a"));
    try testing.expectError(error.ModifierAfterKey, parseKey("a+ctrl"));
    try testing.expectError(error.KeyMustBeOneCodepoint, parseKey("ab"));
    try testing.expectError(error.UnrepresentableKey, parseKey("shift+1"));
    try testing.expectError(error.UnrepresentableKey, parseKey("ctrl+shift+a"));
}

test "keymap rejects duplicate and ambiguous sequences" {
    const ctrl_b = try parseKey("ctrl+b");
    const d = try parseKey("d");
    const duplicate = [_]TestBinding{
        try .init(&.{ctrl_b}, .detach),
        try .init(&.{ctrl_b}, .palette),
    };
    try testing.expectError(error.DuplicateBinding, TestRouter.init(&duplicate));

    const prefix = [_]TestBinding{
        try .init(&.{ctrl_b}, .detach),
        try .init(&.{ ctrl_b, d }, .palette),
    };
    try testing.expectError(error.AmbiguousBindingPrefix, TestRouter.init(&prefix));
}

test "keymap accepts sibling sequences with one shared prefix" {
    const siblings = [_]TestBinding{
        try .parse(&.{ "ctrl+b", "d" }, .detach),
        try .parse(&.{ "ctrl+b", "p" }, .palette),
    };
    var router = try TestRouter.init(&siblings);
    var capture: Capture = .{};
    _ = try router.feed(.{ .bytes = "\x02d\x02p", .now_ns = 0 }, &capture);
    try testing.expectEqualSlices(
        TestAction,
        &.{ .detach, .palette },
        capture.actions[0..capture.action_len],
    );
}

test "keymap action representation does not affect sequence identity" {
    const SmallAction = enum(u8) { detach, palette };
    const SmallBinding = Binding(SmallAction, 4);
    const SmallRouter = Router(SmallAction, .{ .max_bindings = 16, .max_keys = 4, .input_capacity = 64, .held_capacity = 32 });
    const siblings = [_]SmallBinding{
        try .parse(&.{ "ctrl+b", "d" }, .detach),
        try .parse(&.{ "ctrl+b", "p" }, .palette),
    };
    _ = try SmallRouter.init(&siblings);
}

test "unbound input is byte-for-byte transparent" {
    const bindings = [_]TestBinding{try .parse(&.{ "ctrl+b", "d" }, .detach)};
    var router = try TestRouter.init(&bindings);
    var capture: Capture = .{};

    const input = "hello ñ\x1b[A\x1b[999~";
    try testing.expectEqual(Control.continue_routing, try router.feed(.{ .bytes = input, .now_ns = 0 }, &capture));
    try testing.expectEqualStrings(input, capture.slice());
    try testing.expectEqual(@as(usize, 0), capture.action_len);
}

test "a configured sequence runs once and does not reach the pane" {
    const bindings = [_]TestBinding{try .parse(&.{ "ctrl+b", "d" }, .detach)};
    var router = try TestRouter.init(&bindings);
    var capture: Capture = .{};

    _ = try router.feed(.{ .bytes = "before\x02dafter", .now_ns = 100 }, &capture);
    try testing.expectEqualStrings("beforeafter", capture.slice());
    try testing.expectEqualSlices(TestAction, &.{.detach}, capture.actions[0..capture.action_len]);
}

test "CSI-u Ctrl bindings route without colliding with Backspace or Enter" {
    const bindings = [_]TestBinding{
        try .parse(&.{"ctrl+h"}, .detach),
        try .parse(&.{"ctrl+j"}, .palette),
        try .parse(&.{"ctrl+k"}, .next),
        try .parse(&.{"ctrl+l"}, .detach),
    };
    var router = try TestRouter.init(&bindings);
    var capture: Capture = .{};

    _ = try router.feed(.{ .bytes = "\x1b[104;5u\x1b[106;5u\x1b[107;5u\x1b[108;5u", .now_ns = 100 }, &capture);
    try testing.expectEqualSlices(
        TestAction,
        &.{ .detach, .palette, .next, .detach },
        capture.actions[0..capture.action_len],
    );
    try testing.expectEqual(@as(usize, 0), capture.len);
}

test "modified Enter reaches the semantic handler at every chunk boundary" {
    for ([_][]const u8{
        "\x1b[13;2u",
        "\x1b[13;2:1u",
        "\x1b[13::13;2:1u",
        "\x1b[27;2;13~",
    }) |sequence| {
        for (1..sequence.len) |split| {
            var router = try TestRouter.init(&.{});
            var capture: GreedyCapture = .{};
            _ = try router.feed(.{ .bytes = sequence[0..split], .now_ns = 0 }, &capture);
            try testing.expectEqual(@as(usize, 0), capture.key_count);
            _ = try router.feed(.{ .bytes = sequence[split..], .now_ns = 1 }, &capture);
            try testing.expectEqual(@as(usize, 1), capture.key_count);
            try testing.expectEqual(Key.Code.enter, capture.keys[0].code);
            try testing.expect(capture.keys[0].mods.shift);
            try testing.expectEqual(Key.Phase.press, capture.keys[0].phase);
            try testing.expectEqual(@as(usize, 0), capture.action_count);
        }
    }
}

test "an orphan Kitty release fails closed at every chunk boundary" {
    const sequence = "\x1b[13::13;2:3u";
    for (1..sequence.len) |split| {
        var router = try TestRouter.init(&.{});
        var capture: GreedyCapture = .{};
        _ = try router.feed(.{ .bytes = sequence[0..split], .now_ns = 0 }, &capture);
        try testing.expectEqual(@as(usize, 0), capture.key_count);
        _ = try router.feed(.{ .bytes = sequence[split..], .now_ns = 1 }, &capture);
        try testing.expectEqual(@as(usize, 0), capture.key_count);
        try testing.expectEqual(@as(usize, 0), capture.action_count);
    }
}

test "an application-owned key keeps repeats and release" {
    const lifecycle =
        "\x1b[13::13;2:1u" ++
        "\x1b[13::13;2:2u" ++
        "\x1b[13::13;1:3u";
    var router = try TestRouter.init(&.{});
    var capture: SemanticCapture = .{};

    _ = try router.feed(.{ .bytes = lifecycle, .now_ns = 0 }, &capture);

    try testing.expectEqual(@as(usize, 3), capture.key_count);
    try testing.expectEqual(Key.Phase.press, capture.keys[0].phase);
    try testing.expectEqual(Key.Phase.repeat, capture.keys[1].phase);
    try testing.expectEqual(Key.Phase.release, capture.keys[2].phase);
    try testing.expectEqual(@as(u32, 13), capture.keys[2].physical.?.value);
}

test "a binding-owned key consumes repeats and release" {
    const bindings = [_]TestBinding{try .parse(&.{"ctrl+s"}, .palette)};
    const lifecycle =
        "\x1b[115::115;5:1u" ++
        "\x1b[115::115;5:2u" ++
        "\x1b[115::115;1:3u";
    var router = try TestRouter.init(&bindings);
    var capture: SemanticCapture = .{};

    _ = try router.feed(.{ .bytes = lifecycle, .now_ns = 0 }, &capture);

    try testing.expectEqual(@as(usize, 1), capture.action_count);
    try testing.expectEqual(@as(usize, 0), capture.key_count);
}

test "holding a matched suffix repeats with pacing at every byte boundary" {
    const bindings = [_]TestBinding{try .parse(&.{ "ctrl+b", "-" }, .next)};
    const repeated = "\x1b[45::45;1:2u";

    for (0..repeated.len + 1) |split| {
        var router = try TestRouter.initWithPrefix(&bindings, default_prefix);
        var capture: SemanticCapture = .{ .repeat_policy = .{ .interval_ns = 100, .context = 7 } };
        _ = try router.feed(.{ .bytes = "\x1b[98::98;5:1u\x1b[45::45;1:1u\x1b[98::98;1:3u", .now_ns = 0 }, &capture);
        try testing.expectEqual(@as(usize, 1), capture.action_count);
        try testing.expect(!router.prefixPending());
        try testing.expect(router.bindingDeadline() == null);
        try testing.expect(router.inputDeadline() == null);

        _ = try router.feed(.{ .bytes = repeated, .now_ns = 99 }, &capture);
        try testing.expectEqual(@as(usize, 1), capture.action_count);
        _ = try router.feed(.{ .bytes = repeated[0..split], .now_ns = 100 }, &capture);
        _ = try router.feed(.{ .bytes = repeated[split..], .now_ns = 100 }, &capture);
        try testing.expectEqual(@as(usize, 2), capture.action_count);

        _ = try router.feed(.{ .bytes = repeated ++ repeated ++ repeated, .now_ns = 1000 }, &capture);
        try testing.expectEqual(@as(usize, 3), capture.action_count);
        _ = try router.feed(.{ .bytes = repeated, .now_ns = 1099 }, &capture);
        try testing.expectEqual(@as(usize, 3), capture.action_count);
        _ = try router.feed(.{ .bytes = repeated, .now_ns = 1100 }, &capture);
        try testing.expectEqual(@as(usize, 4), capture.action_count);

        _ = try router.feed(.{ .bytes = "\x1b[45::45;1:3u" ++ repeated, .now_ns = 2000 }, &capture);
        try testing.expectEqual(@as(usize, 4), capture.action_count);
        try testing.expectEqual(@as(usize, 0), capture.key_count);
        try testing.expect(router.repeating == null);
    }
}

test "repeat pacing cannot catch up at clock saturation or regression" {
    const bindings = [_]TestBinding{try .parse(&.{"-"}, .next)};
    var router = try TestRouter.init(&bindings);
    var capture: SemanticCapture = .{ .repeat_policy = .{ .interval_ns = 100, .context = 7 } };
    const end = std.math.maxInt(u64);
    const repeated = "\x1b[45::45;1:2u";

    _ = try router.feed(.{ .bytes = "\x1b[45::45;1:1u", .now_ns = end - 100 }, &capture);
    _ = try router.feed(.{ .bytes = repeated ++ repeated, .now_ns = end }, &capture);
    try testing.expectEqual(@as(usize, 2), capture.action_count);
    _ = try router.feed(.{ .bytes = repeated, .now_ns = 0 }, &capture);
    try testing.expectEqual(@as(usize, 2), capture.action_count);
}

test "global hold repeats but separate physical taps stay immediate" {
    const bindings = [_]TestBinding{try .parse(&.{"alt+-"}, .next)};
    var router = try TestRouter.init(&bindings);
    var capture: SemanticCapture = .{ .repeat_policy = .{ .interval_ns = 100, .context = 7 } };
    const press = "\x1b[45::45;3:1u";
    const release = "\x1b[45::45;1:3u";
    const repeated = "\x1b[45::45;3:2u";

    _ = try router.feed(.{ .bytes = press, .now_ns = 0 }, &capture);
    _ = try router.feed(.{ .bytes = repeated, .now_ns = 100 }, &capture);
    _ = try router.feed(.{ .bytes = release ++ press, .now_ns = 101 }, &capture);
    try testing.expectEqual(@as(usize, 3), capture.action_count);
    _ = try router.feed(.{ .bytes = repeated, .now_ns = 200 }, &capture);
    try testing.expectEqual(@as(usize, 3), capture.action_count);
    _ = try router.feed(.{ .bytes = repeated, .now_ns = 201 }, &capture);
    try testing.expectEqual(@as(usize, 4), capture.action_count);
    try testing.expectEqual(@as(usize, 0), capture.key_count);
}

test "losing a held chord modifier cancels without leaking into the application" {
    const bindings = [_]TestBinding{try .parse(&.{"alt+-"}, .next)};
    var router = try TestRouter.init(&bindings);
    var capture: SemanticCapture = .{ .repeat_policy = .{ .interval_ns = 100, .context = 7 } };

    _ = try router.feed(.{ .bytes = "\x1b[45::45;3:1u", .now_ns = 0 }, &capture);
    _ = try router.feed(.{ .bytes = "\x1b[45::45;1:2u", .now_ns = 100 }, &capture);
    _ = try router.feed(.{ .bytes = "\x1b[45::45;3:2u\x1b[45::45;1:3u", .now_ns = 200 }, &capture);
    try testing.expectEqual(@as(usize, 1), capture.action_count);
    try testing.expectEqual(@as(usize, 0), capture.key_count);
    try testing.expect(router.repeating == null);
}

test "new input and reload cancel hold while preserving physical ownership" {
    const bindings = [_]TestBinding{try .parse(&.{"-"}, .next)};
    const interruptions = [_][]const u8{ "x", "\x1b[<0;8;4M", "\x1b[200~paste\x1b[201~" };

    for (interruptions) |interruption| {
        var router = try TestRouter.init(&bindings);
        var capture: SemanticCapture = .{ .repeat_policy = .{ .interval_ns = 100, .context = 7 } };
        _ = try router.feed(.{ .bytes = "\x1b[45::45;1:1u", .now_ns = 0 }, &capture);
        _ = try router.feed(.{ .bytes = interruption, .now_ns = 1 }, &capture);
        const keys_before = capture.key_count;
        _ = try router.feed(.{ .bytes = "\x1b[45::45;1:2u\x1b[45::45;1:3u", .now_ns = 100 }, &capture);
        try testing.expectEqual(@as(usize, 1), capture.action_count);
        try testing.expectEqual(keys_before, capture.key_count);
        try testing.expect(router.repeating == null);
    }

    var router = try TestRouter.init(&bindings);
    var capture: SemanticCapture = .{ .repeat_policy = .{ .interval_ns = 100, .context = 7 } };
    _ = try router.feed(.{ .bytes = "\x1b[45::45;1:1u", .now_ns = 0 }, &capture);
    var replacement = try TestRouter.init(&.{});
    replacement.inheritPhysicalLeases(&router);
    _ = try replacement.feed(.{ .bytes = "\x1b[45::45;1:2u\x1b[45::45;1:3u", .now_ns = 100 }, &capture);
    try testing.expectEqual(@as(usize, 1), capture.action_count);
    try testing.expectEqual(@as(usize, 0), capture.key_count);
    try testing.expect(replacement.repeating == null);
}

test "changed or unavailable repeat authority permanently cancels the hold" {
    const bindings = [_]TestBinding{try .parse(&.{"-"}, .next)};
    const original: RepeatPolicy = .{ .interval_ns = 100, .context = 7 };
    const replacements = [_]?RepeatPolicy{ null, .{ .interval_ns = 100, .context = 8 } };

    for (replacements) |replacement| {
        var router = try TestRouter.init(&bindings);
        var capture: SemanticCapture = .{ .repeat_policy = original };
        _ = try router.feed(.{ .bytes = "\x1b[45::45;1:1u", .now_ns = 0 }, &capture);
        capture.repeat_policy = replacement;
        _ = try router.feed(.{ .bytes = "\x1b[45::45;1:2u", .now_ns = 1 }, &capture);
        capture.repeat_policy = original;
        _ = try router.feed(.{ .bytes = "\x1b[45::45;1:2u", .now_ns = 100 }, &capture);
        try testing.expectEqual(@as(usize, 1), capture.action_count);
        try testing.expectEqual(@as(usize, 0), capture.key_count);
        try testing.expect(router.repeating == null);
    }
}

test "a failed repeated action cancels further execution" {
    const bindings = [_]TestBinding{try .parse(&.{"-"}, .next)};
    var router = try TestRouter.init(&bindings);
    var capture: SemanticCapture = .{ .repeat_policy = .{ .interval_ns = 100, .context = 7 } };
    const key_value: Key = .{
        .code = .{ .char = .init("-") },
        .phase = .repeat,
        .physical = .{ .value = 45 },
    };

    _ = try router.feed(.{ .bytes = "\x1b[45::45;1:1u", .now_ns = 0 }, &capture);
    capture.fail_action = true;
    try testing.expectError(error.ActionFailed, router.routeEvent(.{ .key = key_value, .raw = "", .now_ns = 100 }, &capture));
    capture.fail_action = false;
    _ = try router.routeEvent(.{ .key = key_value, .raw = "", .now_ns = 200 }, &capture);
    try testing.expectEqual(@as(usize, 1), capture.action_count);
    try testing.expect(router.repeating == null);
}

test "releasing a physical prefix does not cancel its logical state" {
    const prefix = try parseKey("ctrl+s");
    const bindings = [_]TestBinding{try .parse(&.{ "ctrl+s", "d" }, .detach)};
    var router = try TestRouter.initWithPrefix(&bindings, prefix);
    var capture: Capture = .{};

    _ = try router.feed(.{ .bytes = "\x1b[115::115;5:1u" ++
        "\x1b[115::115;1:3u", .now_ns = 0 }, &capture);

    try testing.expect(router.prefixPending());
    try testing.expectEqual(@as(usize, 0), capture.action_len);
    _ = try router.feed(.{ .bytes = "d", .now_ns = 1 }, &capture);
    try testing.expect(!router.prefixPending());
    try testing.expectEqualSlices(TestAction, &.{.detach}, capture.actions[0..capture.action_len]);
    try testing.expectEqualStrings("", capture.slice());
}

test "router replacement preserves a held application's owner" {
    const press = "\x1b[120::120;1:1u";
    const release = "\x1b[120::120;1:3u";
    var current = try TestRouter.init(&.{});
    var capture: SemanticCapture = .{};

    _ = try current.feed(.{ .bytes = press, .now_ns = 0 }, &capture);
    var replacement = try TestRouter.init(&.{});
    replacement.inheritPhysicalLeases(&current);
    _ = try replacement.feed(.{ .bytes = release, .now_ns = 1 }, &capture);

    try testing.expectEqual(@as(usize, 2), capture.key_count);
    try testing.expectEqual(Key.Phase.release, capture.keys[1].phase);
}

test "lease saturation drops a new physical lifecycle" {
    var router = try TestRouter.init(&.{});
    var capture: SemanticCapture = .{};

    for (0..max_physical_leases + 1) |index| {
        const value: u32 = @intCast(index + 1);
        const key_value: Key = .{
            .code = .{ .char = .init("x") },
            .physical = .{ .value = value },
        };
        _ = try router.routeEvent(.{ .key = key_value, .raw = "", .now_ns = 0 }, &capture);
    }

    try testing.expectEqual(@as(usize, max_physical_leases), capture.key_count);
    try testing.expectEqual(@as(u64, 1), router.leaseOverflowCount());
}

test "failed application delivery does not leave native ownership" {
    const identity: Key.Physical = .{ .value = 120 };
    var router = try TestRouter.init(&.{});
    var capture: SemanticCapture = .{ .fail_key = true };

    try testing.expectError(error.KeyDeliveryFailed, router.routeEvent(.{ .key = .{
        .code = .{ .char = .init("x") },
        .physical = identity,
    }, .raw = "", .now_ns = 0 }, &capture));

    capture.fail_key = false;
    _ = try router.routeEvent(.{ .key = .{
        .code = .{ .char = .init("x") },
        .phase = .release,
        .physical = identity,
    }, .raw = "", .now_ns = 1 }, &capture);

    try testing.expectEqual(@as(usize, 0), capture.key_count);
}

test "a semantic mouse handler consumes reports before they reach the pane" {
    const bindings = [_]TestBinding{try .parse(&.{ "ctrl+b", "d" }, .detach)};
    var router = try TestRouter.init(&bindings);
    var capture: MouseCapture = .{};

    _ = try router.feed(.{ .bytes = "\x1b[<0;8;4M", .now_ns = 100 }, &capture);
    try testing.expectEqual(@as(usize, 1), capture.mouse_events);
    try testing.expectEqual(@as(usize, 0), capture.forwarded);
}

test "a fragmented KGP capability reply is consumed at every split" {
    const bindings = [_]TestBinding{try .parse(&.{ "ctrl+b", "d" }, .detach)};
    const reply = "\x1b_Gi=31;OK\x1b\\";
    for (1..reply.len) |split| {
        var router = try TestRouter.init(&bindings);
        var capture: TerminalResponseCapture = .{};
        _ = try router.feed(.{ .bytes = reply[0..split], .now_ns = 0 }, &capture);
        _ = try router.feed(.{ .bytes = reply[split..], .now_ns = 1 }, &capture);
        try testing.expectEqual(@as(usize, 0), capture.forwarded);
        try testing.expectEqual(@as(usize, 1), capture.responses);
        try testing.expect(capture.supported);
    }
}

test "an asynchronous terminal response does not cancel prefix mode" {
    const prefix = try parseKey("ctrl+b");
    const bindings = [_]TestBinding{try .parse(&.{ "ctrl+b", "d" }, .detach)};
    var router = try TestRouter.initWithPrefix(&bindings, prefix);
    var capture: TerminalResponseCapture = .{};

    _ = try router.feed(.{ .bytes = "\x02\x1b_Gi=31;OK\x1b\\", .now_ns = 100 }, &capture);
    try testing.expect(router.prefixPending());
    try testing.expectEqual(@as(usize, 1), capture.responses);
    _ = try router.feed(.{ .bytes = "d", .now_ns = 101 }, &capture);
    try testing.expect(!router.prefixPending());
    try testing.expectEqual(@as(usize, 1), capture.actions);
    try testing.expectEqual(@as(usize, 0), capture.forwarded);
}

test "a failed sequence replays its bytes in order" {
    const bindings = [_]TestBinding{try .parse(&.{ "ctrl+b", "d" }, .detach)};
    var router = try TestRouter.init(&bindings);
    var capture: Capture = .{};

    _ = try router.feed(.{ .bytes = "\x02x", .now_ns = 100 }, &capture);
    try testing.expectEqualStrings("\x02x", capture.slice());
    try testing.expectEqual(@as(usize, 0), capture.action_len);
}

test "a configured prefix waits without a binding deadline" {
    const prefix = try parseKey("ctrl+b");
    const bindings = [_]TestBinding{try .parse(&.{ "ctrl+b", "d" }, .detach)};
    var router = try TestRouter.initWithPrefix(&bindings, prefix);
    var capture: Capture = .{};

    _ = try router.feed(.{ .bytes = "\x02", .now_ns = 20 }, &capture);
    try testing.expect(router.prefixPending());
    try testing.expectEqual(@as(?u64, null), router.bindingDeadline());
    _ = try router.expireBinding(20 + 100 * default_sequence_timeout_ns, &capture);
    try testing.expect(router.prefixPending());
    try testing.expectEqualStrings("", capture.slice());

    _ = try router.feed(.{ .bytes = "d", .now_ns = 21 }, &capture);
    try testing.expect(!router.prefixPending());
    try testing.expectEqualSlices(TestAction, &.{.detach}, capture.actions[0..capture.action_len]);
}

test "an invalid prefix suffix is consumed" {
    const prefix = try parseKey("ctrl+b");
    const bindings = [_]TestBinding{try .parse(&.{ "ctrl+b", "d" }, .detach)};
    var router = try TestRouter.initWithPrefix(&bindings, prefix);
    var capture: Capture = .{};

    _ = try router.feed(.{ .bytes = "\x02x", .now_ns = 100 }, &capture);
    try testing.expect(!router.prefixPending());
    try testing.expectEqualStrings("", capture.slice());
    try testing.expectEqual(@as(usize, 0), capture.action_len);

    _ = try router.feed(.{ .bytes = "a", .now_ns = 101 }, &capture);
    try testing.expectEqualStrings("a", capture.slice());
}

test "escape cancels a pending prefix" {
    const prefix = try parseKey("ctrl+b");
    const bindings = [_]TestBinding{try .parse(&.{ "ctrl+b", "d" }, .detach)};
    var router = try TestRouter.initWithPrefix(&bindings, prefix);
    var capture: Capture = .{};

    _ = try router.feed(.{ .bytes = "\x02\x1b", .now_ns = 100 }, &capture);
    try testing.expect(router.prefixPending());
    _ = try router.expireInput(100 + default_escape_timeout_ns, &capture);
    try testing.expect(!router.prefixPending());
    try testing.expectEqualStrings("", capture.slice());
    try testing.expectEqual(@as(usize, 0), capture.action_len);
}

test "a global partial binding keeps its timeout beside a persistent prefix" {
    const prefix = try parseKey("ctrl+b");
    const bindings = [_]TestBinding{
        try .parse(&.{ "ctrl+b", "d" }, .detach),
        try .parse(&.{ "ctrl+x", "n" }, .next),
    };
    var router = try TestRouter.initWithPrefix(&bindings, prefix);
    var capture: Capture = .{};

    _ = try router.feed(.{ .bytes = "\x18", .now_ns = 40 }, &capture);
    try testing.expect(!router.prefixPending());
    try testing.expectEqual(@as(?u64, 40 + default_sequence_timeout_ns), router.bindingDeadline());
    _ = try router.expireBinding(40 + default_sequence_timeout_ns, &capture);
    try testing.expectEqualStrings("\x18", capture.slice());
}

test "the router exposes effective prefixed action keys" {
    const prefix = try parseKey("ctrl+s");
    const bindings = [_]TestBinding{
        try .parse(&.{ "ctrl+s", "x" }, .detach),
        try .parse(&.{"ctrl+d"}, .palette),
    };
    var router = try TestRouter.initWithPrefix(&bindings, prefix);

    try testing.expectEqualDeep(try parseKey("x"), router.prefixedKeyForAction(.detach).?);
    try testing.expect(router.prefixedKeyForAction(.palette) == null);
}

test "a split terminal sequence waits and still matches" {
    const bindings = [_]TestBinding{try .parse(&.{"up"}, .next)};
    var router = try TestRouter.init(&bindings);
    var capture: Capture = .{};

    _ = try router.feed(.{ .bytes = "\x1b", .now_ns = 100 }, &capture);
    try testing.expectEqualStrings("", capture.slice());
    try testing.expectEqual(@as(?u64, 100 + default_escape_timeout_ns), router.inputDeadline());

    _ = try router.feed(.{ .bytes = "[A", .now_ns = 101 }, &capture);
    try testing.expectEqualStrings("", capture.slice());
    try testing.expectEqualSlices(TestAction, &.{.next}, capture.actions[0..capture.action_len]);
    try testing.expectEqual(@as(?u64, null), router.inputDeadline());
}

test "terminal sequences are transparent at every chunk boundary" {
    const bindings = [_]TestBinding{try .parse(&.{ "ctrl+b", "d" }, .detach)};
    const input = "a\x1b[Añ\x1b[1;6D\x1b[999~z";

    var split: usize = 1;
    while (split < input.len) : (split += 1) {
        var router = try TestRouter.init(&bindings);
        var capture: Capture = .{};
        _ = try router.feed(.{ .bytes = input[0..split], .now_ns = 0 }, &capture);
        _ = try router.feed(.{ .bytes = input[split..], .now_ns = 1 }, &capture);
        try testing.expectEqualStrings(input, capture.slice());
    }
}

test "a lone escape becomes a key after its timeout" {
    const bindings = [_]TestBinding{try .parse(&.{"escape"}, .palette)};
    var router = try TestRouter.init(&bindings);
    var capture: Capture = .{};

    _ = try router.feed(.{ .bytes = "\x1b", .now_ns = 5 }, &capture);
    _ = try router.expireInput(5 + default_escape_timeout_ns - 1, &capture);
    try testing.expectEqual(@as(usize, 0), capture.action_len);

    _ = try router.expireInput(5 + default_escape_timeout_ns, &capture);
    try testing.expectEqualSlices(TestAction, &.{.palette}, capture.actions[0..capture.action_len]);
}

test "an incomplete unknown sequence is forwarded after its timeout" {
    const bindings = [_]TestBinding{try .parse(&.{"up"}, .next)};
    var router = try TestRouter.init(&bindings);
    var capture: Capture = .{};

    _ = try router.feed(.{ .bytes = "\x1b[123", .now_ns = 9 }, &capture);
    _ = try router.expireInput(9 + default_escape_timeout_ns, &capture);
    try testing.expectEqualStrings("\x1b[123", capture.slice());
}

test "a partial binding replays after its timeout" {
    const bindings = [_]TestBinding{try .parse(&.{ "ctrl+b", "d" }, .detach)};
    var router = try TestRouter.init(&bindings);
    var capture: Capture = .{};

    _ = try router.feed(.{ .bytes = "\x02", .now_ns = 20 }, &capture);
    try testing.expectEqual(@as(?u64, 20 + default_sequence_timeout_ns), router.bindingDeadline());
    _ = try router.expireBinding(20 + default_sequence_timeout_ns, &capture);
    try testing.expectEqualStrings("\x02", capture.slice());
}

test "an action may stop routing the rest of its input chunk" {
    const bindings = [_]TestBinding{try .parse(&.{ "ctrl+b", "d" }, .detach)};
    var router = try TestRouter.init(&bindings);
    var capture: Capture = .{ .stop_on_action = true };

    try testing.expectEqual(Control.stop, try router.feed(.{ .bytes = "a\x02db", .now_ns = 0 }, &capture));
    try testing.expectEqualStrings("a", capture.slice());
    try testing.expectEqualSlices(TestAction, &.{.detach}, capture.actions[0..capture.action_len]);
}
