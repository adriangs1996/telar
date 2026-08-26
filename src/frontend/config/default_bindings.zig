//! Built-in keymap, kept declarative and separate from input dispatch.

const input = @import("../input/root.zig");
const action = input.action;
const config_model = @import("model.zig");
const keybind = input.keybind;

pub const max_keys = config_model.max_binding_keys;
pub const count = 34;
pub const Binding = keybind.Binding(action.Action, max_keys);

pub const Resolved = struct {
    bindings: [config_model.max_bindings]Binding = undefined,
    len: u16 = 0,

    pub fn slice(resolved: *const Resolved) []const Binding {
        return resolved.bindings[0..resolved.len];
    }
};

pub fn load(prefix: keybind.Key) ![count]Binding {
    return .{
        try prefixed(prefix, "%", .{ .split_pane = .horizontal }),
        try prefixed(prefix, "\"", .{ .split_pane = .vertical }),
        try prefixed(prefix, "left", .{ .focus_pane = .left }),
        try prefixed(prefix, "right", .{ .focus_pane = .right }),
        try prefixed(prefix, "up", .{ .focus_pane = .up }),
        try prefixed(prefix, "down", .{ .focus_pane = .down }),
        try prefixed(prefix, "shift+left", .{ .resize_pane = .left }),
        try prefixed(prefix, "shift+right", .{ .resize_pane = .right }),
        try prefixed(prefix, "shift+up", .{ .resize_pane = .up }),
        try prefixed(prefix, "shift+down", .{ .resize_pane = .down }),
        try prefixed(prefix, "z", .toggle_pane_fullscreen),
        try prefixed(prefix, "s", .toggle_sidebar),
        try prefixed(prefix, "w", .toggle_workspace_list),
        try prefixed(prefix, "N", .new_workspace),
        try prefixed(prefix, "W", .rename_workspace),
        try prefixed(prefix, "x", .close_pane),
        try prefixed(prefix, "d", .detach),
        try prefixed(prefix, "[", .enter_copy_mode),
        try prefixed(prefix, "c", .new_tab),
        try prefixed(prefix, "n", .{ .select_tab_offset = 1 }),
        try prefixed(prefix, "p", .{ .select_tab_offset = -1 }),
        try prefixed(prefix, "1", .{ .select_tab = 0 }),
        try prefixed(prefix, "2", .{ .select_tab = 1 }),
        try prefixed(prefix, "3", .{ .select_tab = 2 }),
        try prefixed(prefix, "4", .{ .select_tab = 3 }),
        try prefixed(prefix, "5", .{ .select_tab = 4 }),
        try prefixed(prefix, "6", .{ .select_tab = 5 }),
        try prefixed(prefix, "7", .{ .select_tab = 6 }),
        try prefixed(prefix, "8", .{ .select_tab = 7 }),
        try prefixed(prefix, "9", .{ .select_tab = 8 }),
        try prefixed(prefix, "T", .rename_tab),
        try prefixed(prefix, "X", .close_tab),
        try prefixed(prefix, ",", .{ .move_tab = .previous }),
        try prefixed(prefix, ".", .{ .move_tab = .next }),
    };
}

/// Builds the effective keymap. Explicit bindings keep their order and
/// replace every default they conflict with — same sequence, or one a prefix
/// of the other. Dropping prefix conflicts too keeps the merged keymap free
/// of the ambiguity the router rejects; every other default is appended.
pub fn resolve(prefix: keybind.Key, configured: []const Binding) !Resolved {
    if (configured.len > config_model.max_bindings) return error.TooManyBindings;

    var resolved: Resolved = .{};
    @memcpy(resolved.bindings[0..configured.len], configured);
    resolved.len = @intCast(configured.len);

    const defaults = try load(prefix);
    for (&defaults) |*default| {
        var overridden = false;
        for (configured) |*binding| {
            if (binding.conflictsWith(default)) {
                overridden = true;
                break;
            }
        }
        if (overridden) continue;
        if (resolved.len == config_model.max_bindings) return error.TooManyBindings;
        resolved.bindings[resolved.len] = default.*;
        resolved.len += 1;
    }

    return resolved;
}

/// Proves the merged keymap compiles with the same parameters the client's
/// router uses. `telar config check` calls this so a merge that the router
/// would reject fails here instead of at interactive startup.
pub fn validate(prefix: keybind.Key, configured: []const Binding) !void {
    const resolved = try resolve(prefix, configured);
    _ = try keybind.Keymap(action.Action, config_model.max_bindings, max_keys)
        .init(resolved.slice());
}

fn prefixed(prefix: keybind.Key, suffix: []const u8, action_value: action.Action) !Binding {
    return .init(&.{ prefix, try keybind.parseKey(suffix) }, action_value);
}

test "configured bindings extend defaults and override matching sequences" {
    const testing = @import("std").testing;
    const prefix = try keybind.parseKey("ctrl+s");
    const override = try prefixed(prefix, "s", .detach);
    const global = try Binding.parse(&.{"ctrl+d"}, .detach);

    const resolved = try resolve(prefix, &.{ override, global });

    try testing.expectEqual(@as(usize, count + 1), resolved.slice().len);
    try testing.expect(resolved.bindings[0].sameSequence(&override));
    try testing.expectEqualDeep(action.Action.detach, resolved.bindings[0].action);
    try testing.expect(resolved.bindings[1].sameSequence(&global));

    var matching_defaults: usize = 0;
    for (resolved.slice()) |*binding| {
        if (binding.sameSequence(&override)) matching_defaults += 1;
    }
    try testing.expectEqual(@as(usize, 1), matching_defaults);
}

test "a configured binding evicts every default it prefix-conflicts with" {
    const testing = @import("std").testing;
    const prefix = try keybind.parseKey("ctrl+b");
    // Extends the default `<prefix> s` (toggle_sidebar) by one key. The
    // default must be dropped, or the merged keymap is prefix-ambiguous.
    const extended = try Binding.init(
        &.{ prefix, try keybind.parseKey("s"), try keybind.parseKey("x") },
        .detach,
    );
    const shadowed = try prefixed(prefix, "s", .toggle_sidebar);

    const resolved = try resolve(prefix, &.{extended});

    try testing.expectEqual(@as(usize, count), resolved.slice().len);
    for (resolved.slice()) |*binding| {
        try testing.expect(!binding.sameSequence(&shadowed));
    }
    try validate(prefix, &.{extended});
}

test "validating rejects configured bindings that conflict with each other" {
    const testing = @import("std").testing;
    const prefix = try keybind.parseKey("ctrl+b");
    const short = try prefixed(prefix, "g", .toggle_sidebar);
    const long = try Binding.init(
        &.{ prefix, try keybind.parseKey("g"), try keybind.parseKey("x") },
        .detach,
    );

    try testing.expectError(error.AmbiguousBindingPrefix, validate(prefix, &.{ short, long }));
}

test "resolving bindings enforces the router capacity" {
    const testing = @import("std").testing;
    const prefix = try keybind.parseKey("ctrl+s");
    const configured = try Binding.parse(&.{"ctrl+d"}, .detach);
    const bindings: [config_model.max_bindings]Binding = @splat(configured);

    try testing.expectError(error.TooManyBindings, resolve(prefix, &bindings));
}
