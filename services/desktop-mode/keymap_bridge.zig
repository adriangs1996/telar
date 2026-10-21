//! C ABI for the same bounded key router used by the GUI and headless client.
const std = @import("std");
const keyinput = @import("keyinput");
const Router = keyinput.GenericRouter(u64, .{
    .max_bindings = 256,
    .max_keys = 5,
    .max_physical_leases = 64,
    .sequence_timeout_ns = 0,
});
const Binding = keyinput.GenericBinding(u64, 5);

const NativeBinding = extern struct {
    keys: [5][*:0]const u8,
    count: usize,
    action: u64,
};

const NativeKey = extern struct {
    chord: [*:0]const u8,
    physical: u32,
    phase: u32,
};

export fn telar_keymap_create() ?*Router {
    const router = std.heap.c_allocator.create(Router) catch return null;
    router.* = Router.init(&.{}) catch unreachable;
    return router;
}

export fn telar_keymap_destroy(router: *Router) void {
    std.heap.c_allocator.destroy(router);
}

fn configure(router: *Router, prefix_text: [*:0]const u8, bindings: []const NativeBinding) !void {
    if (bindings.len > 256) {
        return error.TooManyBindings;
    }

    const prefix = try keyinput.chord.parseKey(std.mem.span(prefix_text));
    if (!prefix.mods.ctrl and !prefix.mods.alt and !prefix.mods.super) {
        return error.PrefixRequiresModifier;
    }

    var parsed: [256]Binding = undefined;
    for (bindings, 0..) |binding, index| {
        if (binding.count == 0 or binding.count > 5 or binding.action == 0) {
            return error.InvalidBinding;
        }

        var keys: [5]keyinput.Key = undefined;
        for (binding.keys[0..binding.count], 0..) |text, key_index| {
            keys[key_index] = try keyinput.chord.parseKey(std.mem.span(text));
        }

        // Unprefixed shortcuts are single chords. Arbitrary global sequences
        // would require replaying intercepted events into a foreign application.
        const prefixed = keyinput.keybind.keyOrder(keys[0], prefix) == .eq;
        if (prefixed and binding.count == 1) {
            return error.PrefixNeedsSuffix;
        }
        if (!prefixed and (binding.count != 1 or (!keys[0].mods.ctrl and !keys[0].mods.alt and !keys[0].mods.super))) {
            return error.GlobalShortcutRequiresModifiedChord;
        }

        parsed[index] = try Binding.init(keys[0..binding.count], binding.action);
    }

    var replacement = try Router.initWithPrefix(parsed[0..bindings.len], prefix);
    replacement.inheritPhysicalLeases(router);
    router.* = replacement;
}

export fn telar_keymap_configure(router: *Router, prefix: [*:0]const u8, bindings: [*]const NativeBinding, count: usize) ?[*:0]const u8 {
    configure(router, prefix, bindings[0..count]) catch |err| return @errorName(err);
    return null;
}

export fn telar_keymap_route(router: *Router, native: *const NativeKey, action: *u64) bool {
    action.* = 0;
    const phase = std.enums.fromInt(keyinput.Key.Phase, native.phase) orelse return false;
    // An unrepresentable key still cancels a pending prefix, just as an invalid suffix does.
    var key = keyinput.chord.parseKey(std.mem.span(native.chord)) catch keyinput.Key.plain(.escape);
    key.phase = phase;
    key.physical = .{ .value = native.physical };

    if (!router.wantsBinding(key)) {
        if (phase == .press) {
            router.relinquishKey(.{ .value = native.physical });
        }

        return false;
    }

    const decision = router.routeEvent(.{ .key = key, .now_ns = 0 }, .{});
    switch (decision) {
        .action => |request| action.* = request.value,
        .forward, .replay => return false,
        .pending, .discard => {},
    }

    return true;
}

export fn telar_keymap_pending(router: *const Router) bool {
    return router.prefixPending();
}

export fn telar_keymap_cancel(router: *Router) void {
    router.cancelSequence();
}
