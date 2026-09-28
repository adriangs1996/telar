//! Client-owned input routing over the last successfully delivered targets.
//! The compositor may prepare new targets while input retains the visible
//! ones. Gesture and physical-key leases keep their owner across focus changes.
const keyinput = @import("keyinput");
const event_module = @import("../../input/event.zig");
const key_owner = @import("key_owner.zig");
const data = @import("model");
const std = @import("std");
const Key = @import("../../input/KeyInput.zig");
const Pointer = @import("../../input/PointerEvent.zig");
const Id = @import("Id.zig");
const Target = @import("Target.zig");
const Registry = @import("Registry.zig");
const Route = @import("Route.zig");
const GenericPresentedState = @import("../../render/GenericPresentedState.zig").Type;
const TextInput = @import("../../input/TextInput.zig");
const GenericTable = keyinput.GenericTable;
const Dispatcher = @This();

maps: GenericPresentedState(Registry) = .{},
focused: ?Id = null,
hovered: ?Id = null,
captures: [3]?Id = @splat(null),
/// Retired captures still consume their eventual release.
discarded: [3]bool = @splat(false),
keys: GenericTable(key_owner.Owner, data.keybind.max_physical_leases) = .{},
revision: u64 = 0,
window_focused: bool = true,
next_id: u64 = 1,
overflowed: bool = false,
message_link_count: u8 = 0,

/// Begins a replacement registry without changing input authority.
/// Example: `const targets = dispatcher.begin();`
pub fn begin(self: *Dispatcher) *Registry {
    self.message_link_count = 0;
    return self.maps.begin();
}

/// Link fragments have a separate quota and leave room for conversation controls.
/// Saturation keeps the styled label visible without adding a hover target.
/// Example: `_ = try dispatcher.addMessageLink(target);`
pub fn addMessageLink(self: *Dispatcher, target: Target) !?Id {
    if (self.message_link_count == 64 or self.maps.preparing().len >= Registry.capacity - 64) {
        return null;
    }

    const id = try self.add(target);
    self.message_link_count += 1;
    return id;
}

/// Assigns collision-free IDs by owned semantic identity, retaining an ID
/// across reordered frames. A generation change or disappearance retires it.
/// Example: `const id = try dispatcher.add(.{ .bounds = bounds, .action = action });`
pub fn add(self: *Dispatcher, value: Target) !Id {
    var target = value;
    if (target.id.target_id == 0) {
        for (self.maps.presented().targets[0..self.maps.presented().len]) |previous| {
            if (previous.namespace == target.namespace and previous.id.generation == target.id.generation and std.meta.eql(previous.action, target.action)) {
                target.id = previous.id;
                break;
            }
        }

        if (target.id.target_id == 0) {
            target.id.target_id = self.next_id;
            self.next_id = std.math.add(u64, self.next_id, 1) catch return error.WidgetIdentityExhausted;
        }
    }

    try self.maps.preparing().add(target);
    return target.id;
}

/// Example: `dispatcher.seal();`
pub fn seal(self: *Dispatcher) void {
    self.maps.seal();
}

/// Publishes only after the matching frame succeeded. A retired target loses
/// focus and its captured gestures become sinks until their releases arrive.
/// Example: `dispatcher.present(delivered);`
pub fn present(self: *Dispatcher, delivered: bool) void {
    const changed = delivered and self.maps.sealed and !self.maps.presented().equivalent(self.maps.prepared());
    self.maps.present(delivered);
    if (!delivered) {
        return;
    }

    const registry = self.maps.presented();
    if (changed) {
        self.revision +%= 1;
    }
    if (self.focused) |id| {
        const target = registry.find(id);
        if (target == null or target.?.layer < registry.modal_layer or !target.?.enabled) {
            self.assignFocus(null);
        }
    }

    for (&self.captures, &self.discarded) |*capture, *discarded| {
        if (capture.*) |id| {
            const target = registry.find(id);
            if (target == null or !target.?.enabled or target.?.layer < registry.modal_layer) {
                capture.* = null;
                discarded.* = true;
            }
        }
    }

    for (self.keys.entries[0..self.keys.len]) |entry| {
        if (entry.owner == .widget) {
            const target = registry.find(entry.owner.widget);
            if (target == null or !target.?.enabled or target.?.layer < registry.modal_layer) {
                _ = self.keys.acquire(entry.identity, .discarded);
            }
        }
    }

    if (self.focused == null and registry.modal_layer != 0) {
        _ = self.traverse(false);
    }
}

/// Chooses a delivered owner; false leaves terminal routing intact. Text,
/// paste and IME use focused ownership, never hover. Call only on the client
/// thread after native admission copied its borrowed bytes.
/// Example: `const routed = dispatcher.route(event);`
pub fn route(self: *Dispatcher, event: event_module.Event) Route {
    return switch (event) {
        .key => |value| self.key(value, true),
        .text => |value| if (value.physical != null) self.textKey(value) else self.text(),
        .pointer => |value| self.pointer(value),
        .scroll => |scroll| .{ .consumed = self.maps.presented().at(.{ scroll.x, scroll.y }) != null or self.maps.presented().modal_layer != 0, .target = self.maps.presented().at(.{ scroll.x, scroll.y }) },
        .focus => |focused| blk: {
            self.window_focused = focused;
            if (!focused) {
                self.cancel();
            }

            break :blk .{};
        },
        else => self.text(),
    };
}

/// Explicit focus requests are checked against delivered geometry and scope.
/// Example: `const changed = dispatcher.focus(field_id);`
pub fn focus(self: *Dispatcher, id: ?Id) bool {
    if (id) |value| {
        const target = self.maps.presented().find(value) orelse return false;
        if (!target.enabled or !target.focusable or target.layer < self.maps.presented().modal_layer) {
            return false;
        }
    }

    const before = self.focused;
    self.assignFocus(id);
    return !std.meta.eql(before, self.focused);
}

/// Rejects a gesture start while retaining its release as a sink.
/// Example: `dispatcher.discardPointer(.left);`
pub fn discardPointer(self: *Dispatcher, button: Pointer.Button) void {
    const index = @intFromEnum(button);
    self.captures[index] = null;
    self.discarded[index] = true;
}

/// Focus loss cancels all gestures, retaining physical-key sinks until their
/// releases so a later focus owner cannot inherit held input.
/// Example: `dispatcher.cancel();`
pub fn cancel(self: *Dispatcher) void {
    for (&self.captures, &self.discarded) |*capture, *discarded| {
        discarded.* = capture.* != null or discarded.*;
        capture.* = null;
    }

    for (self.keys.entries[0..self.keys.len]) |entry| {
        if (entry.owner != .fallback) {
            _ = self.keys.acquire(entry.identity, .discarded);
        }
    }

    self.hovered = null;
    self.revision +%= 1;
}

/// The currently focused delivered target, if its scope is still active.
/// Example: `const target = dispatcher.focusedTarget() orelse return;`
pub fn focusedTarget(self: *const Dispatcher) ?Target {
    const id = self.focused orelse return null;
    const registry = self.maps.presented();
    const target = registry.find(id) orelse return null;
    return if (target.enabled and target.layer >= registry.modal_layer) target else null;
}

fn text(self: *const Dispatcher) Route {
    if (!self.window_focused) {
        return .{ .consumed = true };
    }

    const target = self.focusedTarget();
    return .{ .consumed = target != null or self.maps.presented().modal_layer != 0, .target = target };
}

fn textKey(self: *Dispatcher, value: TextInput) Route {
    var key_value: Key = .{ .code = .{ .char = .{ .bytes = @splat(0), .len = @intCast(@min(4, value.bytes.len)) } }, .phase = value.phase, .physical = value.physical, .target_id = value.target_id, .generation = value.generation };
    @memcpy(key_value.code.char.bytes[0..key_value.code.char.len], value.bytes[0..key_value.code.char.len]);
    return self.key(key_value, true);
}

/// Captures editor-menu navigation without traversing or abandoning its editor.
/// Physical leases and explicit native target validation remain unchanged.
/// Example: `const decision = dispatcher.editorKey(event);`
pub fn editorKey(self: *Dispatcher, event: Key) Route {
    return self.key(event, false);
}

fn key(self: *Dispatcher, event: Key, navigate: bool) Route {
    if (event.physical) |physical| {
        if (event.phase != .press) {
            const owner = (if (event.phase == .release) self.keys.release(physical) else self.keys.owner(physical)) orelse return .{ .consumed = self.overflowed };
            return switch (owner) {
                .fallback => .{},
                .discarded => .{ .consumed = true },
                .widget => |id| .{ .consumed = true, .target = self.maps.presented().find(id) },
            };
        }
    }

    var result = self.text();
    if (event.target_id != 0 and (result.target == null or !result.target.?.id.eql(.{ .target_id = event.target_id, .generation = event.generation }))) {
        result = .{ .consumed = true };
    }
    if (navigate and event.phase == .press and self.window_focused) {
        const target = self.focusedTarget();
        // Tab moves focus only when another control can take it. A prompt
        // field keeps the key: its prompt owns what Tab means, from moving
        // between the context form's fields to completing a folder.
        const prompt_field = target != null and target.?.action == .text_field;
        if ((event.code == .tab or event.code == .back_tab) and !prompt_field and (target != null or self.maps.presented().modal_layer != 0) and self.canTraverse()) {
            result = .{ .consumed = true, .focus_changed = self.traverse(event.code == .back_tab or event.mods.shift) };
        } else if (event.code == .escape and target != null and self.maps.presented().modal_layer == 0) {
            result = .{ .consumed = true, .focus_changed = self.focus(null) };
        }
    }

    if (event.physical) |physical| {
        const owner: key_owner.Owner = if (!result.consumed) .fallback else if (result.target) |target| .{ .widget = target.id } else .discarded;
        if (!self.keys.acquire(physical, owner)) {
            self.overflowed = true;
            return .{ .consumed = true };
        }
    }

    return result;
}

fn pointer(self: *Dispatcher, event: Pointer) Route {
    const button = @intFromEnum(event.button);
    const registry = self.maps.presented();
    if (event.retained()) {
        if (self.captures[button]) |id| {
            if (event.kind == .release) {
                self.captures[button] = null;
                self.revision +%= 1;
            }

            return .{ .consumed = true, .target = registry.find(id) };
        }

        if (self.discarded[button]) {
            if (event.kind == .release) {
                self.discarded[button] = false;
            }

            return .{ .consumed = true };
        }

        return .{};
    }

    const target = if (event.kind == .leave) null else registry.at(.{ event.x, event.y });
    const hover: ?Id = if (target) |value| value.id else null;
    if (!std.meta.eql(hover, self.hovered)) {
        self.hovered = hover;
        self.revision +%= 1;
    }

    var changed = false;
    if (event.kind == .press) {
        self.discarded[button] = false;
        if (target) |value| {
            self.captures[button] = value.id;
            self.revision +%= 1;
            if (value.enabled and value.focusable) {
                changed = self.focus(value.id);
            }
        } else if (registry.modal_layer == 0) {
            changed = self.focus(null);
        }
    }

    return .{ .consumed = target != null or registry.modal_layer != 0, .target = if (target != null and target.?.enabled) target else null, .focus_changed = changed };
}

/// Whether a focusable control other than the focused one is reachable.
fn canTraverse(self: *const Dispatcher) bool {
    const registry = self.maps.presented();
    for (registry.targets[0..registry.len]) |target| {
        if (!target.enabled or !target.focusable or target.layer < registry.modal_layer) {
            continue;
        }

        if (self.focused == null or !target.id.eql(self.focused.?)) {
            return true;
        }
    }

    return false;
}

fn traverse(self: *Dispatcher, backwards: bool) bool {
    const registry = self.maps.presented();
    if (registry.len == 0) {
        return false;
    }

    var start: usize = if (backwards) 0 else registry.len - 1;
    if (self.focused) |id| {
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
            return self.focus(target.id);
        }
    }

    return false;
}

fn assignFocus(self: *Dispatcher, id: ?Id) void {
    if (!std.meta.eql(self.focused, id)) {
        self.focused = id;
        self.revision +%= 1;
    }
}
