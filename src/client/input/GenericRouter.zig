const RouterLimits = @import("RouterLimits.zig");
const GenericKeymap = @import("GenericKeymap.zig").Type;
const GenericBinding = @import("GenericBinding.zig").Type;
const GenericTable = @import("GenericTable.zig").Type;
const keybind = @import("keybind.zig");
const Key = @import("Key.zig");
const RepeatPolicy = @import("RepeatPolicy.zig");
const std = @import("std");

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
    const Leases = GenericTable(LeaseOwner, keybind.max_physical_leases);
    return struct {
        pub const Feed = struct {
            bytes: []const u8,
            now_ns: u64,
        };

        const Drain = struct {
            now_ns: u64,
            force_escape: bool,
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
        output: [input_capacity + held_capacity]u8 = undefined,
        output_len: usize = 0,
        pasting: bool = false,
        escape_timeout_ns: u64 = keybind.default_escape_timeout_ns,
        sequence_timeout_ns: u64 = keybind.default_sequence_timeout_ns,
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

        pub fn prefixPending(router: *const Self) bool {
            return router.prefix_pending;
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
        pub fn inheritPhysicalLeases(router: *Self, previous: *const Self) void {
            router.leases = previous.leases;
            router.repeating = null;
        }

        /// Returns how many physical presses were dropped because the bounded
        /// lease table was saturated.
        ///
        /// ```zig
        /// const dropped = router.leaseOverflowCount();
        /// ```
        pub fn leaseOverflowCount(router: *const Self) u64 {
            return router.leases.overflowCount();
        }

        /// Returns the configured one-key suffix for a prefixed action. The
        /// client uses this to render help from the effective keymap instead
        /// of repeating default binding labels in the UI.
        pub fn prefixedKeyForAction(router: *const Self, action: Action) ?Key {
            const prefix = router.prefix orelse return null;
            for (router.map.bindings[0..router.map.len]) |*binding| {
                if (binding.len != 2 or keybind.keyOrder(binding.keys[0], prefix) != .eq) {
                    continue;
                }
                if (std.meta.eql(binding.action, action)) {
                    return binding.keys[1];
                }
            }
            return null;
        }

        /// Feeds host-terminal bytes through the compiled keymap.
        ///
        /// `handler.forward(bytes)` must finish using `bytes` before returning.
        /// `handler.action(action)` returns `.stop` when the action ends input
        /// processing, for example after detaching the client. An optional
        /// `handler.repeatPolicy(action)` opts into paced physical repeats.
        /// It must return null when the action or its current owner is unavailable.
        /// Repeats retain the matched action, never re-enter sequence matching,
        /// and schedule no timers or catch-up work.
        /// For example: `const control = try router.feed(.{ .bytes = input, .now_ns = now }, handler);`.
        pub fn feed(router: *Self, input: Feed, handler: anytype) !keybind.Control {
            const bytes = input.bytes;
            const now_ns = input.now_ns;
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
                if (try router.drain(.{ .now_ns = now_ns, .force_escape = false }, handler) == .stop) {
                    return .stop;
                }
            }
            try router.flushOutput(handler);
            return .continue_routing;
        }

        pub fn inputDeadline(router: *const Self) ?u64 {
            const since = router.input_since_ns orelse return null;
            return since +| router.escape_timeout_ns;
        }

        pub fn bindingDeadline(router: *const Self) ?u64 {
            if (router.prefix_pending) {
                return null;
            }
            const since = router.binding_since_ns orelse return null;
            return since +| router.sequence_timeout_ns;
        }

        pub fn expireInput(router: *Self, now_ns: u64, handler: anytype) !keybind.Control {
            const deadline = router.inputDeadline() orelse return .continue_routing;
            if (now_ns < deadline) {
                return .continue_routing;
            }

            const pending = router.input[router.input_start..router.input_end];
            if (pending.len == 1 and pending[0] == 0x1b) {
                if (try router.drain(.{ .now_ns = now_ns, .force_escape = true }, handler) == .stop) {
                    return .stop;
                }
            } else {
                try router.replayBinding(handler);
                if (comptime !@hasDecl(@TypeOf(handler.*), "key")) {
                    try router.appendOutput(pending, handler);
                }
                router.input_start = 0;
                router.input_end = 0;
                router.input_since_ns = null;
            }
            try router.flushOutput(handler);
            return .continue_routing;
        }

        pub fn expireBinding(router: *Self, now_ns: u64, handler: anytype) !keybind.Control {
            const deadline = router.bindingDeadline() orelse return .continue_routing;
            if (now_ns < deadline) {
                return .continue_routing;
            }
            try router.replayBinding(handler);
            try router.flushOutput(handler);
            return .continue_routing;
        }

        fn drain(router: *Self, input: Drain, handler: anytype) !keybind.Control {
            while (router.input_start < router.input_end) {
                const pending = router.input[router.input_start..router.input_end];
                if (!input.force_escape and pending.len == 1 and pending[0] == 0x1b) {
                    if (router.input_since_ns == null) {
                        router.input_since_ns = input.now_ns;
                    }
                    break;
                }

                const parsed = term.parse(pending) orelse break;
                if (parsed.len == 0) {
                    if (router.input_since_ns == null) {
                        router.input_since_ns = input.now_ns;
                    }
                    break;
                }

                router.input_since_ns = null;
                const raw = pending[0..parsed.len];
                if (router.pasting and std.meta.activeTag(parsed.event) != .paste_end) {
                    try router.flushOutput(handler);
                    if (comptime @hasDecl(@TypeOf(handler.*), "pasteContent")) {
                        try handler.pasteContent(raw);
                    } else {
                        try router.appendOutput(raw, handler);
                    }
                    router.input_start += parsed.len;
                    continue;
                }
                switch (parsed.event) {
                    .key => |key| {
                        const control = try router.routeEvent(.{
                            .key = key,
                            .raw = raw,
                            .now_ns = input.now_ns,
                        }, handler);
                        router.input_start += parsed.len;
                        if (control == .stop) {
                            router.clear();

                            return .stop;
                        }

                        continue;
                    },
                    .mouse => |mouse| {
                        router.repeating = null;
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
                        // Capability replies are asynchronous host protocol,
                        // not user input. They cannot kick the user out of a
                        // persistent prefix mode that is waiting for a key.
                        if (!router.prefix_pending) {
                            router.resetMatch();
                            router.binding_since_ns = null;
                        }
                        try router.flushOutput(handler);
                        if (comptime @hasDecl(@TypeOf(handler.*), "terminalResponse")) {
                            try handler.terminalResponse(response);
                        }
                    },
                    .paste_start => {
                        router.repeating = null;
                        try router.replayBinding(handler);
                        try router.flushOutput(handler);
                        router.pasting = true;
                        if (comptime @hasDecl(@TypeOf(handler.*), "pasteStart")) {
                            try handler.pasteStart();
                        } else {
                            try router.appendOutput(raw, handler);
                        }
                    },
                    .paste_end => {
                        try router.replayBinding(handler);
                        try router.flushOutput(handler);
                        router.pasting = false;
                        if (comptime @hasDecl(@TypeOf(handler.*), "pasteEnd")) {
                            try handler.pasteEnd();
                        } else {
                            try router.appendOutput(raw, handler);
                        }
                    },
                    .incomplete => {
                        try router.replayBinding(handler);
                        if (comptime !@hasDecl(@TypeOf(handler.*), "key")) {
                            try router.appendOutput(raw, handler);
                        }
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

        pub const KeyInput = struct {
            key: Key,
            raw: []const u8,
            now_ns: u64,
        };

        /// Routes a decoded press, repeat or release using the same key ownership.
        /// Example: `_ = try router.routeEvent(.{ .key = key, .raw = "", .now_ns = now }, handler);`.
        pub fn routeEvent(router: *Self, input: KeyInput, handler: anytype) !keybind.Control {
            if (input.key.phase == .press) {
                router.repeating = null;
            }

            const identity = input.key.physical orelse return router.handleKeyPress(input, handler);

            switch (input.key.phase) {
                .press => {
                    if (!router.leases.acquire(identity, .binding)) {
                        return .continue_routing;
                    }
                    errdefer _ = router.leases.release(identity);

                    return router.handleKeyPress(input, handler);
                },
                .repeat => {
                    if (router.leases.owner(identity) == .binding) {
                        return router.repeatBinding(input, handler);
                    }

                    if (router.leases.owner(identity) != .application) {
                        return .continue_routing;
                    }

                    try router.deliverApplicationKey(input, handler);

                    return .continue_routing;
                },
                .release => {
                    if (router.repeating) |held| {
                        if (held.key.physical.?.eql(identity)) {
                            router.repeating = null;
                        }
                    }

                    if (router.leases.release(identity) != .application) {
                        return .continue_routing;
                    }

                    try router.deliverApplicationKey(input, handler);

                    return .continue_routing;
                },
            }
        }

        fn handleKeyPress(router: *Self, input: KeyInput, handler: anytype) !keybind.Control {
            if (comptime @hasDecl(@TypeOf(handler.*), "capturesKeys")) {
                if (handler.capturesKeys()) {
                    try router.replayBinding(handler);
                    router.transferKeyToApplication(input.key);
                    try router.deliverApplicationKey(input, handler);

                    return .continue_routing;
                }
            }

            const was_pending = router.depth != 0;
            switch (router.routeKey(input.key, input.raw)) {
                .forward => |forwarded| {
                    router.transferKeyToApplication(forwarded.key);
                    try router.deliverApplicationKey(.{
                        .key = forwarded.key,
                        .raw = forwarded.raw,
                        .now_ns = input.now_ns,
                    }, handler);
                },
                .replay => |replay| {
                    router.transferKeysToApplication(replay.held_keys[0..replay.held_key_len]);
                    router.transferKeyToApplication(replay.current_key);
                    if (comptime @hasDecl(@TypeOf(handler.*), "key")) {
                        try router.flushOutput(handler);
                        for (replay.held_keys[0..replay.held_key_len]) |held_key| {
                            try handler.key(held_key);
                        }
                        try handler.key(replay.current_key);
                    } else {
                        try router.appendOutput(replay.held_raw[0..replay.held_raw_len], handler);
                        try router.appendOutput(replay.current_raw, handler);
                    }
                },
                .pending => {
                    if (!was_pending and !router.prefix_pending) {
                        router.binding_since_ns = input.now_ns;
                    }
                },
                .discard => {
                    router.binding_since_ns = null;
                },
                .action => |action| {
                    router.binding_since_ns = null;
                    try router.flushOutput(handler);

                    const control = try handler.action(action);
                    if (comptime @hasDecl(@TypeOf(handler.*), "repeatPolicy")) {
                        if (control == .continue_routing and input.key.physical != null) {
                            if (handler.repeatPolicy(action)) |policy| {
                                std.debug.assert(policy.interval_ns != 0);
                                router.repeating = .{
                                    .key = input.key,
                                    .action = action,
                                    .policy = policy,
                                    .last_ns = input.now_ns,
                                };
                            }
                        }
                    }

                    return control;
                },
            }
            if (router.depth == 0) {
                router.binding_since_ns = null;
            }

            return .continue_routing;
        }

        fn repeatBinding(router: *Self, input: KeyInput, handler: anytype) !keybind.Control {
            if (comptime !@hasDecl(@TypeOf(handler.*), "repeatPolicy")) {
                return .continue_routing;
            } else {
                const held = router.repeating orelse return .continue_routing;
                if (!held.key.physical.?.eql(input.key.physical.?)) {
                    return .continue_routing;
                }

                const policy = handler.repeatPolicy(held.action);
                if (keybind.keyOrder(held.key, input.key) != .eq or !std.meta.eql(policy, @as(?RepeatPolicy, held.policy))) {
                    router.repeating = null;

                    return .continue_routing;
                }

                if (input.now_ns -| held.last_ns < held.policy.interval_ns) {
                    return .continue_routing;
                }

                // Late and batched repeats produce one step, not a replay of
                // every interval missed while the client was busy.
                router.repeating.?.last_ns = input.now_ns;
                errdefer router.repeating = null;
                try router.flushOutput(handler);

                return handler.action(held.action);
            }
        }

        fn deliverApplicationKey(router: *Self, input: KeyInput, handler: anytype) !void {
            if (comptime @hasDecl(@TypeOf(handler.*), "key")) {
                try router.flushOutput(handler);
                try handler.key(input.key);
            } else {
                try router.appendOutput(input.raw, handler);
            }
        }

        fn transferKeyToApplication(router: *Self, key_value: Key) void {
            const identity = key_value.physical orelse return;
            if (router.leases.owner(identity) == null) {
                return;
            }

            const transferred = router.leases.acquire(identity, .application);
            std.debug.assert(transferred);
        }

        fn transferKeysToApplication(router: *Self, keys: []const Key) void {
            for (keys) |key_value| {
                router.transferKeyToApplication(key_value);
            }
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
            discard,
            pending,
            action: Action,
        };

        fn routeKey(router: *Self, key: Key, raw: []const u8) Routed {
            if (router.prefix_pending and keybind.isPlainEscape(key)) {
                router.resetMatch();
                return .discard;
            }
            const range = if (router.depth == 0)
                Map.Range{ .start = 0, .end = router.map.len }
            else
                router.candidates;
            const matched = router.map.matchingRange(range, .{ .depth = router.depth, .key = key }) orelse {
                if (router.depth == 0) {
                    return .{ .forward = .{ .key = key, .raw = raw } };
                }
                if (router.prefix_pending) {
                    router.resetMatch();
                    return .discard;
                }
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
            if (next_depth == 1) {
                if (router.prefix) |prefix| {
                    router.prefix_pending = keybind.keyOrder(key, prefix) == .eq;
                }
            }
            return .pending;
        }

        fn replayBinding(router: *Self, handler: anytype) !void {
            if (router.depth == 0) {
                return;
            }
            if (router.prefix_pending) {
                router.resetMatch();
                router.binding_since_ns = null;
                return;
            }
            router.transferKeysToApplication(router.held_keys[0..router.held_key_len]);
            if (comptime @hasDecl(@TypeOf(handler.*), "key")) {
                try router.flushOutput(handler);
                for (router.held_keys[0..router.held_key_len]) |held_key| {
                    try handler.key(held_key);
                }
            } else {
                try router.appendOutput(router.held[0..router.held_len], handler);
            }
            router.resetMatch();
            router.binding_since_ns = null;
        }

        fn resetMatch(router: *Self) void {
            router.candidates = .{ .start = 0, .end = router.map.len };
            router.depth = 0;
            router.prefix_pending = false;
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
            router.leases.clear();
            router.repeating = null;
        }

        fn appendOutput(router: *Self, bytes: []const u8, handler: anytype) !void {
            if (bytes.len > router.output.len) {
                try router.flushOutput(handler);
                try handler.forward(bytes);
                return;
            }
            if (router.output_len + bytes.len > router.output.len) {
                try router.flushOutput(handler);
            }
            @memcpy(router.output[router.output_len..][0..bytes.len], bytes);
            router.output_len += bytes.len;
        }

        fn flushOutput(router: *Self, handler: anytype) !void {
            if (router.output_len == 0) {
                return;
            }
            try handler.forward(router.output[0..router.output_len]);
            router.output_len = 0;
        }

        fn compactInput(router: *Self) void {
            if (router.input_start == 0) {
                return;
            }
            const len = router.input_end - router.input_start;
            std.mem.copyForwards(u8, router.input[0..len], router.input[router.input_start..router.input_end]);
            router.input_start = 0;
            router.input_end = len;
        }

        fn recoverFullInput(router: *Self, handler: anytype) !void {
            try router.replayBinding(handler);
            if (comptime !@hasDecl(@TypeOf(handler.*), "key")) {
                try router.appendOutput(router.input[router.input_start..router.input_end], handler);
            }
            router.input_start = 0;
            router.input_end = 0;
            router.input_since_ns = null;
            try router.flushOutput(handler);
        }
    };
}
