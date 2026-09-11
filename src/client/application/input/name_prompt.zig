//! Application boundary for the bounded client name prompt.

const NamePromptState = @import("../../model/NamePromptState.zig");
const NamePromptEffectsCapture = @import("NamePromptEffectsCapture.zig");
const NamePromptHandler = @import("NamePromptHandler.zig");
const std = @import("std");

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

test "accepted submission stays borrowed and active until the effect returns" {
    var prompt: NamePromptState = .{};
    var capture: NamePromptEffectsCapture = .{ .prompt = &prompt };
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
    var prompt: NamePromptState = .{};
    var capture: NamePromptEffectsCapture = .{
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
    var prompt: NamePromptState = .{};
    var capture: NamePromptEffectsCapture = .{ .prompt = &prompt };
    var handler: NamePromptHandler = .{
        .prompt = &prompt,
        .effects = capture.port(),
    };
    prompt.begin(.create_workspace);

    try std.testing.expect(try handler.execute(.{ .insert = "a" }) == .changed);
    try std.testing.expect(try handler.execute(.cancel) == .cancelled);
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
}
