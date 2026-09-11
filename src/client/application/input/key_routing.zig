//! Application policy for assigning routed host input to one client owner.

const KeyType = @import("../../input/Key.zig");
const PaneIdType = @import("telar-core").PaneId;
const GenericTable = @import("../../input/GenericTable.zig").Type;
const keybind = @import("../../input/keybind.zig");
const KeyRoutingAuthority = @import("KeyRoutingAuthority.zig");
const std = @import("std");
const chord = @import("../../input/chord.zig");
const KeyRoutingCapture = @import("KeyRoutingCapture.zig");
const PhysicalType = @import("../../input/Physical.zig");

pub const Command = union(enum) {
    bytes: []const u8,
    key: KeyType,
};

pub const Owner = enum {
    ignored,
    attachment_modal,
    name_prompt,
    copy_mode,
    pane,
};

pub const PaneTarget = union(enum) {
    current,
    lease: PaneIdType,
};

pub const LeaseOwner = union(enum) {
    ignored,
    attachment_modal,
    name_prompt,
    copy_mode,
    pane: PaneIdType,
};

pub const Leases = GenericTable(LeaseOwner, keybind.max_physical_leases);

/// Returns whether the native router must bypass configured bindings for the
/// current exclusive owner.
///
/// ```zig
/// if (captures(authority)) routeDirectly();
/// ```
pub fn captures(authority: KeyRoutingAuthority) bool {
    return authority.attachment_modal_active or authority.prompt_active;
}

pub fn requestsClipboardPreview(command: Command) bool {
    return switch (command) {
        .bytes => false,
        .key => |key| key.phase == .press and key.isCtrl('v') and !key.mods.alt and !key.mods.shift,
    };
}

pub const Event = enum {
    close_modal,
    prompt,
    copy_key,
    pane,
    preview,
};

pub const Failure = enum {
    none,
    prompt,
    copy_key,
    pane,
    preview,
};

test "key routing captures only modal and prompt authority" {
    try std.testing.expect(captures(.{ .attachment_modal_active = true }));
    try std.testing.expect(captures(.{ .prompt_active = true }));
    try std.testing.expect(!captures(.{ .copy_mode_active = true }));
    try std.testing.expect(!captures(.{}));
}

test "semantic key routing selects modal prompt copy mode or pane in order" {
    const key = try chord.parseKey("x");
    var capture: KeyRoutingCapture = .{};
    var handler = capture.routingHandler();

    const modal = try handler.execute(.{ .key = try chord.parseKey("escape") }, .{
        .attachment_modal_active = true,
        .prompt_active = true,
        .copy_mode_active = true,
    });
    try std.testing.expectEqual(Owner.attachment_modal, modal.owner);
    try std.testing.expectEqualSlices(Event, &.{.close_modal}, capture.events[0..capture.event_count]);

    capture = .{};
    handler = capture.routingHandler();
    const prompt = try handler.execute(.{ .key = key }, .{
        .prompt_active = true,
        .copy_mode_active = true,
    });
    try std.testing.expectEqual(Owner.name_prompt, prompt.owner);
    try std.testing.expectEqualSlices(Event, &.{.prompt}, capture.events[0..capture.event_count]);
    try std.testing.expectEqualDeep(Command{ .key = key }, capture.command.?);

    capture = .{};
    handler = capture.routingHandler();
    const copy = try handler.execute(.{ .key = key }, .{ .copy_mode_active = true });
    try std.testing.expectEqual(Owner.copy_mode, copy.owner);
    try std.testing.expectEqualSlices(Event, &.{.copy_key}, capture.events[0..capture.event_count]);

    capture = .{};
    handler = capture.routingHandler();
    const pane = try handler.execute(.{ .key = key }, .{});
    try std.testing.expectEqual(Owner.pane, pane.owner);
    try std.testing.expect(pane.delivered);
    try std.testing.expectEqualSlices(Event, &.{.pane}, capture.events[0..capture.event_count]);
}

test "byte routing ignores empty values and bypasses modal authority" {
    var capture: KeyRoutingCapture = .{};
    var handler = capture.routingHandler();

    const empty = try handler.execute(.{ .bytes = "" }, .{ .attachment_modal_active = true });
    try std.testing.expectEqual(Owner.ignored, empty.owner);
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);

    const pane = try handler.execute(.{ .bytes = "raw" }, .{ .attachment_modal_active = true });
    try std.testing.expectEqual(Owner.pane, pane.owner);
    try std.testing.expectEqualSlices(Event, &.{.pane}, capture.events[0..capture.event_count]);
    try std.testing.expectEqualStrings("raw", capture.command.?.bytes);

    capture = .{};
    handler = capture.routingHandler();
    const prompt = try handler.execute(.{ .bytes = "name" }, .{
        .attachment_modal_active = true,
        .prompt_active = true,
        .copy_mode_active = true,
    });
    try std.testing.expectEqual(Owner.name_prompt, prompt.owner);
    try std.testing.expectEqualSlices(Event, &.{.prompt}, capture.events[0..capture.event_count]);

    capture = .{};
    handler = capture.routingHandler();
    const copy = try handler.execute(.{ .bytes = "ignored" }, .{ .copy_mode_active = true });
    try std.testing.expectEqual(Owner.copy_mode, copy.owner);
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "clipboard preview follows one confirmed pane delivery and cannot fail the key" {
    const control_v = try chord.parseKey("ctrl+v");
    var capture: KeyRoutingCapture = .{ .failure = .preview };
    var handler = capture.routingHandler();

    const delivered = try handler.execute(.{ .key = control_v }, .{});
    try std.testing.expect(delivered.delivered);
    try std.testing.expectEqualSlices(Event, &.{ .pane, .preview }, capture.events[0..capture.event_count]);

    capture = .{ .pane_delivered = false };
    handler = capture.routingHandler();
    const unavailable = try handler.execute(.{ .key = control_v }, .{});
    try std.testing.expect(!unavailable.delivered);
    try std.testing.expectEqualSlices(Event, &.{.pane}, capture.events[0..capture.event_count]);

    capture = .{};
    handler = capture.routingHandler();
    var shifted = control_v;
    shifted.mods.shift = true;
    _ = try handler.execute(.{ .key = shifted }, .{});
    try std.testing.expectEqualSlices(Event, &.{.pane}, capture.events[0..capture.event_count]);

    const other_keys = [_]KeyType{
        try chord.parseKey("alt+v"),
        try chord.parseKey("v"),
        try chord.parseKey("ctrl+shift+left"),
    };
    for (other_keys) |key| {
        capture = .{};
        handler = capture.routingHandler();
        _ = try handler.execute(.{ .key = key }, .{});
        try std.testing.expectEqualSlices(Event, &.{.pane}, capture.events[0..capture.event_count]);
    }
}

test "selected key owner failures propagate without falling through" {
    var capture: KeyRoutingCapture = .{ .failure = .prompt };
    var handler = capture.routingHandler();

    try std.testing.expectError(
        error.PromptInputFailed,
        handler.execute(.{ .bytes = "name" }, .{
            .prompt_active = true,
            .copy_mode_active = true,
        }),
    );
    try std.testing.expectEqualSlices(Event, &.{.prompt}, capture.events[0..capture.event_count]);

    capture = .{ .failure = .copy_key };
    handler = capture.routingHandler();
    try std.testing.expectError(
        error.CopyModeInputFailed,
        handler.execute(.{ .key = try chord.parseKey("x") }, .{ .copy_mode_active = true }),
    );
    try std.testing.expectEqualSlices(Event, &.{.copy_key}, capture.events[0..capture.event_count]);

    capture = .{ .failure = .pane };
    handler = capture.routingHandler();
    try std.testing.expectError(error.PaneInputFailed, handler.execute(.{ .bytes = "raw" }, .{}));
    try std.testing.expectEqualSlices(Event, &.{.pane}, capture.events[0..capture.event_count]);
}

test "a pane key lifecycle stays with the pane that received its press" {
    const first: PaneIdType = @enumFromInt(1);
    const second: PaneIdType = @enumFromInt(2);
    const identity: PhysicalType = .{ .value = 120 };
    var capture: KeyRoutingCapture = .{ .pane_id = first };
    var handler = capture.routingHandler();

    const press = try handler.execute(.{ .key = .{
        .code = .{ .char = .init("x") },
        .physical = identity,
    } }, .{});
    try std.testing.expect(press.delivered);
    try std.testing.expectEqual(PaneTarget.current, capture.pane_target.?);

    capture.pane_id = second;
    const repeat = try handler.execute(.{ .key = .{
        .code = .{ .char = .init("x") },
        .phase = .repeat,
        .physical = identity,
    } }, .{ .prompt_active = true });
    try std.testing.expect(repeat.delivered);
    try std.testing.expectEqualDeep(PaneTarget{ .lease = first }, capture.pane_target.?);

    const release = try handler.execute(.{ .key = .{
        .code = .{ .char = .init("x") },
        .phase = .release,
        .physical = identity,
    } }, .{ .copy_mode_active = true });
    try std.testing.expect(release.delivered);
    try std.testing.expectEqualDeep(PaneTarget{ .lease = first }, capture.pane_target.?);
    try std.testing.expectEqual(@as(usize, 0), capture.leases.count());
    try std.testing.expectEqualSlices(Event, &.{ .pane, .pane, .pane }, capture.events[0..capture.event_count]);
}

test "prompt repeats stay with the prompt and release has no side effect" {
    const identity: PhysicalType = .{ .value = 97 };
    var capture: KeyRoutingCapture = .{};
    var handler = capture.routingHandler();

    _ = try handler.execute(.{ .key = .{
        .code = .{ .char = .init("a") },
        .physical = identity,
    } }, .{ .prompt_active = true });
    _ = try handler.execute(.{ .key = .{
        .code = .{ .char = .init("a") },
        .phase = .repeat,
        .physical = identity,
    } }, .{});
    _ = try handler.execute(.{ .key = .{
        .code = .{ .char = .init("a") },
        .phase = .release,
        .physical = identity,
    } }, .{});

    try std.testing.expectEqualSlices(Event, &.{ .prompt, .prompt }, capture.events[0..capture.event_count]);
    try std.testing.expectEqual(@as(usize, 0), capture.leases.count());
}

test "orphan lifecycles and saturated leases fail closed" {
    var capture: KeyRoutingCapture = .{};
    var handler = capture.routingHandler();

    const orphan = try handler.execute(.{ .key = .{
        .code = .{ .char = .init("x") },
        .phase = .release,
        .physical = .{ .value = 120 },
    } }, .{});
    try std.testing.expectEqual(Owner.ignored, orphan.owner);
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);

    for (0..keybind.max_physical_leases) |index| {
        try std.testing.expect(capture.leases.acquire(.{ .value = @intCast(index + 1) }, .ignored));
    }
    const overflow = try handler.execute(.{ .key = .{
        .code = .{ .char = .init("x") },
        .physical = .{ .value = keybind.max_physical_leases + 1 },
    } }, .{});
    try std.testing.expect(overflow.lease_overflow);
    try std.testing.expectEqual(Owner.ignored, overflow.owner);
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "failed press delivery does not leave a lease" {
    var capture: KeyRoutingCapture = .{ .failure = .prompt };
    var handler = capture.routingHandler();

    try std.testing.expectError(error.PromptInputFailed, handler.execute(.{ .key = .{
        .code = .{ .char = .init("x") },
        .physical = .{ .value = 120 },
    } }, .{ .prompt_active = true }));
    try std.testing.expectEqual(@as(usize, 0), capture.leases.count());
}
