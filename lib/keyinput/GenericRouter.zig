const GenericBinding = @import("GenericBinding.zig").Type;
const GenericTable = @import("GenericTable.zig").Type;
const Key = @import("Key.zig");
const RepeatPolicy = @import("RepeatPolicy.zig");
const RouterLimits = @import("RouterLimits.zig");
const chord = @import("chord.zig");
const keybind = @import("keybind.zig");
const routing_tests = @import("routing_tests.zig");
const GenericKeymap = @import("GenericKeymap.zig").Type;
const std = @import("std");
const Capture = @import("RoutingCapture.zig");

pub fn Type(comptime Action: type, comptime limits: RouterLimits, comptime Decoder: type) type {
    const term = Decoder;
    const max_bindings = limits.max_bindings;
    const max_keys = limits.max_keys;
    const input_capacity = limits.input_capacity;
    const held_capacity = limits.held_capacity;

    if (input_capacity == 0 or held_capacity == 0) {
        @compileError("router buffers must be non-zero");
    }

    const Map = GenericKeymap(Action, max_bindings, max_keys);
    const BindingType = GenericBinding(Action, max_keys);
    const LeaseOwner = enum { binding, application };
    const Leases = GenericTable(LeaseOwner, limits.max_physical_leases);
    return struct {
        pub const Feed = struct {
            bytes: []const u8,
            now_ns: u64,
        };

        pub const Context = struct {
            captures_keys: bool = false,
            repeat_policy: ?RepeatPolicy = null,
        };

        pub const ActionRequest = struct {
            value: Action,
            key: Key,
            now_ns: u64,
            repeated: bool = false,
        };

        pub const Replay = struct {
            held_keys: [max_keys]Key = undefined,
            held_key_len: u8 = 0,
            held_raw: [held_capacity]u8 = undefined,
            held_raw_len: usize = 0,
            current_key: ?Key = null,
            current_raw: []const u8 = "",
        };

        pub const Decision = union(enum) {
            forward: struct { key: Key, raw: []const u8 },
            replay: Replay,
            action: ActionRequest,
            pending,
            discard,
        };

        const HostEvent = if (Decoder != void and @hasDecl(Decoder, "Event")) Decoder.Event else void;
        pub const Decoded = struct {
            event: HostEvent,
            raw: []const u8,
            paste_content: bool = false,
        };

        map: Map,
        prefix: ?Key = null,
        candidates: Map.Range = .{ .start = 0, .end = 0 },
        depth: u8 = 0,
        prefix_pending: bool = false,
        held: [held_capacity]u8 = undefined,
        held_len: usize = 0,
        held_keys: [max_keys]Key = undefined,
        held_key_len: u8 = 0,
        input: [input_capacity]u8 = undefined,
        input_start: usize = 0,
        input_end: usize = 0,
        input_since_ns: ?u64 = null,
        binding_since_ns: ?u64 = null,
        pasting: bool = false,
        escape_timeout_ns: u64 = limits.escape_timeout_ns,
        sequence_timeout_ns: u64 = limits.sequence_timeout_ns,
        leases: Leases = .{},
        repeating: ?RepeatingBinding = null,

        const RepeatingBinding = struct {
            key: Key,
            action: Action,
            policy: RepeatPolicy,
            last_ns: u64,
        };

        const Self = @This();

        pub fn init(configured: []const BindingType) !Self {
            return initWithPrefix(configured, null);
        }

        pub fn initWithPrefix(configured: []const BindingType, prefix: ?Key) !Self {
            const map = try Map.init(configured);
            return .{
                .map = map,
                .prefix = prefix,
                .candidates = .{ .start = 0, .end = map.len },
            };
        }

        pub fn prefixPending(self: *const Self) bool {
            return self.prefix_pending;
        }

        /// Admits configured shortcuts before a local editor handles the key.
        /// Pending sequences own their next press, including misses and Escape,
        /// so normal routing can resolve replay or discard. Repeats and releases
        /// retain only an existing binding lease, independent of focus or modifiers.
        /// This query never advances a sequence or changes physical ownership.
        /// Example: `if (router.wantsBinding(key)) return routeGlobal(key);`
        pub fn wantsBinding(self: *const Self, key: Key) bool {
            if (key.phase != .press) {
                const physical = key.physical orelse return false;
                return self.leases.owner(physical) == .binding;
            }

            if (self.depth != 0) {
                return true;
            }

            return self.map.matchingRange(.{ .start = 0, .end = self.map.len }, .{ .depth = 0, .key = key }) != null;
        }

        /// Returns a physical key to a widget after a chord replays into it.
        /// The widget then owns subsequent repeats and release; another key's
        /// retained repeat remains active. Example: `router.relinquishKey(physical);`
        pub fn relinquishKey(self: *Self, physical: Key.Physical) void {
            _ = self.releasePhysicalKey(physical);
        }

        /// Copies physical ownership into a replacement router.
        ///
        /// Configuration reloads replace the compiled keymap while keys may
        /// still be held. Keeping their leases prevents a repeat or release
        /// from being reclassified by the new bindings.
        ///
        /// ```zig
        /// var replacement = try Router.init(bindings);
        /// replacement.inheritPhysicalLeases(&current);
        /// ```
        pub fn inheritPhysicalLeases(self: *Self, previous: *const Self) void {
            self.leases = previous.leases;
            self.repeating = null;
        }

        /// Returns how many physical presses were dropped because the bounded
        /// lease table was saturated.
        ///
        /// ```zig
        /// const dropped = router.leaseOverflowCount();
        /// ```
        pub fn leaseOverflowCount(self: *const Self) u64 {
            return self.leases.overflowCount();
        }

        /// Returns the configured one-key suffix for a prefixed action. The
        /// client uses this to render help from the effective keymap instead
        /// of repeating default binding labels in the UI.
        pub fn prefixedKeyForAction(self: *const Self, action: Action) ?Key {
            const prefix = self.prefix orelse return null;
            for (self.map.bindings[0..self.map.len]) |*binding| {
                if (binding.len != 2 or keybind.keyOrder(binding.keys[0], prefix) != .eq) {
                    continue;
                }
                if (std.meta.eql(binding.action, action)) {
                    return binding.keys[1];
                }
            }
            return null;
        }

        /// Consumes bytes only until the next host event. Borrowed raw bytes stay
        /// valid until the next decoder call. Execute this event before pulling
        /// another one: actions can change focus, capture or stop the client.
        /// Example: `while (router.next(&feed)) |event| { try apply(event); }`
        pub fn next(self: *Self, feed: *Feed) ?Decoded {
            while (true) {
                const pending = self.input[self.input_start..self.input_end];
                const lone_escape = pending.len == 1 and pending[0] == 0x1b;
                if (pending.len != 0 and !lone_escape) {
                    if (term.parse(pending)) |parsed| {
                        if (parsed.len != 0) {
                            self.input_start += parsed.len;
                            self.input_since_ns = null;
                            const content = self.pasting and parsed.event != .paste_end;
                            if (!content) {
                                if (parsed.event == .paste_start) {
                                    self.pasting = true;
                                }
                                if (parsed.event == .paste_end) {
                                    self.pasting = false;
                                }
                            }

                            return .{ .event = parsed.event, .raw = pending[0..parsed.len], .paste_content = content };
                        }
                    }
                }

                if (pending.len != 0 and self.input_since_ns == null) {
                    self.input_since_ns = feed.now_ns;
                }
                if (feed.bytes.len == 0) {
                    return null;
                }

                if (pending.len == self.input.len) {
                    self.input_start = self.input_end;
                    self.input_since_ns = null;
                    return .{ .event = .incomplete, .raw = pending, .paste_content = self.pasting };
                }

                self.compactInput();
                const count = @min(self.input.len - self.input_end, feed.bytes.len);
                @memcpy(self.input[self.input_end..][0..count], feed.bytes[0..count]);
                self.input_end += count;
                feed.bytes = feed.bytes[count..];
            }
        }

        pub fn inputDeadline(self: *const Self) ?u64 {
            const since = self.input_since_ns orelse return null;
            return since +| self.escape_timeout_ns;
        }

        pub fn bindingDeadline(self: *const Self) ?u64 {
            if (self.prefix_pending) {
                return null;
            }
            const since = self.binding_since_ns orelse return null;
            return since +| self.sequence_timeout_ns;
        }

        /// Resolves a timed-out host sequence; malformed input remains explicitly
        /// marked and must never be sent verbatim to a child terminal.
        /// Example: `if (router.expireInput(now)) |event| try apply(event);`
        pub fn expireInput(self: *Self, now_ns: u64) ?Decoded {
            const deadline = self.inputDeadline() orelse return null;
            if (now_ns < deadline) {
                return null;
            }

            const pending = self.input[self.input_start..self.input_end];
            const event: HostEvent = if (pending.len == 1 and pending[0] == 0x1b)
                term.parse(pending).?.event
            else
                .incomplete;
            self.input_start = self.input_end;
            self.input_since_ns = null;
            return .{ .event = event, .raw = pending, .paste_content = self.pasting and event != .paste_end };
        }

        pub fn expireBinding(self: *Self, now_ns: u64) Decision {
            const deadline = self.bindingDeadline() orelse return .pending;
            if (now_ns < deadline) {
                return .pending;
            }
            return self.replayBinding();
        }

        pub const KeyInput = struct {
            key: Key,
            raw: []const u8,
            now_ns: u64,
        };

        /// Decides ownership and binding resolution without calling application code.
        /// Supply current capture/repeat policy before every event, then execute the
        /// decision before routing another. Example: `const decision = router.routeEvent(event, context);`
        pub fn routeEvent(self: *Self, input: KeyInput, context: Context) Decision {
            if (input.key.phase == .press) {
                self.repeating = null;
            }

            if (input.key.physical) |identity| {
                switch (input.key.phase) {
                    .press => {
                        if (!self.leases.acquire(identity, .binding)) {
                            return .discard;
                        }
                    },
                    .repeat => {
                        if (self.leases.owner(identity) == .binding) {
                            return self.repeatBinding(input, context.repeat_policy);
                        }
                        if (self.leases.owner(identity) != .application) {
                            return .discard;
                        }
                        return .{ .forward = .{ .key = input.key, .raw = input.raw } };
                    },
                    .release => {
                        if (self.releasePhysicalKey(identity) != .application) {
                            return .discard;
                        }
                        return .{ .forward = .{ .key = input.key, .raw = input.raw } };
                    },
                }
            }

            if (context.captures_keys) {
                const previous = self.replayBinding();
                self.transferKeyToApplication(input.key);
                if (previous == .replay) {
                    var replay = previous.replay;
                    replay.current_key = input.key;
                    replay.current_raw = input.raw;
                    return .{ .replay = replay };
                }
                return .{ .forward = .{ .key = input.key, .raw = input.raw } };
            }

            const was_pending = self.depth != 0;
            const routed = self.routeKey(input);
            switch (routed) {
                .forward => |forwarded| self.transferKeyToApplication(forwarded.key),
                .replay => |replay| {
                    self.transferKeysToApplication(replay.held_keys[0..replay.held_key_len]);
                    self.transferKeyToApplication(replay.current_key.?);
                },
                .pending => {
                    if (!was_pending and !self.prefix_pending) {
                        self.binding_since_ns = input.now_ns;
                    }
                },
                .discard => {},
                .action => {
                    self.binding_since_ns = null;
                },
            }
            if (self.depth == 0) {
                self.binding_since_ns = null;
            }
            return routed;
        }

        /// Query the policy for this action in the current application state.
        /// Example: `const policy = if (router.repeatAction()) |a| repeatPolicy(a) else null;`
        pub fn repeatAction(self: *const Self) ?Action {
            return if (self.repeating) |held| held.action else null;
        }

        /// Arm repeats only after a successful action, using its resulting owner.
        /// Example: `router.actionCompleted(request, repeatPolicy(request.value));`
        pub fn actionCompleted(self: *Self, request: ActionRequest, policy: ?RepeatPolicy) void {
            if (request.repeated or request.key.physical == null) {
                return;
            }
            if (policy) |value| {
                std.debug.assert(value.interval_ns != 0);
                self.repeating = .{ .key = request.key, .action = request.value, .policy = value, .last_ns = request.now_ns };
            }
        }

        /// Release a failed press and cancel repeats after delivery/action errors.
        /// Example: `errdefer router.eventFailed(input.key);`
        pub fn eventFailed(self: *Self, key: Key) void {
            self.repeating = null;
            if (key.phase == .press) {
                if (key.physical) |physical| {
                    _ = self.leases.release(physical);
                }
            }
        }

        fn repeatBinding(self: *Self, input: KeyInput, policy: ?RepeatPolicy) Decision {
            const held = self.repeating orelse return .discard;
            if (!held.key.physical.?.eql(input.key.physical.?)) {
                return .discard;
            }
            if (keybind.keyOrder(held.key, input.key) != .eq or !std.meta.eql(policy, @as(?RepeatPolicy, held.policy))) {
                self.repeating = null;
                return .discard;
            }
            if (input.now_ns -| held.last_ns < held.policy.interval_ns) {
                return .discard;
            }

            // A late or batched repeat produces one step, without catch-up work.
            self.repeating.?.last_ns = input.now_ns;
            return .{ .action = .{ .value = held.action, .key = input.key, .now_ns = input.now_ns, .repeated = true } };
        }

        fn releasePhysicalKey(self: *Self, physical: Key.Physical) ?LeaseOwner {
            if (self.repeating) |held| {
                if (held.key.physical.?.eql(physical)) {
                    self.repeating = null;
                }
            }

            return self.leases.release(physical);
        }

        fn transferKeyToApplication(self: *Self, key_value: Key) void {
            const identity = key_value.physical orelse return;
            if (self.leases.owner(identity) == null) {
                return;
            }

            const transferred = self.leases.acquire(identity, .application);
            std.debug.assert(transferred);
        }

        fn transferKeysToApplication(self: *Self, keys: []const Key) void {
            for (keys) |key_value| {
                self.transferKeyToApplication(key_value);
            }
        }

        fn routeKey(self: *Self, input: KeyInput) Decision {
            const key = input.key;
            const raw = input.raw;
            if (self.prefix_pending and keybind.isPlainEscape(key)) {
                self.resetMatch();
                return .discard;
            }
            const range = if (self.depth == 0)
                Map.Range{ .start = 0, .end = self.map.len }
            else
                self.candidates;
            const matched = self.map.matchingRange(range, .{ .depth = self.depth, .key = key }) orelse {
                if (self.depth == 0) {
                    return .{ .forward = .{ .key = key, .raw = raw } };
                }
                if (self.prefix_pending) {
                    self.resetMatch();
                    return .discard;
                }
                const held_key_len = self.held_key_len;
                const held_raw_len = self.held_len;
                var held_keys: [max_keys]Key = undefined;
                var held_raw: [held_capacity]u8 = undefined;
                @memcpy(held_keys[0..held_key_len], self.held_keys[0..held_key_len]);
                @memcpy(held_raw[0..held_raw_len], self.held[0..held_raw_len]);
                self.resetMatch();
                return .{ .replay = .{
                    .held_keys = held_keys,
                    .held_key_len = held_key_len,
                    .held_raw = held_raw,
                    .held_raw_len = held_raw_len,
                    .current_key = key,
                    .current_raw = raw,
                } };
            };

            const next_depth: usize = self.depth + 1;
            const first = self.map.bindingAt(matched.start);
            if (first.len == next_depth) {
                const action = first.action;
                self.resetMatch();
                return .{ .action = .{ .value = action, .key = key, .now_ns = input.now_ns } };
            }

            if (self.held_len + raw.len > self.held.len) {
                const held_key_len = self.held_key_len;
                const held_raw_len = self.held_len;
                var held_keys: [max_keys]Key = undefined;
                var held_raw: [held_capacity]u8 = undefined;
                @memcpy(held_keys[0..held_key_len], self.held_keys[0..held_key_len]);
                @memcpy(held_raw[0..held_raw_len], self.held[0..held_raw_len]);
                self.resetMatch();
                return .{ .replay = .{
                    .held_keys = held_keys,
                    .held_key_len = held_key_len,
                    .held_raw = held_raw,
                    .held_raw_len = held_raw_len,
                    .current_key = key,
                    .current_raw = raw,
                } };
            }
            @memcpy(self.held[self.held_len..][0..raw.len], raw);
            self.held_len += raw.len;
            self.held_keys[self.held_key_len] = key;
            self.held_key_len += 1;
            self.candidates = matched;
            self.depth = @intCast(next_depth);
            if (next_depth == 1) {
                if (self.prefix) |prefix| {
                    self.prefix_pending = keybind.keyOrder(key, prefix) == .eq;
                }
            }
            return .pending;
        }

        /// Returns held keys before paste or another owner interrupts a chord.
        /// Example: `try apply(router.interrupt());`
        pub fn interrupt(self: *Self) Decision {
            self.repeating = null;
            return self.replayBinding();
        }

        /// Host capability replies preserve prefix mode and physical repeats.
        /// Example: `router.observeHostResponse();`
        pub fn observeHostResponse(self: *Self) void {
            if (!self.prefix_pending) {
                self.resetMatch();
                self.binding_since_ns = null;
            }
        }

        /// Drops a partial chord when a semantic pointer action takes ownership.
        /// Example: `router.cancelSequence();`
        pub fn cancelSequence(self: *Self) void {
            self.repeating = null;
            self.resetMatch();
            self.binding_since_ns = null;
        }

        fn replayBinding(self: *Self) Decision {
            if (self.depth == 0) {
                return .discard;
            }
            defer self.resetMatch();
            self.binding_since_ns = null;
            if (self.prefix_pending) {
                return .discard;
            }
            self.transferKeysToApplication(self.held_keys[0..self.held_key_len]);
            var replay: Replay = .{};
            replay.held_key_len = self.held_key_len;
            replay.held_raw_len = self.held_len;
            @memcpy(replay.held_keys[0..self.held_key_len], self.held_keys[0..self.held_key_len]);
            @memcpy(replay.held_raw[0..self.held_len], self.held[0..self.held_len]);
            return .{ .replay = replay };
        }

        fn resetMatch(self: *Self) void {
            self.candidates = .{ .start = 0, .end = self.map.len };
            self.depth = 0;
            self.prefix_pending = false;
            self.held_len = 0;
            self.held_key_len = 0;
        }

        pub fn clear(self: *Self) void {
            self.resetMatch();
            self.input_start = 0;
            self.input_end = 0;
            self.input_since_ns = null;
            self.binding_since_ns = null;
            self.pasting = false;
            self.leases.clear();
            self.repeating = null;
        }

        fn compactInput(self: *Self) void {
            if (self.input_start == 0) {
                return;
            }
            const len = self.input_end - self.input_start;
            std.mem.copyForwards(u8, self.input[0..len], self.input[self.input_start..self.input_end]);
            self.input_start = 0;
            self.input_end = len;
        }
    };
}

fn testRouter() type {
    return Type(routing_tests.Action, routing_tests.limits, void);
}

test "binding admission finds configured direct and chord shortcuts without changing state" {
    const Router = testRouter();
    const Binding = GenericBinding(routing_tests.Action, 4);
    const parse = chord.parseKey;
    const router = try Router.init(&.{
        try Binding.parse(&.{ "ctrl+k", "ctrl+c" }, .next),
        try Binding.parse(&.{"alt+down"}, .next),
        try Binding.parse(&.{"ctrl+p"}, .detach),
    });
    for (0..3) |_| {
        for ([_][]const u8{ "ctrl+p", "ctrl+k", "alt+down" }) |name| {
            try std.testing.expect(router.wantsBinding(try parse(name)));
        }

        for ([_][]const u8{ "p", "k", "down", "ctrl+c", "escape", "ctrl+alt+p" }) |name| {
            try std.testing.expect(!router.wantsBinding(try parse(name)));
        }
    }

    try std.testing.expectEqual(@as(u8, 0), router.depth);
    try std.testing.expectEqual(@as(usize, 0), router.held_len);
    try std.testing.expectEqual(@as(usize, 0), router.leases.count());
    try std.testing.expect(router.bindingDeadline() == null);
    const empty = try Router.init(&.{});
    try std.testing.expect(!empty.wantsBinding(try parse("ctrl+p")));
}

test "binding admission keeps ordinary chord misses with the router until replay" {
    const Router = testRouter();
    const Binding = GenericBinding(routing_tests.Action, 4);
    var router = try Router.init(&.{try Binding.parse(&.{ "a", "b" }, .next)});
    var capture: Capture = .{};
    const first = try chord.parseKey("a");
    const miss = try chord.parseKey("x");
    try std.testing.expect(router.wantsBinding(first));
    _ = try capture.apply(router.routeEvent(.{ .key = first, .raw = "", .now_ns = 1 }, .{}));
    const deadline = router.bindingDeadline();
    try std.testing.expect(router.wantsBinding(try chord.parseKey("b")));
    try std.testing.expect(router.wantsBinding(miss));
    try std.testing.expectEqual(deadline, router.bindingDeadline());
    try std.testing.expectEqual(@as(u8, 1), router.depth);
    try std.testing.expectEqual(@as(usize, 0), capture.key_count);
    _ = try capture.apply(router.routeEvent(.{ .key = miss, .raw = "", .now_ns = 2 }, .{}));
    try std.testing.expectEqual(@as(usize, 2), capture.key_count);
    try std.testing.expectEqualDeep(first, capture.keys[0]);
    try std.testing.expectEqualDeep(miss, capture.keys[1]);
    try std.testing.expect(!router.wantsBinding(miss));
}

test "binding admission resolves persistent prefix misses and Escape without claiming unleased repeats" {
    const Router = testRouter();
    const Binding = GenericBinding(routing_tests.Action, 4);
    const prefix = try chord.parseKey("ctrl+b");
    var router = try Router.initWithPrefix(&.{try Binding.parse(&.{ "ctrl+b", "n" }, .next)}, prefix);
    var capture: Capture = .{};
    for ([_][]const u8{ "x", "escape" }) |name| {
        _ = try capture.apply(router.routeEvent(.{ .key = prefix, .raw = "", .now_ns = 1 }, .{}));
        const press = try chord.parseKey(name);
        try std.testing.expect(router.wantsBinding(press));
        var repeat = press;
        repeat.phase = .repeat;
        repeat.physical = .{ .value = 99 };
        try std.testing.expect(!router.wantsBinding(repeat));
        try std.testing.expect(router.prefixPending());
        _ = try capture.apply(router.routeEvent(.{ .key = press, .raw = "", .now_ns = 2 }, .{}));
        try std.testing.expect(!router.prefixPending());
        try std.testing.expect(!router.wantsBinding(press));
    }

    try std.testing.expectEqual(@as(usize, 0), capture.key_count);
    try std.testing.expectEqual(@as(usize, 0), capture.action_count);
}

test "binding admission retains a physical shortcut through focus and keymap replacement" {
    const Router = testRouter();
    const Binding = GenericBinding(routing_tests.Action, 4);
    var router = try Router.init(&.{try Binding.parse(&.{"ctrl+n"}, .next)});
    var original: Capture = .{};
    var other_focus: Capture = .{};
    var event = try chord.parseKey("ctrl+n");
    event.physical = .{ .value = 42 };
    try std.testing.expect(router.wantsBinding(event));
    _ = try original.apply(router.routeEvent(.{ .key = event, .raw = "", .now_ns = 1 }, .{}));
    router.cancelSequence();
    var replacement = try Router.init(&.{});
    replacement.inheritPhysicalLeases(&router);
    event.mods = .{};
    event.phase = .repeat;
    try std.testing.expect(replacement.wantsBinding(event));
    _ = try other_focus.apply(replacement.routeEvent(.{ .key = event, .raw = "", .now_ns = 2 }, .{}));
    event.phase = .release;
    try std.testing.expect(replacement.wantsBinding(event));
    _ = try other_focus.apply(replacement.routeEvent(.{ .key = event, .raw = "", .now_ns = 3 }, .{}));
    try std.testing.expect(!replacement.wantsBinding(event));
    try std.testing.expectEqual(@as(usize, 1), original.action_count);
    try std.testing.expectEqual(@as(usize, 0), other_focus.action_count);
    try std.testing.expectEqual(@as(usize, 0), other_focus.key_count);
}

test "binding admission cannot steal application repeats or releases when modifiers become a shortcut" {
    const Router = testRouter();
    const Binding = GenericBinding(routing_tests.Action, 4);
    var router = try Router.init(&.{try Binding.parse(&.{"ctrl+n"}, .next)});
    var capture: Capture = .{};
    var event = try chord.parseKey("n");
    event.physical = .{ .value = 42 };
    try std.testing.expect(!router.wantsBinding(event));
    _ = try capture.apply(router.routeEvent(.{ .key = event, .raw = "", .now_ns = 1 }, .{}));
    event.mods.ctrl = true;
    for ([_]Key.Phase{ .repeat, .release }) |phase| {
        event.phase = phase;
        try std.testing.expect(!router.wantsBinding(event));
    }

    event.physical = .{ .value = 43 };
    try std.testing.expect(!router.wantsBinding(event));
    event.physical = null;
    try std.testing.expect(!router.wantsBinding(event));
    event.phase = .repeat;
    try std.testing.expect(!router.wantsBinding(event));
    try std.testing.expectEqual(@as(usize, 1), router.leases.count());
    try std.testing.expectEqual(@as(usize, 1), capture.key_count);
    try std.testing.expectEqual(@as(usize, 0), capture.action_count);
}

test "replayed chord keys can return their physical ownership to the original widget" {
    const Router = testRouter();
    const Binding = GenericBinding(routing_tests.Action, 4);
    var router = try Router.init(&.{try Binding.parse(&.{ "a", "b" }, .next)});
    var capture: Capture = .{};
    var first = try chord.parseKey("a");
    first.physical = .{ .value = 1 };
    var miss = try chord.parseKey("x");
    miss.physical = .{ .value = 2 };
    _ = try capture.apply(router.routeEvent(.{ .key = first, .raw = "", .now_ns = 1 }, .{}));
    _ = try capture.apply(router.routeEvent(.{ .key = miss, .raw = "", .now_ns = 2 }, .{}));
    try std.testing.expectEqual(@as(usize, 2), capture.key_count);
    router.relinquishKey(first.physical.?);
    router.relinquishKey(miss.physical.?);
    try std.testing.expectEqual(@as(usize, 0), router.leases.count());
    // Stale routing cannot forward these lifecycles to a newly focused owner.
    var other_focus: Capture = .{};
    first.phase = .repeat;
    _ = try other_focus.apply(router.routeEvent(.{ .key = first, .raw = "", .now_ns = 3 }, .{}));
    miss.phase = .release;
    _ = try other_focus.apply(router.routeEvent(.{ .key = miss, .raw = "", .now_ns = 4 }, .{}));
    try std.testing.expectEqual(@as(usize, 0), other_focus.key_count);
    try std.testing.expectEqual(@as(usize, 0), other_focus.action_count);
}

test "relinquishing a physical key preserves another shortcut repeat and cancels its own" {
    const Router = testRouter();
    const Binding = GenericBinding(routing_tests.Action, 4);
    var router = try Router.init(&.{try Binding.parse(&.{"ctrl+n"}, .next)});
    var capture: Capture = .{};
    var event = try chord.parseKey("ctrl+n");
    event.physical = .{ .value = 42 };
    _ = try capture.apply(router.routeEvent(.{ .key = event, .raw = "", .now_ns = 1 }, .{}));
    router.repeating = .{ .key = event, .action = .next, .policy = .{ .interval_ns = 1, .context = 9 }, .last_ns = 1 };
    router.relinquishKey(.{ .value = 99 });
    try std.testing.expect(router.repeating != null);
    try std.testing.expectEqual(@as(usize, 1), router.leases.count());
    router.relinquishKey(event.physical.?);
    try std.testing.expect(router.repeating == null);
    try std.testing.expectEqual(@as(usize, 0), router.leases.count());
    event.phase = .repeat;
    try std.testing.expect(!router.wantsBinding(event));
    router.relinquishKey(event.physical.?);
    try std.testing.expectEqual(@as(usize, 0), router.leases.count());
}
