//! Application policy for assigning each streamed paste phase to one owner.

const std = @import("std");

pub const Command = union(enum) {
    start,
    /// Borrowed only for the synchronous routing effect.
    content: []const u8,
    finish,
};

pub const Authority = struct {
    attachment_modal_active: bool = false,
    prompt_active: bool = false,
    prompt_pasting: bool = false,
    copy_mode_active: bool = false,
    pane_paste_active: bool = false,
};

pub const Owner = enum {
    prompt,
    pane,
};

pub const Outcome = enum {
    ignored,
    prompt_owned,
    pane_owned,
};

pub const Route = struct {
    owner: Owner,
    command: Command,
};

pub const Effects = struct {
    context: *anyopaque,
    route: *const fn (*anyopaque, Route) anyerror!void,
};

pub const PasteRoutingHandler = struct {
    effects: Effects,

    /// Resolves one paste phase against a fixed authority snapshot and sends
    /// it to at most one owner.
    ///
    /// ```zig
    /// const outcome = try handler.execute(authority, command);
    /// ```
    pub fn execute(handler: *PasteRoutingHandler, authority: Authority, command: Command) !Outcome {
        const owner = resolve(authority, command) orelse return .ignored;

        try handler.effects.route(handler.effects.context, .{
            .owner = owner,
            .command = command,
        });

        return switch (owner) {
            .prompt => .prompt_owned,
            .pane => .pane_owned,
        };
    }
};

fn resolve(authority: Authority, command: Command) ?Owner {
    return switch (command) {
        .start => if (authority.attachment_modal_active)
            null
        else if (authority.prompt_active)
            .prompt
        else if (authority.copy_mode_active)
            null
        else
            .pane,
        .content, .finish => if (authority.pane_paste_active)
            .pane
        else if (authority.prompt_pasting)
            .prompt
        else
            null,
    };
}

const Capture = struct {
    route_value: ?Route = null,
    calls: usize = 0,
    fail: bool = false,

    fn effects(capture: *Capture) Effects {
        return .{ .context = capture, .route = route };
    }

    fn route(raw_context: *anyopaque, value: Route) !void {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        capture.calls += 1;
        capture.route_value = value;

        if (capture.fail) {
            return error.PasteRouteFailed;
        }
    }
};

test "PasteRoutingHandler assigns paste start by modal prompt and copy authority" {
    const cases = [_]struct {
        authority: Authority,
        outcome: Outcome,
    }{
        .{ .authority = .{ .attachment_modal_active = true, .prompt_active = true }, .outcome = .ignored },
        .{ .authority = .{ .prompt_active = true }, .outcome = .prompt_owned },
        .{ .authority = .{ .copy_mode_active = true }, .outcome = .ignored },
        .{ .authority = .{}, .outcome = .pane_owned },
    };

    for (cases) |case| {
        var capture: Capture = .{};
        var handler: PasteRoutingHandler = .{ .effects = capture.effects() };

        try std.testing.expectEqual(case.outcome, try handler.execute(case.authority, .start));
        try std.testing.expectEqual(@as(usize, @intFromBool(case.outcome != .ignored)), capture.calls);
    }
}

test "PasteRoutingHandler keeps later phases with their established owner" {
    var capture: Capture = .{};
    var handler: PasteRoutingHandler = .{ .effects = capture.effects() };
    const competing: Authority = .{
        .attachment_modal_active = true,
        .prompt_active = true,
        .prompt_pasting = true,
        .copy_mode_active = true,
        .pane_paste_active = true,
    };

    try std.testing.expectEqual(Outcome.pane_owned, try handler.execute(competing, .{ .content = "one" }));
    try std.testing.expectEqual(Owner.pane, capture.route_value.?.owner);
    try std.testing.expectEqualStrings("one", capture.route_value.?.command.content);

    capture = .{};
    handler = .{ .effects = capture.effects() };
    var prompt = competing;
    prompt.pane_paste_active = false;
    try std.testing.expectEqual(Outcome.prompt_owned, try handler.execute(prompt, .finish));
    try std.testing.expectEqual(Owner.prompt, capture.route_value.?.owner);

    capture = .{};
    handler = .{ .effects = capture.effects() };
    prompt.prompt_pasting = false;
    try std.testing.expectEqual(Outcome.ignored, try handler.execute(prompt, .{ .content = "lost" }));
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
}

test "PasteRoutingHandler propagates the selected owner failure without fallback" {
    var capture: Capture = .{ .fail = true };
    var handler: PasteRoutingHandler = .{ .effects = capture.effects() };

    try std.testing.expectError(
        error.PasteRouteFailed,
        handler.execute(.{ .prompt_active = true }, .start),
    );
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(Owner.prompt, capture.route_value.?.owner);
}
