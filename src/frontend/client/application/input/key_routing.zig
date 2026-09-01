//! Application policy for assigning routed host input to one client owner.

const std = @import("std");
const input_capability = @import("../../../input/root.zig");

const keybind = input_capability.keybind;

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
};

pub const Effects = struct {
    context: *anyopaque,
    close_modal: *const fn (*anyopaque) void,
    prompt: *const fn (*anyopaque, Command) anyerror!void,
    copy_key: *const fn (*anyopaque, keybind.Key) anyerror!void,
    pane: *const fn (*anyopaque, Command) anyerror!bool,
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

    /// Assigns one synchronous input value to exactly one owner. A successful
    /// unmodified Ctrl+V pane delivery may start one best-effort media preview.
    ///
    /// ```zig
    /// const outcome = try handler.execute(command, authority);
    /// ```
    pub fn execute(handler: *KeyRoutingHandler, command: Command, authority: Authority) !Outcome {
        switch (command) {
            .bytes => |bytes| {
                if (bytes.len == 0) {
                    return .{ .owner = .ignored };
                }
            },
            .key => |key| {
                if (authority.attachment_modal_active) {
                    if (key.code == .escape) {
                        handler.effects.close_modal(handler.effects.context);
                    }

                    return .{ .owner = .attachment_modal };
                }
            },
        }

        if (authority.prompt_active) {
            try handler.effects.prompt(handler.effects.context, command);

            return .{ .owner = .name_prompt };
        }

        if (authority.copy_mode_active) {
            switch (command) {
                .bytes => {},
                .key => |key| try handler.effects.copy_key(handler.effects.context, key),
            }

            return .{ .owner = .copy_mode };
        }

        const delivered = try handler.effects.pane(handler.effects.context, command);
        if (delivered and requestsClipboardPreview(command)) {
            handler.effects.preview(handler.effects.context) catch {};
        }

        return .{ .owner = .pane, .delivered = delivered };
    }
};

fn requestsClipboardPreview(command: Command) bool {
    return switch (command) {
        .bytes => false,
        .key => |key| key.isCtrl('v') and !key.mods.alt and !key.mods.shift,
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
    failure: Failure = .none,

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

    fn pane(raw_context: *anyopaque, command: Command) !bool {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        capture.record(.pane);
        capture.command = command;

        if (capture.failure == .pane) {
            return error.PaneInputFailed;
        }

        return capture.pane_delivered;
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
    var handler: KeyRoutingHandler = .{ .effects = capture.effects() };

    const modal = try handler.execute(.{ .key = try keybind.parseKey("escape") }, .{
        .attachment_modal_active = true,
        .prompt_active = true,
        .copy_mode_active = true,
    });
    try std.testing.expectEqual(Owner.attachment_modal, modal.owner);
    try std.testing.expectEqualSlices(Event, &.{.close_modal}, capture.events[0..capture.event_count]);

    capture = .{};
    handler = .{ .effects = capture.effects() };
    const prompt = try handler.execute(.{ .key = key }, .{
        .prompt_active = true,
        .copy_mode_active = true,
    });
    try std.testing.expectEqual(Owner.name_prompt, prompt.owner);
    try std.testing.expectEqualSlices(Event, &.{.prompt}, capture.events[0..capture.event_count]);
    try std.testing.expectEqualDeep(Command{ .key = key }, capture.command.?);

    capture = .{};
    handler = .{ .effects = capture.effects() };
    const copy = try handler.execute(.{ .key = key }, .{ .copy_mode_active = true });
    try std.testing.expectEqual(Owner.copy_mode, copy.owner);
    try std.testing.expectEqualSlices(Event, &.{.copy_key}, capture.events[0..capture.event_count]);

    capture = .{};
    handler = .{ .effects = capture.effects() };
    const pane = try handler.execute(.{ .key = key }, .{});
    try std.testing.expectEqual(Owner.pane, pane.owner);
    try std.testing.expect(pane.delivered);
    try std.testing.expectEqualSlices(Event, &.{.pane}, capture.events[0..capture.event_count]);
}

test "byte routing ignores empty values and bypasses modal authority" {
    var capture: Capture = .{};
    var handler: KeyRoutingHandler = .{ .effects = capture.effects() };

    const empty = try handler.execute(.{ .bytes = "" }, .{ .attachment_modal_active = true });
    try std.testing.expectEqual(Owner.ignored, empty.owner);
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);

    const pane = try handler.execute(.{ .bytes = "raw" }, .{ .attachment_modal_active = true });
    try std.testing.expectEqual(Owner.pane, pane.owner);
    try std.testing.expectEqualSlices(Event, &.{.pane}, capture.events[0..capture.event_count]);
    try std.testing.expectEqualStrings("raw", capture.command.?.bytes);

    capture = .{};
    handler = .{ .effects = capture.effects() };
    const prompt = try handler.execute(.{ .bytes = "name" }, .{
        .attachment_modal_active = true,
        .prompt_active = true,
        .copy_mode_active = true,
    });
    try std.testing.expectEqual(Owner.name_prompt, prompt.owner);
    try std.testing.expectEqualSlices(Event, &.{.prompt}, capture.events[0..capture.event_count]);

    capture = .{};
    handler = .{ .effects = capture.effects() };
    const copy = try handler.execute(.{ .bytes = "ignored" }, .{ .copy_mode_active = true });
    try std.testing.expectEqual(Owner.copy_mode, copy.owner);
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "clipboard preview follows one confirmed pane delivery and cannot fail the key" {
    const control_v = try keybind.parseKey("ctrl+v");
    var capture: Capture = .{ .failure = .preview };
    var handler: KeyRoutingHandler = .{ .effects = capture.effects() };

    const delivered = try handler.execute(.{ .key = control_v }, .{});
    try std.testing.expect(delivered.delivered);
    try std.testing.expectEqualSlices(Event, &.{ .pane, .preview }, capture.events[0..capture.event_count]);

    capture = .{ .pane_delivered = false };
    handler = .{ .effects = capture.effects() };
    const unavailable = try handler.execute(.{ .key = control_v }, .{});
    try std.testing.expect(!unavailable.delivered);
    try std.testing.expectEqualSlices(Event, &.{.pane}, capture.events[0..capture.event_count]);

    capture = .{};
    handler = .{ .effects = capture.effects() };
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
        handler = .{ .effects = capture.effects() };
        _ = try handler.execute(.{ .key = key }, .{});
        try std.testing.expectEqualSlices(Event, &.{.pane}, capture.events[0..capture.event_count]);
    }
}

test "selected key owner failures propagate without falling through" {
    var capture: Capture = .{ .failure = .prompt };
    var handler: KeyRoutingHandler = .{ .effects = capture.effects() };

    try std.testing.expectError(
        error.PromptInputFailed,
        handler.execute(.{ .bytes = "name" }, .{
            .prompt_active = true,
            .copy_mode_active = true,
        }),
    );
    try std.testing.expectEqualSlices(Event, &.{.prompt}, capture.events[0..capture.event_count]);

    capture = .{ .failure = .copy_key };
    handler = .{ .effects = capture.effects() };
    try std.testing.expectError(
        error.CopyModeInputFailed,
        handler.execute(.{ .key = try keybind.parseKey("x") }, .{ .copy_mode_active = true }),
    );
    try std.testing.expectEqualSlices(Event, &.{.copy_key}, capture.events[0..capture.event_count]);

    capture = .{ .failure = .pane };
    handler = .{ .effects = capture.effects() };
    try std.testing.expectError(error.PaneInputFailed, handler.execute(.{ .bytes = "raw" }, .{}));
    try std.testing.expectEqualSlices(Event, &.{.pane}, capture.events[0..capture.event_count]);
}
