//! Application policy for assigning routed host input to one client owner.

const std = @import("std");
const core = @import("telar-core");
const input_capability = @import("../../../input/root.zig");

const keybind = input_capability.keybind;
const key_lease = input_capability.key_lease;
const schema = core.schema;

pub const Command = union(enum) {
    bytes: []const u8,
    key: keybind.Key,
};

pub const Authority = struct {
    attachment_modal_active: bool = false,
    prompt_active: bool = false,
    copy_mode_active: bool = false,
};

pub const Owner = enum {
    ignored,
    attachment_modal,
    name_prompt,
    copy_mode,
    pane,
};

pub const Outcome = struct {
    owner: Owner,
    delivered: bool = false,
    lease_overflow: bool = false,
};

pub const PaneTarget = union(enum) {
    current,
    lease: schema.PaneId,
};

pub const PaneCommand = struct {
    target: PaneTarget,
    input: Command,
};

pub const LeaseOwner = union(enum) {
    ignored,
    attachment_modal,
    name_prompt,
    copy_mode,
    pane: schema.PaneId,
};

pub const Leases = key_lease.Table(LeaseOwner, keybind.max_physical_leases);

pub const Effects = struct {
    context: *anyopaque,
    close_modal: *const fn (*anyopaque) void,
    prompt: *const fn (*anyopaque, Command) anyerror!void,
    copy_key: *const fn (*anyopaque, keybind.Key) anyerror!void,
    pane: *const fn (*anyopaque, PaneCommand) anyerror!?schema.PaneId,
    preview: *const fn (*anyopaque) anyerror!void,
};

/// Returns whether the native router must bypass configured bindings for the
/// current exclusive owner.
///
/// ```zig
/// if (captures(authority)) routeDirectly();
/// ```
pub fn captures(authority: Authority) bool {
    return authority.attachment_modal_active or authority.prompt_active;
}

pub const KeyRoutingHandler = struct {
    effects: Effects,
    leases: *Leases,

    /// Assigns one synchronous input value to exactly one owner. A successful
    /// unmodified Ctrl+V pane delivery may start one best-effort media preview.
    ///
    /// ```zig
    /// const outcome = try handler.execute(command, authority);
    /// ```
    pub fn execute(handler: *KeyRoutingHandler, command: Command, authority: Authority) !Outcome {
        return switch (command) {
            .bytes => |bytes| if (bytes.len == 0)
                .{ .owner = .ignored }
            else
                (try handler.routeCurrent(command, authority)).outcome,
            .key => |key| handler.routeKey(key, authority),
        };
    }

    const Routed = struct {
        outcome: Outcome,
        lease_owner: LeaseOwner,
    };

    fn routeKey(handler: *KeyRoutingHandler, key: keybind.Key, authority: Authority) !Outcome {
        const identity = key.physical orelse return (try handler.routeCurrent(.{ .key = key }, authority)).outcome;

        return switch (key.phase) {
            .press => handler.routePress(key, authority),
            .repeat => handler.routeRepeat(key, handler.leases.owner(identity) orelse return .{ .owner = .ignored }),
            .release => handler.routeRelease(key, handler.leases.release(identity) orelse return .{ .owner = .ignored }),
        };
    }

    fn routePress(handler: *KeyRoutingHandler, key: keybind.Key, authority: Authority) !Outcome {
        const identity = key.physical.?;
        if (!handler.leases.acquire(identity, .ignored)) {
            return .{ .owner = .ignored, .lease_overflow = true };
        }
        errdefer _ = handler.leases.release(identity);

        const routed = try handler.routeCurrent(.{ .key = key }, authority);
        const assigned = handler.leases.acquire(identity, routed.lease_owner);
        std.debug.assert(assigned);

        return routed.outcome;
    }

    fn routeRepeat(handler: *KeyRoutingHandler, key: keybind.Key, owner: LeaseOwner) !Outcome {
        return switch (owner) {
            .ignored => .{ .owner = .ignored },
            .attachment_modal => .{ .owner = .attachment_modal },
            .name_prompt => prompt: {
                try handler.effects.prompt(handler.effects.context, .{ .key = key });

                break :prompt .{ .owner = .name_prompt };
            },
            .copy_mode => copy: {
                try handler.effects.copy_key(handler.effects.context, key);

                break :copy .{ .owner = .copy_mode };
            },
            .pane => |pane_id| handler.routeLeasedPane(key, pane_id),
        };
    }

    fn routeRelease(handler: *KeyRoutingHandler, key: keybind.Key, owner: LeaseOwner) !Outcome {
        return switch (owner) {
            .ignored => .{ .owner = .ignored },
            .attachment_modal => .{ .owner = .attachment_modal },
            .name_prompt => .{ .owner = .name_prompt },
            .copy_mode => .{ .owner = .copy_mode },
            .pane => |pane_id| handler.routeLeasedPane(key, pane_id),
        };
    }

    fn routeCurrent(handler: *KeyRoutingHandler, command: Command, authority: Authority) !Routed {
        switch (command) {
            .bytes => {},
            .key => |key| {
                if (authority.attachment_modal_active) {
                    if (key.code == .escape) {
                        handler.effects.close_modal(handler.effects.context);
                    }

                    return .{
                        .outcome = .{ .owner = .attachment_modal },
                        .lease_owner = .attachment_modal,
                    };
                }
            },
        }

        if (authority.prompt_active) {
            try handler.effects.prompt(handler.effects.context, command);

            return .{
                .outcome = .{ .owner = .name_prompt },
                .lease_owner = .name_prompt,
            };
        }

        if (authority.copy_mode_active) {
            switch (command) {
                .bytes => {},
                .key => |key| try handler.effects.copy_key(handler.effects.context, key),
            }

            return .{
                .outcome = .{ .owner = .copy_mode },
                .lease_owner = .copy_mode,
            };
        }

        const pane_id = try handler.effects.pane(handler.effects.context, .{
            .target = .current,
            .input = command,
        });
        if (pane_id != null and requestsClipboardPreview(command)) {
            handler.effects.preview(handler.effects.context) catch {};
        }

        return .{
            .outcome = .{ .owner = .pane, .delivered = pane_id != null },
            .lease_owner = if (pane_id) |id| .{ .pane = id } else .ignored,
        };
    }

    fn routeLeasedPane(handler: *KeyRoutingHandler, key: keybind.Key, pane_id: schema.PaneId) !Outcome {
        const delivered = try handler.effects.pane(handler.effects.context, .{
            .target = .{ .lease = pane_id },
            .input = .{ .key = key },
        });

        return .{ .owner = .pane, .delivered = delivered != null };
    }
};

fn requestsClipboardPreview(command: Command) bool {
    return switch (command) {
        .bytes => false,
        .key => |key| key.phase == .press and key.isCtrl('v') and !key.mods.alt and !key.mods.shift,
    };
}

const Event = enum {
    close_modal,
    prompt,
    copy_key,
    pane,
    preview,
};

const Failure = enum {
    none,
    prompt,
    copy_key,
    pane,
    preview,
};

const Capture = struct {
    events: [5]Event = undefined,
    event_count: usize = 0,
    command: ?Command = null,
    pane_delivered: bool = true,
    pane_id: schema.PaneId = @enumFromInt(1),
    pane_target: ?PaneTarget = null,
    failure: Failure = .none,
    leases: Leases = .{},

    fn routingHandler(capture: *Capture) KeyRoutingHandler {
        return .{
            .effects = capture.effects(),
            .leases = &capture.leases,
        };
    }

    fn effects(capture: *Capture) Effects {
        return .{
            .context = capture,
            .close_modal = closeModal,
            .prompt = prompt,
            .copy_key = copyKey,
            .pane = pane,
            .preview = preview,
        };
    }

    fn record(capture: *Capture, event: Event) void {
        capture.events[capture.event_count] = event;
        capture.event_count += 1;
    }

    fn closeModal(raw_context: *anyopaque) void {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        capture.record(.close_modal);
    }

    fn prompt(raw_context: *anyopaque, command: Command) !void {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        capture.record(.prompt);
        capture.command = command;

        if (capture.failure == .prompt) {
            return error.PromptInputFailed;
        }
    }

    fn copyKey(raw_context: *anyopaque, key: keybind.Key) !void {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        capture.record(.copy_key);
        capture.command = .{ .key = key };

        if (capture.failure == .copy_key) {
            return error.CopyModeInputFailed;
        }
    }

    fn pane(raw_context: *anyopaque, command: PaneCommand) !?schema.PaneId {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        capture.record(.pane);
        capture.command = command.input;
        capture.pane_target = command.target;

        if (capture.failure == .pane) {
            return error.PaneInputFailed;
        }

        if (!capture.pane_delivered) {
            return null;
        }

        return switch (command.target) {
            .current => capture.pane_id,
            .lease => |pane_id| pane_id,
        };
    }

    fn preview(raw_context: *anyopaque) !void {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        capture.record(.preview);

        if (capture.failure == .preview) {
            return error.ClipboardPreviewFailed;
        }
    }
};

test "key routing captures only modal and prompt authority" {
    try std.testing.expect(captures(.{ .attachment_modal_active = true }));
    try std.testing.expect(captures(.{ .prompt_active = true }));
    try std.testing.expect(!captures(.{ .copy_mode_active = true }));
    try std.testing.expect(!captures(.{}));
}

test "semantic key routing selects modal prompt copy mode or pane in order" {
    const key = try keybind.parseKey("x");
    var capture: Capture = .{};
    var handler = capture.routingHandler();

    const modal = try handler.execute(.{ .key = try keybind.parseKey("escape") }, .{
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
    var capture: Capture = .{};
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
    const control_v = try keybind.parseKey("ctrl+v");
    var capture: Capture = .{ .failure = .preview };
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

    const other_keys = [_]keybind.Key{
        try keybind.parseKey("alt+v"),
        try keybind.parseKey("v"),
        try keybind.parseKey("ctrl+shift+left"),
    };
    for (other_keys) |key| {
        capture = .{};
        handler = capture.routingHandler();
        _ = try handler.execute(.{ .key = key }, .{});
        try std.testing.expectEqualSlices(Event, &.{.pane}, capture.events[0..capture.event_count]);
    }
}

test "selected key owner failures propagate without falling through" {
    var capture: Capture = .{ .failure = .prompt };
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
        handler.execute(.{ .key = try keybind.parseKey("x") }, .{ .copy_mode_active = true }),
    );
    try std.testing.expectEqualSlices(Event, &.{.copy_key}, capture.events[0..capture.event_count]);

    capture = .{ .failure = .pane };
    handler = capture.routingHandler();
    try std.testing.expectError(error.PaneInputFailed, handler.execute(.{ .bytes = "raw" }, .{}));
    try std.testing.expectEqualSlices(Event, &.{.pane}, capture.events[0..capture.event_count]);
}

test "a pane key lifecycle stays with the pane that received its press" {
    const first: schema.PaneId = @enumFromInt(1);
    const second: schema.PaneId = @enumFromInt(2);
    const identity: keybind.Key.Physical = .{ .value = 120 };
    var capture: Capture = .{ .pane_id = first };
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
    const identity: keybind.Key.Physical = .{ .value = 97 };
    var capture: Capture = .{};
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
    var capture: Capture = .{};
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
    var capture: Capture = .{ .failure = .prompt };
    var handler = capture.routingHandler();

    try std.testing.expectError(error.PromptInputFailed, handler.execute(.{ .key = .{
        .code = .{ .char = .init("x") },
        .physical = .{ .value = 120 },
    } }, .{ .prompt_active = true }));
    try std.testing.expectEqual(@as(usize, 0), capture.leases.count());
}
