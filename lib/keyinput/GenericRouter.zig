const GenericBinding = @import("GenericBinding.zig").Type;
const GenericTable = @import("GenericTable.zig").Type;
const Key = @import("Key.zig");
const RepeatPolicy = @import("RepeatPolicy.zig");
const RouterLimits = @import("RouterLimits.zig");
const keybind = @import("keybind.zig");
const GenericKeymap = @import("GenericKeymap.zig").Type;
const std = @import("std");

pub fn Type(comptime Action: type, comptime limits: RouterLimits) type {
    const max_bindings = limits.max_bindings;
    const max_keys = limits.max_keys;
    const Map = GenericKeymap(Action, max_bindings, max_keys);
    const BindingType = GenericBinding(Action, max_keys);
    const LeaseOwner = enum { binding, application };
    const Leases = GenericTable(LeaseOwner, limits.max_physical_leases);
    return struct {
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
            // SAFETY: Replay construction copies held_key_len keys before returning the decision; consumers replay only that prefix.
            held_keys: [max_keys]Key = undefined,
            held_key_len: u8 = 0,
            current_key: ?Key = null,
        };

        pub const Decision = union(enum) {
            forward: Key,
            replay: Replay,
            action: ActionRequest,
            pending,
            discard,
        };

        map: Map,
        prefix: ?Key = null,
        candidates: Map.Range = .{ .start = 0, .end = 0 },
        depth: u8 = 0,
        prefix_pending: bool = false,
        // SAFETY: The router stores each held key before increasing held_key_len; replay and lease transfer use only that prefix.
        held_keys: [max_keys]Key = undefined,
        held_key_len: u8 = 0,
        binding_since_ns: ?u64 = null,
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

        pub fn bindingDeadline(self: *const Self) ?u64 {
            if (self.prefix_pending) {
                return null;
            }
            const since = self.binding_since_ns orelse return null;
            return since +| self.sequence_timeout_ns;
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
                        return .{ .forward = input.key };
                    },
                    .release => {
                        if (self.releasePhysicalKey(identity) != .application) {
                            return .discard;
                        }
                        return .{ .forward = input.key };
                    },
                }
            }

            if (context.captures_keys) {
                const previous = self.replayBinding();
                self.transferKeyToApplication(input.key);
                if (previous == .replay) {
                    var replay = previous.replay;
                    replay.current_key = input.key;
                    return .{ .replay = replay };
                }
                return .{ .forward = input.key };
            }

            const was_pending = self.depth != 0;
            const routed = self.routeKey(input);
            switch (routed) {
                .forward => |forwarded| self.transferKeyToApplication(forwarded),
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
                    return .{ .forward = key };
                }
                if (self.prefix_pending) {
                    self.resetMatch();
                    return .discard;
                }
                var replay: Replay = .{
                    .held_key_len = self.held_key_len,
                    .current_key = key,
                };
                @memcpy(replay.held_keys[0..self.held_key_len], self.held_keys[0..self.held_key_len]);
                self.resetMatch();
                return .{ .replay = replay };
            };

            const next_depth: usize = self.depth + 1;
            const first = self.map.bindingAt(matched.start);
            if (first.len == next_depth) {
                const action = first.action;
                self.resetMatch();
                return .{ .action = .{ .value = action, .key = key, .now_ns = input.now_ns } };
            }

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
            @memcpy(replay.held_keys[0..self.held_key_len], self.held_keys[0..self.held_key_len]);
            return .{ .replay = replay };
        }

        fn resetMatch(self: *Self) void {
            self.candidates = .{ .start = 0, .end = self.map.len };
            self.depth = 0;
            self.prefix_pending = false;
            self.held_key_len = 0;
        }

        pub fn clear(self: *Self) void {
            self.resetMatch();
            self.binding_since_ns = null;
            self.leases.clear();
            self.repeating = null;
        }
    };
}
