//! Application boundary for the bounded client name prompt.

const std = @import("std");
const name_prompt = @import("../../model/name_prompt.zig");

pub const SubmitEffects = struct {
    context: *anyopaque,
    submit: *const fn (*anyopaque, name_prompt.Submission) anyerror!bool,
};

pub const Outcome = enum {
    unchanged,
    routing_changed,
    changed,
    cancelled,
    /// The palette asked to delete its selected entry; the controller owns
    /// the wire effect.
    removed,
    blocked,
    finished,
};

pub const NamePromptHandler = struct {
    prompt: *name_prompt.State,
    effects: SubmitEffects,

    /// Applies one editor command and closes the prompt only after its submit
    /// effect accepts the borrowed submission.
    ///
    /// ```zig
    /// const outcome = try handler.execute(.submit);
    /// ```
    pub fn execute(handler: *NamePromptHandler, command: name_prompt.Command) !Outcome {
        return switch (handler.prompt.apply(command)) {
            .unchanged => .unchanged,
            .routing_changed => .routing_changed,
            .changed => .changed,
            .cancelled => .cancelled,
            .removed => .removed,
            .submitted => |submission| if (!try handler.effects.submit(
                handler.effects.context,
                submission,
            ))
                .blocked
            else blk: {
                std.debug.assert(handler.prompt.finish(submission.target));
                break :blk .finished;
            },
        };
    }
};

const EffectsCapture = struct {
    prompt: *const name_prompt.State,
    accept: bool = true,
    fail: bool = false,
    calls: usize = 0,
    observed_active: bool = false,
    name: [32]u8 = undefined,
    name_len: u8 = 0,

    fn port(capture: *EffectsCapture) SubmitEffects {
        return .{ .context = capture, .submit = submit };
    }

    fn submit(context: *anyopaque, submission: name_prompt.Submission) !bool {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.observed_active = capture.prompt.active();
        capture.name_len = @intCast(submission.name.len);
        @memcpy(capture.name[0..submission.name.len], submission.name);

        if (capture.fail) {
            return error.SubmitFailed;
        }

        return capture.accept;
    }

    fn nameSlice(capture: *const EffectsCapture) []const u8 {
        return capture.name[0..capture.name_len];
    }
};

test "accepted submission stays borrowed and active until the effect returns" {
    var prompt: name_prompt.State = .{};
    var capture: EffectsCapture = .{ .prompt = &prompt };
    var handler: NamePromptHandler = .{
        .prompt = &prompt,
        .effects = capture.port(),
    };
    prompt.begin(.create_workspace);
    _ = try handler.execute(.{ .insert = "agents" });

    try std.testing.expect(try handler.execute(.submit) == .finished);

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.observed_active);
    try std.testing.expectEqualStrings("agents", capture.nameSlice());
    try std.testing.expect(!prompt.active());
}

test "blocked and failed submissions retain the prompt" {
    var prompt: name_prompt.State = .{};
    var capture: EffectsCapture = .{
        .prompt = &prompt,
        .accept = false,
    };
    var handler: NamePromptHandler = .{
        .prompt = &prompt,
        .effects = capture.port(),
    };
    prompt.begin(.{ .rename_tab = .{ .tab_id = @enumFromInt(1), .label = "main" } });

    try std.testing.expect(try handler.execute(.submit) == .blocked);
    try std.testing.expect(prompt.active());

    capture.accept = true;
    capture.fail = true;
    try std.testing.expectError(error.SubmitFailed, handler.execute(.submit));
    try std.testing.expect(prompt.active());
    try std.testing.expectEqualStrings("main", prompt.currentConst().?.field.text());
}

test "editor and cancellation transitions never call submit effects" {
    var prompt: name_prompt.State = .{};
    var capture: EffectsCapture = .{ .prompt = &prompt };
    var handler: NamePromptHandler = .{
        .prompt = &prompt,
        .effects = capture.port(),
    };
    prompt.begin(.create_workspace);

    try std.testing.expect(try handler.execute(.{ .insert = "a" }) == .changed);
    try std.testing.expect(try handler.execute(.cancel) == .cancelled);
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
}
