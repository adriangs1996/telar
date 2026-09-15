//! Client-owned input routing over the last successfully delivered targets.
//! The compositor may prepare new targets while input retains the visible
//! ones. Gesture and physical-key leases keep their owner across focus changes.
const std = @import("std");
const client = @import("telar-client");
const Event = @import("../../input/event.zig").Event;
const Key = @import("../../input/KeyInput.zig");
const Pointer = @import("../../input/PointerEvent.zig");
const Id = @import("Id.zig");
const Target = @import("Target.zig");
const Registry = @import("Registry.zig");
const Route = @import("Route.zig");
const Owner = @import("key_owner.zig").Owner;
const GenericPresentedState = @import("../../render/GenericPresentedState.zig").Type;
const GenericTable = client.GenericTable;
const Dispatcher = @This();

maps: GenericPresentedState(Registry) = .{},
focused: ?Id = null,
hovered: ?Id = null,
captures: [3]?Id = @splat(null),
/// Retired captures still consume their eventual release.
discarded: [3]bool = @splat(false),
keys: GenericTable(Owner, client.max_physical_leases) = .{},
revision: u64 = 0,
window_focused: bool = true,
next_id: u64 = 1,
overflowed: bool = false,

/// Begins a replacement registry without changing input authority.
/// Example: `const targets = dispatcher.begin();`
pub fn begin(dispatcher: *Dispatcher) *Registry {
    return dispatcher.maps.begin();
}

/// Assigns collision-free IDs by owned semantic identity, retaining an ID
/// across reordered frames. A generation change or disappearance retires it.
/// Example: `const id = try dispatcher.add(.{ .bounds = bounds, .action = action });`
pub fn add(dispatcher: *Dispatcher, value: Target) !Id {
    var target = value;
    if (target.id.target_id == 0) {
        for (dispatcher.maps.presented().targets[0..dispatcher.maps.presented().len]) |previous| {
            if (previous.namespace == target.namespace and previous.id.generation == target.id.generation and std.meta.eql(previous.action, target.action)) {
                target.id = previous.id;
                break;
            }
        }

        if (target.id.target_id == 0) {
            target.id.target_id = dispatcher.next_id;
            dispatcher.next_id = std.math.add(u64, dispatcher.next_id, 1) catch return error.WidgetIdentityExhausted;
        }
    }

    try dispatcher.maps.preparing().add(target);
    return target.id;
}

/// Example: `dispatcher.seal();`
pub fn seal(dispatcher: *Dispatcher) void {
    dispatcher.maps.seal();
}

/// Publishes only after the matching frame succeeded. A retired target loses
/// focus and its captured gestures become sinks until their releases arrive.
/// Example: `dispatcher.present(delivered);`
pub fn present(dispatcher: *Dispatcher, delivered: bool) void {
    const changed = delivered and dispatcher.maps.sealed and !dispatcher.maps.presented().equivalent(dispatcher.maps.prepared());
    dispatcher.maps.present(delivered);
    if (!delivered) {
        return;
    }

    const registry = dispatcher.maps.presented();
    if (changed) {
        dispatcher.revision +%= 1;
    }
    if (dispatcher.focused) |id| {
        const target = registry.find(id);
        if (target == null or target.?.layer < registry.modal_layer or !target.?.enabled) {
            dispatcher.assignFocus(null);
        }
    }

    for (&dispatcher.captures, &dispatcher.discarded) |*capture, *discarded| {
        if (capture.*) |id| {
            const target = registry.find(id);
            if (target == null or !target.?.enabled or target.?.layer < registry.modal_layer) {
                capture.* = null;
                discarded.* = true;
            }
        }
    }

    for (dispatcher.keys.entries[0..dispatcher.keys.len]) |entry| {
        if (entry.owner == .widget) {
            const target = registry.find(entry.owner.widget);
            if (target == null or !target.?.enabled or target.?.layer < registry.modal_layer) {
                _ = dispatcher.keys.acquire(entry.identity, .discarded);
            }
        }
    }

    if (dispatcher.focused == null and registry.modal_layer != 0) {
        _ = dispatcher.traverse(false);
    }
}

/// Chooses a delivered owner; false leaves terminal routing intact. Text,
/// paste and IME use focused ownership, never hover. Call only on the client
/// thread after native admission copied its borrowed bytes.
/// Example: `const routed = dispatcher.route(event);`
pub fn route(dispatcher: *Dispatcher, event: Event) Route {
    return switch (event) {
        .key => |value| dispatcher.key(value),
        .text => |value| if (value.physical != null) dispatcher.textKey(value) else dispatcher.text(),
        .pointer => |value| dispatcher.pointer(value),
        .scroll => |scroll| .{ .consumed = dispatcher.maps.presented().at(.{ scroll.x, scroll.y }) != null or dispatcher.maps.presented().modal_layer != 0, .target = dispatcher.maps.presented().at(.{ scroll.x, scroll.y }) },
        .focus => |focused| blk: {
            dispatcher.window_focused = focused;
            if (!focused) {
                dispatcher.cancel();
            }

            break :blk .{};
        },
        else => dispatcher.text(),
    };
}

/// Explicit focus requests are checked against delivered geometry and scope.
/// Example: `const changed = dispatcher.focus(field_id);`
pub fn focus(dispatcher: *Dispatcher, id: ?Id) bool {
    if (id) |value| {
        const target = dispatcher.maps.presented().find(value) orelse return false;
        if (!target.enabled or !target.focusable or target.layer < dispatcher.maps.presented().modal_layer) {
            return false;
        }
    }

    const before = dispatcher.focused;
    dispatcher.assignFocus(id);
    return !std.meta.eql(before, dispatcher.focused);
}

/// Rejects a gesture start while retaining its release as a sink.
/// Example: `dispatcher.discardPointer(.left);`
pub fn discardPointer(dispatcher: *Dispatcher, button: Pointer.Button) void {
    const index = @intFromEnum(button);
    dispatcher.captures[index] = null;
    dispatcher.discarded[index] = true;
}

/// Focus loss cancels all gestures, retaining physical-key sinks until their
/// releases so a later focus owner cannot inherit held input.
/// Example: `dispatcher.cancel();`
pub fn cancel(dispatcher: *Dispatcher) void {
    for (&dispatcher.captures, &dispatcher.discarded) |*capture, *discarded| {
        discarded.* = capture.* != null or discarded.*;
        capture.* = null;
    }

    for (dispatcher.keys.entries[0..dispatcher.keys.len]) |entry| {
        if (entry.owner != .fallback) {
            _ = dispatcher.keys.acquire(entry.identity, .discarded);
        }
    }

    dispatcher.hovered = null;
    dispatcher.revision +%= 1;
}

/// The currently focused delivered target, if its scope is still active.
/// Example: `const target = dispatcher.focusedTarget() orelse return;`
pub fn focusedTarget(dispatcher: *const Dispatcher) ?Target {
    const id = dispatcher.focused orelse return null;
    const registry = dispatcher.maps.presented();
    const target = registry.find(id) orelse return null;
    return if (target.enabled and target.layer >= registry.modal_layer) target else null;
}

fn text(dispatcher: *const Dispatcher) Route {
    if (!dispatcher.window_focused) {
        return .{ .consumed = true };
    }

    const target = dispatcher.focusedTarget();
    return .{ .consumed = target != null or dispatcher.maps.presented().modal_layer != 0, .target = target };
}

fn textKey(dispatcher: *Dispatcher, value: @import("../../input/TextInput.zig")) Route {
    var key_value: Key = .{ .code = .{ .char = .{ .bytes = @splat(0), .len = @intCast(@min(4, value.bytes.len)) } }, .phase = value.phase, .physical = value.physical, .target_id = value.target_id, .generation = value.generation };
    @memcpy(key_value.code.char.bytes[0..key_value.code.char.len], value.bytes[0..key_value.code.char.len]);
    return dispatcher.key(key_value);
}

fn key(dispatcher: *Dispatcher, event: Key) Route {
    if (event.physical) |physical| {
        if (event.phase != .press) {
            const owner = (if (event.phase == .release) dispatcher.keys.release(physical) else dispatcher.keys.owner(physical)) orelse return .{ .consumed = dispatcher.overflowed };
            return switch (owner) {
                .fallback => .{},
                .discarded => .{ .consumed = true },
                .widget => |id| .{ .consumed = true, .target = dispatcher.maps.presented().find(id) },
            };
        }
    }

    var result = dispatcher.text();
    if (event.target_id != 0 and (result.target == null or !result.target.?.id.eql(.{ .target_id = event.target_id, .generation = event.generation }))) {
        result = .{ .consumed = true };
    }
    if (event.phase == .press and dispatcher.window_focused) {
        const target = dispatcher.focusedTarget();
        if ((event.code == .tab or event.code == .back_tab) and (target != null or dispatcher.maps.presented().modal_layer != 0) and (target == null or target.?.traverse_tab)) {
            result = .{ .consumed = true, .focus_changed = dispatcher.traverse(event.code == .back_tab or event.mods.shift) };
        } else if (event.code == .escape and target != null and dispatcher.maps.presented().modal_layer == 0) {
            result = .{ .consumed = true, .focus_changed = dispatcher.focus(null) };
        }
    }

    if (event.physical) |physical| {
        const owner: Owner = if (!result.consumed) .fallback else if (result.target) |target| .{ .widget = target.id } else .discarded;
        if (!dispatcher.keys.acquire(physical, owner)) {
            dispatcher.overflowed = true;
            return .{ .consumed = true };
        }
    }

    return result;
}

fn pointer(dispatcher: *Dispatcher, event: Pointer) Route {
    const button = @intFromEnum(event.button);
    const registry = dispatcher.maps.presented();
    if (event.retained()) {
        if (dispatcher.captures[button]) |id| {
            if (event.kind == .release) {
                dispatcher.captures[button] = null;
                dispatcher.revision +%= 1;
            }

            return .{ .consumed = true, .target = registry.find(id) };
        }

        if (dispatcher.discarded[button]) {
            if (event.kind == .release) {
                dispatcher.discarded[button] = false;
            }

            return .{ .consumed = true };
        }

        return .{};
    }

    const target = if (event.kind == .leave) null else registry.at(.{ event.x, event.y });
    const hover: ?Id = if (target) |value| value.id else null;
    if (!std.meta.eql(hover, dispatcher.hovered)) {
        dispatcher.hovered = hover;
        dispatcher.revision +%= 1;
    }

    var changed = false;
    if (event.kind == .press) {
        dispatcher.discarded[button] = false;
        if (target) |value| {
            dispatcher.captures[button] = value.id;
            dispatcher.revision +%= 1;
            if (value.enabled and value.focusable) {
                changed = dispatcher.focus(value.id);
            }
        } else if (registry.modal_layer == 0) {
            changed = dispatcher.focus(null);
        }
    }

    return .{ .consumed = target != null or registry.modal_layer != 0, .target = if (target != null and target.?.enabled) target else null, .focus_changed = changed };
}

fn traverse(dispatcher: *Dispatcher, backwards: bool) bool {
    const registry = dispatcher.maps.presented();
    if (registry.len == 0) {
        return false;
    }

    var start: usize = if (backwards) 0 else registry.len - 1;
    if (dispatcher.focused) |id| {
        for (registry.targets[0..registry.len], 0..) |target, index| {
            if (target.id.eql(id)) {
                start = index;
                break;
            }
        }
    }

    for (1..registry.len + 1) |step| {
        const index = if (backwards) (start + registry.len - step) % registry.len else (start + step) % registry.len;
        const target = registry.targets[index];
        if (target.enabled and target.focusable and target.layer >= registry.modal_layer) {
            return dispatcher.focus(target.id);
        }
    }

    return false;
}

fn assignFocus(dispatcher: *Dispatcher, id: ?Id) void {
    if (!std.meta.eql(dispatcher.focused, id)) {
        dispatcher.focused = id;
        dispatcher.revision +%= 1;
    }
}
