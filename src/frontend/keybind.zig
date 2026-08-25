//! Key sequences between host terminal input and application actions.
//!
//! Configuration is deliberately outside this file. The Lua loader parses
//! strings into `Key` values and hands the resulting bindings to `Router.init`.
//! The router then owns a sorted, bounded copy. Routing performs no allocation
//! and never has to retain slices owned by the configuration parser.

const std = @import("std");
const term = @import("term.zig");

pub const Key = term.Event.Key;

pub const Control = enum {
    continue_routing,
    stop,
};

pub const default_escape_timeout_ns: u64 = 25 * std.time.ns_per_ms;
pub const default_sequence_timeout_ns: u64 = 1000 * std.time.ns_per_ms;
pub const default_prefix = parseKey("ctrl+b") catch unreachable;

/// Parses one key chord from configuration syntax.
///
/// Examples are `ctrl+b`, `ctrl+shift+left`, `escape`, `space`, and `ñ`.
/// Sequences stay arrays at this layer so configuration can parse a prefix and
/// its suffixes without another string grammar.
pub fn parseKey(text: []const u8) !Key {
    if (text.len == 0) return error.EmptyKey;

    var mods: Key.Mods = .{};
    var code_text: ?[]const u8 = null;
    var parts = std.mem.splitScalar(u8, text, '+');
    while (parts.next()) |part| {
        if (part.len == 0) return error.EmptyKeyPart;
        if (code_text != null) return error.ModifierAfterKey;

        if (eqlAscii(part, "ctrl") or eqlAscii(part, "control")) {
            if (mods.ctrl) return error.DuplicateModifier;
            mods.ctrl = true;
        } else if (eqlAscii(part, "alt")) {
            if (mods.alt) return error.DuplicateModifier;
            mods.alt = true;
        } else if (eqlAscii(part, "shift")) {
            if (mods.shift) return error.DuplicateModifier;
            mods.shift = true;
        } else {
            code_text = part;
        }
    }

    const name = code_text orelse return error.MissingKey;
    var code = try parseCode(name);

    // Legacy terminals report Shift+Tab as its own CSI sequence and do not set
    // a modifier bit. Store the form the input parser emits.
    if (code == .tab and mods.shift and !mods.ctrl and !mods.alt) {
        code = .back_tab;
        mods.shift = false;
    }

    // Ctrl letters arrive as C0 bytes and therefore lose their case. Treat
    // `ctrl+B` and `ctrl+b` as the same configuration value.
    if (mods.ctrl) switch (code) {
        .char => |*char| {
            if (char.len == 1 and std.ascii.isUpper(char.bytes[0]))
                char.bytes[0] = std.ascii.toLower(char.bytes[0]);
        },
        else => {},
    };

    // Legacy terminal input carries the resulting printable character, not a
    // Shift bit. Canonicalize the combinations whose result is independent of
    // keyboard layout and reject the rest instead of accepting a dead binding.
    if (mods.shift) switch (code) {
        .char => |*char| {
            if (mods.ctrl) return error.UnrepresentableKey;
            if (char.len == 1 and std.ascii.isAlphabetic(char.bytes[0])) {
                char.bytes[0] = std.ascii.toUpper(char.bytes[0]);
                mods.shift = false;
            } else if (char.len == 1 and char.bytes[0] == ' ') {
                mods.shift = false;
            } else {
                return error.UnrepresentableKey;
            }
        },
        else => {},
    };

    return .{ .code = code, .mods = mods };
}

fn parseCode(text: []const u8) !Key.Code {
    if (eqlAscii(text, "up")) return .up;
    if (eqlAscii(text, "down")) return .down;
    if (eqlAscii(text, "left")) return .left;
    if (eqlAscii(text, "right")) return .right;
    if (eqlAscii(text, "home")) return .home;
    if (eqlAscii(text, "end")) return .end;
    if (eqlAscii(text, "delete") or eqlAscii(text, "del")) return .delete;
    if (eqlAscii(text, "enter") or eqlAscii(text, "return")) return .enter;
    if (eqlAscii(text, "escape") or eqlAscii(text, "esc")) return .escape;
    if (eqlAscii(text, "backspace")) return .backspace;
    if (eqlAscii(text, "tab")) return .tab;
    if (eqlAscii(text, "backtab")) return .back_tab;
    if (eqlAscii(text, "space")) return .{ .char = .init(" ") };
    if (eqlAscii(text, "plus")) return .{ .char = .init("+") };

    const sequence_len = std.unicode.utf8ByteSequenceLength(text[0]) catch
        return error.InvalidUtf8;
    if (sequence_len != text.len) return error.KeyMustBeOneCodepoint;
    _ = std.unicode.utf8Decode(text) catch return error.InvalidUtf8;
    return .{ .char = .init(text) };
}

fn eqlAscii(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

pub fn Binding(comptime Action: type, comptime max_keys: usize) type {
    if (max_keys == 0 or max_keys > std.math.maxInt(u8))
        @compileError("max_keys must fit in a non-zero u8");

    return struct {
        // Fully initialized so configuration values remain safe to copy as a
        // whole struct even though comparisons inspect only `len` keys.
        keys: [max_keys]Key = @splat(.plain(.escape)),
        len: u8,
        action: Action,

        const Self = @This();

        pub fn init(keys: []const Key, action: Action) !Self {
            if (keys.len == 0) return error.EmptySequence;
            if (keys.len > max_keys) return error.SequenceTooLong;
            var binding: Self = .{ .len = @intCast(keys.len), .action = action };
            @memcpy(binding.keys[0..keys.len], keys);
            return binding;
        }

        pub fn parse(names: []const []const u8, action: Action) !Self {
            if (names.len == 0) return error.EmptySequence;
            if (names.len > max_keys) return error.SequenceTooLong;
            var binding: Self = .{ .len = @intCast(names.len), .action = action };
            for (names, 0..) |name, index| binding.keys[index] = try parseKey(name);
            return binding;
        }

        fn slice(binding: *const Self) []const Key {
            return binding.keys[0..binding.len];
        }
    };
}

pub fn Keymap(
    comptime Action: type,
    comptime max_bindings: usize,
    comptime max_keys: usize,
) type {
    if (max_bindings == 0 or max_bindings > std.math.maxInt(u16))
        @compileError("max_bindings must fit in a non-zero u16");

    const BindingType = Binding(Action, max_keys);
    return struct {
        bindings: [max_bindings]BindingType = undefined,
        order: [max_bindings]u16 = undefined,
        len: u16 = 0,

        const Self = @This();

        pub fn init(configured: []const BindingType) !Self {
            if (configured.len > max_bindings) return error.TooManyBindings;
            var map: Self = .{ .len = @intCast(configured.len) };
            for (configured, 0..) |binding, index| map.bindings[index] = binding;
            for (map.order[0..map.len], 0..) |*slot, index| slot.* = @intCast(index);
            // Sort small integer indices, not unions with inactive payloads and
            // padding. Configuration compilation moves two bytes at a time
            // instead of an entire binding.
            var unsorted: usize = 1;
            while (unsorted < map.len) : (unsorted += 1) {
                const candidate = map.order[unsorted];
                var position = unsorted;
                while (position > 0 and orderLessThan(&map.bindings, candidate, map.order[position - 1])) {
                    map.order[position] = map.order[position - 1];
                    position -= 1;
                }
                map.order[position] = candidate;
            }

            var index: usize = 1;
            while (index < map.len) : (index += 1) {
                const previous = map.bindingAt(index - 1);
                const current = map.bindingAt(index);
                const shared = commonPrefix(previous.slice(), current.slice());
                if (shared == previous.len or shared == current.len) {
                    if (previous.len == current.len) return error.DuplicateBinding;
                    return error.AmbiguousBindingPrefix;
                }
            }
            return map;
        }

        pub fn isEmpty(map: *const Self) bool {
            return map.len == 0;
        }

        const Range = struct { start: usize, end: usize };

        fn matchingRange(map: *const Self, range: Range, depth: usize, key: Key) ?Range {
            var low = range.start;
            var high = range.end;
            while (low < high) {
                const middle = low + (high - low) / 2;
                if (keyOrder(map.bindingAt(middle).keys[depth], key) == .lt)
                    low = middle + 1
                else
                    high = middle;
            }
            const start = low;

            high = range.end;
            while (low < high) {
                const middle = low + (high - low) / 2;
                if (keyOrder(map.bindingAt(middle).keys[depth], key) == .gt)
                    high = middle
                else
                    low = middle + 1;
            }
            if (start == low) return null;
            return .{ .start = start, .end = low };
        }

        fn bindingAt(map: *const Self, sorted_index: usize) *const BindingType {
            return &map.bindings[map.order[sorted_index]];
        }

        fn orderLessThan(bindings: *const [max_bindings]BindingType, a: u16, b: u16) bool {
            return sequenceOrder(bindings[a].slice(), bindings[b].slice()) == .lt;
        }
    };
}

fn commonPrefix(a: []const Key, b: []const Key) usize {
    const limit = @min(a.len, b.len);
    var index: usize = 0;
    while (index < limit and keyOrder(a[index], b[index]) == .eq) : (index += 1) {}
    return index;
}

fn sequenceOrder(a: []const Key, b: []const Key) std.math.Order {
    const limit = @min(a.len, b.len);
    for (0..limit) |index| {
        const order = keyOrder(a[index], b[index]);
        if (order != .eq) return order;
    }
    return std.math.order(a.len, b.len);
}

fn keyOrder(a: Key, b: Key) std.math.Order {
    if (a.mods.ctrl != b.mods.ctrl) return std.math.order(@intFromBool(a.mods.ctrl), @intFromBool(b.mods.ctrl));
    if (a.mods.alt != b.mods.alt) return std.math.order(@intFromBool(a.mods.alt), @intFromBool(b.mods.alt));
    if (a.mods.shift != b.mods.shift) return std.math.order(@intFromBool(a.mods.shift), @intFromBool(b.mods.shift));

    const a_tag = std.meta.activeTag(a.code);
    const b_tag = std.meta.activeTag(b.code);
    const tag_order = std.math.order(@intFromEnum(a_tag), @intFromEnum(b_tag));
    if (tag_order != .eq or a_tag != .char) return tag_order;

    const a_char = a.code.char;
    const b_char = b.code.char;
    return std.mem.order(u8, a_char.slice(), b_char.slice());
}

pub fn Router(
    comptime Action: type,
    comptime max_bindings: usize,
    comptime max_keys: usize,
    comptime input_capacity: usize,
    comptime held_capacity: usize,
) type {
    if (input_capacity == 0 or held_capacity == 0)
        @compileError("router buffers must be non-zero");

    const Map = Keymap(Action, max_bindings, max_keys);
    const BindingType = Binding(Action, max_keys);
    return struct {
        map: Map,
        candidates: Map.Range = .{ .start = 0, .end = 0 },
        depth: u8 = 0,
        held: [held_capacity]u8 = undefined,
        held_len: usize = 0,
        held_keys: [max_keys]Key = undefined,
        held_key_len: u8 = 0,
        input: [input_capacity]u8 = undefined,
        input_start: usize = 0,
        input_end: usize = 0,
        input_since_ns: ?u64 = null,
        binding_since_ns: ?u64 = null,
        output: [input_capacity + held_capacity]u8 = undefined,
        output_len: usize = 0,
        pasting: bool = false,
        escape_timeout_ns: u64 = default_escape_timeout_ns,
        sequence_timeout_ns: u64 = default_sequence_timeout_ns,

        const Self = @This();

        pub fn init(configured: []const BindingType) !Self {
            const map = try Map.init(configured);
            return .{
                .map = map,
                .candidates = .{ .start = 0, .end = map.len },
            };
        }

        /// Feeds host-terminal bytes through the compiled keymap.
        ///
        /// `handler.forward(bytes)` must finish using `bytes` before returning.
        /// `handler.action(action)` returns `.stop` when the action ends input
        /// processing, for example after detaching the client.
        pub fn feed(router: *Self, bytes: []const u8, now_ns: u64, handler: anytype) !Control {
            var offset: usize = 0;
            while (offset < bytes.len) {
                router.compactInput();
                const take = @min(router.input.len - router.input_end, bytes.len - offset);
                if (take == 0) {
                    try router.recoverFullInput(handler);
                    continue;
                }
                @memcpy(router.input[router.input_end..][0..take], bytes[offset..][0..take]);
                router.input_end += take;
                offset += take;
                if (try router.drain(now_ns, false, handler) == .stop) return .stop;
            }
            try router.flushOutput(handler);
            return .continue_routing;
        }

        pub fn inputDeadline(router: *const Self) ?u64 {
            const since = router.input_since_ns orelse return null;
            return since +| router.escape_timeout_ns;
        }

        pub fn bindingDeadline(router: *const Self) ?u64 {
            const since = router.binding_since_ns orelse return null;
            return since +| router.sequence_timeout_ns;
        }

        pub fn expireInput(router: *Self, now_ns: u64, handler: anytype) !Control {
            const deadline = router.inputDeadline() orelse return .continue_routing;
            if (now_ns < deadline) return .continue_routing;

            const pending = router.input[router.input_start..router.input_end];
            if (pending.len == 1 and pending[0] == 0x1b) {
                if (try router.drain(now_ns, true, handler) == .stop) return .stop;
            } else {
                try router.replayBinding(handler);
                if (comptime !@hasDecl(@TypeOf(handler.*), "key"))
                    try router.appendOutput(pending, handler);
                router.input_start = 0;
                router.input_end = 0;
                router.input_since_ns = null;
            }
            try router.flushOutput(handler);
            return .continue_routing;
        }

        pub fn expireBinding(router: *Self, now_ns: u64, handler: anytype) !Control {
            const deadline = router.bindingDeadline() orelse return .continue_routing;
            if (now_ns < deadline) return .continue_routing;
            try router.replayBinding(handler);
            try router.flushOutput(handler);
            return .continue_routing;
        }

        fn drain(router: *Self, now_ns: u64, force_escape: bool, handler: anytype) !Control {
            while (router.input_start < router.input_end) {
                const pending = router.input[router.input_start..router.input_end];
                if (!force_escape and pending.len == 1 and pending[0] == 0x1b) {
                    if (router.input_since_ns == null) router.input_since_ns = now_ns;
                    break;
                }

                const parsed = term.parse(pending) orelse break;
                if (parsed.len == 0) {
                    if (router.input_since_ns == null) router.input_since_ns = now_ns;
                    break;
                }

                router.input_since_ns = null;
                const raw = pending[0..parsed.len];
                if (router.pasting and std.meta.activeTag(parsed.event) != .paste_end) {
                    try router.flushOutput(handler);
                    if (comptime @hasDecl(@TypeOf(handler.*), "pasteContent"))
                        try handler.pasteContent(raw)
                    else
                        try router.appendOutput(raw, handler);
                    router.input_start += parsed.len;
                    continue;
                }
                switch (parsed.event) {
                    .key => |key| {
                        if (comptime @hasDecl(@TypeOf(handler.*), "capturesKeys")) {
                            if (handler.capturesKeys()) {
                                try router.replayBinding(handler);
                                try router.flushOutput(handler);
                                try handler.key(key);
                                router.input_start += parsed.len;
                                continue;
                            }
                        }
                        const was_pending = router.depth != 0;
                        switch (router.routeKey(key, raw)) {
                            .forward => |forwarded| {
                                if (comptime @hasDecl(@TypeOf(handler.*), "key")) {
                                    try router.flushOutput(handler);
                                    try handler.key(forwarded.key);
                                } else {
                                    try router.appendOutput(forwarded.raw, handler);
                                }
                            },
                            .replay => |replay| {
                                if (comptime @hasDecl(@TypeOf(handler.*), "key")) {
                                    try router.flushOutput(handler);
                                    for (replay.held_keys[0..replay.held_key_len]) |held_key|
                                        try handler.key(held_key);
                                    try handler.key(replay.current_key);
                                } else {
                                    try router.appendOutput(replay.held_raw[0..replay.held_raw_len], handler);
                                    try router.appendOutput(replay.current_raw, handler);
                                }
                            },
                            .pending => {
                                if (!was_pending) router.binding_since_ns = now_ns;
                            },
                            .action => |action| {
                                router.binding_since_ns = null;
                                try router.flushOutput(handler);
                                router.input_start += parsed.len;
                                if (try handler.action(action) == .stop) {
                                    router.clear();
                                    return .stop;
                                }
                                continue;
                            },
                        }
                        if (router.depth == 0) router.binding_since_ns = null;
                    },
                    .mouse => |mouse| {
                        if (comptime @hasDecl(@TypeOf(handler.*), "mouse")) {
                            // A pointer action belongs to telar's visible UI.
                            // Cancel a half-entered keybinding instead of
                            // leaking its prefix into the focused PTY.
                            router.resetMatch();
                            router.binding_since_ns = null;
                            try router.flushOutput(handler);
                            try handler.mouse(mouse);
                        } else {
                            try router.replayBinding(handler);
                            try router.appendOutput(raw, handler);
                        }
                    },
                    .terminal_response => |response| {
                        router.resetMatch();
                        router.binding_since_ns = null;
                        try router.flushOutput(handler);
                        if (comptime @hasDecl(@TypeOf(handler.*), "terminalResponse"))
                            try handler.terminalResponse(response);
                    },
                    .paste_start => {
                        try router.replayBinding(handler);
                        try router.flushOutput(handler);
                        router.pasting = true;
                        if (comptime @hasDecl(@TypeOf(handler.*), "pasteStart"))
                            try handler.pasteStart()
                        else
                            try router.appendOutput(raw, handler);
                    },
                    .paste_end => {
                        try router.replayBinding(handler);
                        try router.flushOutput(handler);
                        router.pasting = false;
                        if (comptime @hasDecl(@TypeOf(handler.*), "pasteEnd"))
                            try handler.pasteEnd()
                        else
                            try router.appendOutput(raw, handler);
                    },
                    .incomplete => {
                        try router.replayBinding(handler);
                        if (comptime !@hasDecl(@TypeOf(handler.*), "key"))
                            try router.appendOutput(raw, handler);
                    },
                }
                router.input_start += parsed.len;
            }

            if (router.input_start == router.input_end) {
                router.input_start = 0;
                router.input_end = 0;
            }
            return .continue_routing;
        }

        const Routed = union(enum) {
            forward: struct { key: Key, raw: []const u8 },
            replay: struct {
                held_keys: [max_keys]Key,
                held_key_len: u8,
                held_raw: [held_capacity]u8,
                held_raw_len: usize,
                current_key: Key,
                current_raw: []const u8,
            },
            pending,
            action: Action,
        };

        fn routeKey(router: *Self, key: Key, raw: []const u8) Routed {
            const range = if (router.depth == 0)
                Map.Range{ .start = 0, .end = router.map.len }
            else
                router.candidates;
            const matched = router.map.matchingRange(range, router.depth, key) orelse {
                if (router.depth == 0) return .{ .forward = .{ .key = key, .raw = raw } };
                const held_key_len = router.held_key_len;
                const held_raw_len = router.held_len;
                var held_keys: [max_keys]Key = undefined;
                var held_raw: [held_capacity]u8 = undefined;
                @memcpy(held_keys[0..held_key_len], router.held_keys[0..held_key_len]);
                @memcpy(held_raw[0..held_raw_len], router.held[0..held_raw_len]);
                router.resetMatch();
                return .{ .replay = .{
                    .held_keys = held_keys,
                    .held_key_len = held_key_len,
                    .held_raw = held_raw,
                    .held_raw_len = held_raw_len,
                    .current_key = key,
                    .current_raw = raw,
                } };
            };

            const next_depth: usize = router.depth + 1;
            const first = router.map.bindingAt(matched.start);
            if (first.len == next_depth) {
                const action = first.action;
                router.resetMatch();
                return .{ .action = action };
            }

            if (router.held_len + raw.len > router.held.len) {
                const held_key_len = router.held_key_len;
                const held_raw_len = router.held_len;
                var held_keys: [max_keys]Key = undefined;
                var held_raw: [held_capacity]u8 = undefined;
                @memcpy(held_keys[0..held_key_len], router.held_keys[0..held_key_len]);
                @memcpy(held_raw[0..held_raw_len], router.held[0..held_raw_len]);
                router.resetMatch();
                return .{ .replay = .{
                    .held_keys = held_keys,
                    .held_key_len = held_key_len,
                    .held_raw = held_raw,
                    .held_raw_len = held_raw_len,
                    .current_key = key,
                    .current_raw = raw,
                } };
            }
            @memcpy(router.held[router.held_len..][0..raw.len], raw);
            router.held_len += raw.len;
            router.held_keys[router.held_key_len] = key;
            router.held_key_len += 1;
            router.candidates = matched;
            router.depth = @intCast(next_depth);
            return .pending;
        }

        fn replayBinding(router: *Self, handler: anytype) !void {
            if (router.depth == 0) return;
            if (comptime @hasDecl(@TypeOf(handler.*), "key")) {
                try router.flushOutput(handler);
                for (router.held_keys[0..router.held_key_len]) |held_key|
                    try handler.key(held_key);
            } else {
                try router.appendOutput(router.held[0..router.held_len], handler);
            }
            router.resetMatch();
            router.binding_since_ns = null;
        }

        fn resetMatch(router: *Self) void {
            router.candidates = .{ .start = 0, .end = router.map.len };
            router.depth = 0;
            router.held_len = 0;
            router.held_key_len = 0;
        }

        fn clear(router: *Self) void {
            router.resetMatch();
            router.input_start = 0;
            router.input_end = 0;
            router.input_since_ns = null;
            router.binding_since_ns = null;
            router.output_len = 0;
            router.pasting = false;
        }

        fn appendOutput(router: *Self, bytes: []const u8, handler: anytype) !void {
            if (bytes.len > router.output.len) {
                try router.flushOutput(handler);
                try handler.forward(bytes);
                return;
            }
            if (router.output_len + bytes.len > router.output.len)
                try router.flushOutput(handler);
            @memcpy(router.output[router.output_len..][0..bytes.len], bytes);
            router.output_len += bytes.len;
        }

        fn flushOutput(router: *Self, handler: anytype) !void {
            if (router.output_len == 0) return;
            try handler.forward(router.output[0..router.output_len]);
            router.output_len = 0;
        }

        fn compactInput(router: *Self) void {
            if (router.input_start == 0) return;
            const len = router.input_end - router.input_start;
            std.mem.copyForwards(u8, router.input[0..len], router.input[router.input_start..router.input_end]);
            router.input_start = 0;
            router.input_end = len;
        }

        fn recoverFullInput(router: *Self, handler: anytype) !void {
            try router.replayBinding(handler);
            if (comptime !@hasDecl(@TypeOf(handler.*), "key"))
                try router.appendOutput(router.input[router.input_start..router.input_end], handler);
            router.input_start = 0;
            router.input_end = 0;
            router.input_since_ns = null;
            try router.flushOutput(handler);
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestAction = enum { detach, palette, next };
const TestBinding = Binding(TestAction, 4);
const TestRouter = Router(TestAction, 16, 4, 64, 32);

const Capture = struct {
    bytes: [256]u8 = undefined,
    len: usize = 0,
    actions: [8]TestAction = undefined,
    action_len: usize = 0,
    stop_on_action: bool = false,

    fn forward(capture: *Capture, bytes: []const u8) !void {
        if (capture.len + bytes.len > capture.bytes.len) return error.CaptureOverflow;
        @memcpy(capture.bytes[capture.len..][0..bytes.len], bytes);
        capture.len += bytes.len;
    }

    fn action(capture: *Capture, value: TestAction) !Control {
        capture.actions[capture.action_len] = value;
        capture.action_len += 1;
        return if (capture.stop_on_action) .stop else .continue_routing;
    }

    fn slice(capture: *const Capture) []const u8 {
        return capture.bytes[0..capture.len];
    }
};

const GreedyCapture = struct {
    keys: [8]Key = undefined,
    key_count: usize = 0,
    action_count: usize = 0,

    fn capturesKeys(_: *const GreedyCapture) bool {
        return true;
    }

    fn key(capture: *GreedyCapture, value: Key) !void {
        capture.keys[capture.key_count] = value;
        capture.key_count += 1;
    }

    fn forward(_: *GreedyCapture, _: []const u8) !void {}

    fn action(capture: *GreedyCapture, _: TestAction) !Control {
        capture.action_count += 1;
        return .continue_routing;
    }
};

const MouseCapture = struct {
    forwarded: usize = 0,
    mouse_events: usize = 0,

    fn forward(capture: *MouseCapture, bytes: []const u8) !void {
        capture.forwarded += bytes.len;
    }

    fn action(_: *MouseCapture, _: TestAction) !Control {
        return .continue_routing;
    }

    fn mouse(capture: *MouseCapture, _: term.Event.Mouse) !void {
        capture.mouse_events += 1;
    }
};

const TerminalResponseCapture = struct {
    forwarded: usize = 0,
    responses: usize = 0,
    supported: bool = false,

    fn forward(capture: *TerminalResponseCapture, bytes: []const u8) !void {
        capture.forwarded += bytes.len;
    }

    fn action(_: *TerminalResponseCapture, _: TestAction) !Control {
        return .continue_routing;
    }

    fn terminalResponse(capture: *TerminalResponseCapture, response: term.Event.TerminalResponse) !void {
        switch (response) {
            .kitty_graphics => |kitty| capture.supported = kitty.supported,
            else => {},
        }
        capture.responses += 1;
    }
};

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

    _ = try router.feed("a", 0, &capture);

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
    _ = try router.feed("\x02d\x02p", 0, &capture);
    try testing.expectEqualSlices(
        TestAction,
        &.{ .detach, .palette },
        capture.actions[0..capture.action_len],
    );
}

test "keymap action representation does not affect sequence identity" {
    const SmallAction = enum(u8) { detach, palette };
    const SmallBinding = Binding(SmallAction, 4);
    const SmallRouter = Router(SmallAction, 16, 4, 64, 32);
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
    try testing.expectEqual(Control.continue_routing, try router.feed(input, 0, &capture));
    try testing.expectEqualStrings(input, capture.slice());
    try testing.expectEqual(@as(usize, 0), capture.action_len);
}

test "a configured sequence runs once and does not reach the pane" {
    const bindings = [_]TestBinding{try .parse(&.{ "ctrl+b", "d" }, .detach)};
    var router = try TestRouter.init(&bindings);
    var capture: Capture = .{};

    _ = try router.feed("before\x02dafter", 100, &capture);
    try testing.expectEqualStrings("beforeafter", capture.slice());
    try testing.expectEqualSlices(TestAction, &.{.detach}, capture.actions[0..capture.action_len]);
}

test "a semantic mouse handler consumes reports before they reach the pane" {
    const bindings = [_]TestBinding{try .parse(&.{ "ctrl+b", "d" }, .detach)};
    var router = try TestRouter.init(&bindings);
    var capture: MouseCapture = .{};

    _ = try router.feed("\x1b[<0;8;4M", 100, &capture);
    try testing.expectEqual(@as(usize, 1), capture.mouse_events);
    try testing.expectEqual(@as(usize, 0), capture.forwarded);
}

test "a fragmented KGP capability reply is consumed at every split" {
    const bindings = [_]TestBinding{try .parse(&.{ "ctrl+b", "d" }, .detach)};
    const reply = "\x1b_Gi=31;OK\x1b\\";
    for (1..reply.len) |split| {
        var router = try TestRouter.init(&bindings);
        var capture: TerminalResponseCapture = .{};
        _ = try router.feed(reply[0..split], 0, &capture);
        _ = try router.feed(reply[split..], 1, &capture);
        try testing.expectEqual(@as(usize, 0), capture.forwarded);
        try testing.expectEqual(@as(usize, 1), capture.responses);
        try testing.expect(capture.supported);
    }
}

test "a failed sequence replays its bytes in order" {
    const bindings = [_]TestBinding{try .parse(&.{ "ctrl+b", "d" }, .detach)};
    var router = try TestRouter.init(&bindings);
    var capture: Capture = .{};

    _ = try router.feed("\x02x", 100, &capture);
    try testing.expectEqualStrings("\x02x", capture.slice());
    try testing.expectEqual(@as(usize, 0), capture.action_len);
}

test "a split terminal sequence waits and still matches" {
    const bindings = [_]TestBinding{try .parse(&.{"up"}, .next)};
    var router = try TestRouter.init(&bindings);
    var capture: Capture = .{};

    _ = try router.feed("\x1b", 100, &capture);
    try testing.expectEqualStrings("", capture.slice());
    try testing.expectEqual(@as(?u64, 100 + default_escape_timeout_ns), router.inputDeadline());

    _ = try router.feed("[A", 101, &capture);
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
        _ = try router.feed(input[0..split], 0, &capture);
        _ = try router.feed(input[split..], 1, &capture);
        try testing.expectEqualStrings(input, capture.slice());
    }
}

test "a lone escape becomes a key after its timeout" {
    const bindings = [_]TestBinding{try .parse(&.{"escape"}, .palette)};
    var router = try TestRouter.init(&bindings);
    var capture: Capture = .{};

    _ = try router.feed("\x1b", 5, &capture);
    _ = try router.expireInput(5 + default_escape_timeout_ns - 1, &capture);
    try testing.expectEqual(@as(usize, 0), capture.action_len);

    _ = try router.expireInput(5 + default_escape_timeout_ns, &capture);
    try testing.expectEqualSlices(TestAction, &.{.palette}, capture.actions[0..capture.action_len]);
}

test "an incomplete unknown sequence is forwarded after its timeout" {
    const bindings = [_]TestBinding{try .parse(&.{"up"}, .next)};
    var router = try TestRouter.init(&bindings);
    var capture: Capture = .{};

    _ = try router.feed("\x1b[123", 9, &capture);
    _ = try router.expireInput(9 + default_escape_timeout_ns, &capture);
    try testing.expectEqualStrings("\x1b[123", capture.slice());
}

test "a partial binding replays after its timeout" {
    const bindings = [_]TestBinding{try .parse(&.{ "ctrl+b", "d" }, .detach)};
    var router = try TestRouter.init(&bindings);
    var capture: Capture = .{};

    _ = try router.feed("\x02", 20, &capture);
    try testing.expectEqual(@as(?u64, 20 + default_sequence_timeout_ns), router.bindingDeadline());
    _ = try router.expireBinding(20 + default_sequence_timeout_ns, &capture);
    try testing.expectEqualStrings("\x02", capture.slice());
}

test "an action may stop routing the rest of its input chunk" {
    const bindings = [_]TestBinding{try .parse(&.{ "ctrl+b", "d" }, .detach)};
    var router = try TestRouter.init(&bindings);
    var capture: Capture = .{ .stop_on_action = true };

    try testing.expectEqual(Control.stop, try router.feed("a\x02db", 0, &capture));
    try testing.expectEqualStrings("a", capture.slice());
    try testing.expectEqualSlices(TestAction, &.{.detach}, capture.actions[0..capture.action_len]);
}
