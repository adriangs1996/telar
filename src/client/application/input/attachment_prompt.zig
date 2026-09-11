//! Application policy binding local previews to one agent prompt's image markers.

const std = @import("std");
const core = @import("telar-core");
const attachments = @import("../../attachments/root.zig");
const input_capability = @import("../../input/root.zig");
const client_model = @import("../../root.zig").model;
const key_routing = @import("key_routing.zig");

const Key = input_capability.keybind.Key;
pub const schema = core.schema;

pub const RemovalCommand = @import("RemovalCommand.zig");

/// Maps the marker scheme an agent's manifest declares to the client policy
/// that binds previews to prompt markers.
///
/// ```zig
/// const policy = markerPolicy(.pasted_path);
/// ```
pub fn markerPolicy(markers: schema.AgentAttachmentMarkers) attachments.MarkerPolicy {
    return switch (markers) {
        .stable_number => .stable_number,
        .pasted_path => .pasted_path,
        .ordered, .none => .ordered,
    };
}

/// Reports whether the agent's editor turns Enter after a trailing backslash
/// into a newline. Claude and Pi do; Codex submits the prompt regardless.
///
/// ```zig
/// if (backslashContinuesPrompt(policy) and attachments.promptContinuesAtCursor(screen)) return;
/// ```
pub fn backslashContinuesPrompt(policy: attachments.MarkerPolicy) bool {
    return policy != .ordered;
}

/// Reports whether one accepted key may remove a learned marker from the
/// child's editor. Atomic placeholders only vanish on Backspace or Delete;
/// Pi's plain-text path also yields to its word and line deletion bindings.
///
/// ```zig
/// if (editsMarkers(policy, key)) store.expectMarkerDeletion(target);
/// ```
pub fn editsMarkers(policy: attachments.MarkerPolicy, key: Key) bool {
    if (key.phase == .release or !policy.learnsIdentity()) {
        return false;
    }

    const plain = !key.mods.ctrl and !key.mods.alt and !key.mods.shift;
    const char_deletion = key.code == .backspace or key.code == .delete;
    if (plain) {
        return char_deletion;
    }
    if (policy != .pasted_path or key.mods.shift) {
        return false;
    }
    if (key.mods.alt and !key.mods.ctrl) {
        return char_deletion or isLetter(key, 'd');
    }
    if (key.mods.ctrl and !key.mods.alt) {
        for ("dhwuk") |letter| {
            if (isLetter(key, letter)) {
                return true;
            }
        }
    }

    return false;
}

fn isLetter(key: Key, letter: u8) bool {
    return switch (key.code) {
        .char => |char| char.len == 1 and std.ascii.toLower(char.bytes[0]) == letter,
        else => false,
    };
}

pub const DismissEffects = @import("DismissEffects.zig");

pub const DismissAttachmentHandler = @import("DismissAttachmentHandler.zig");

pub const ObserveEffects = @import("ObserveEffects.zig");

pub const ObservePaneInputHandler = @import("ObservePaneInputHandler.zig");

pub const Event = enum {
    plan,
    deliver,
    remove,
};

const DismissCapture = @import("DismissCapture.zig");

test "marker policies follow each provider's prompt conventions" {
    try std.testing.expect(markerPolicy(.ordered) == .ordered);
    try std.testing.expect(markerPolicy(.none) == .ordered);
    try std.testing.expect(markerPolicy(.stable_number) == .stable_number);
    try std.testing.expect(markerPolicy(.pasted_path) == .pasted_path);
    try std.testing.expect(backslashContinuesPrompt(.stable_number));
    try std.testing.expect(backslashContinuesPrompt(.pasted_path));
    try std.testing.expect(!backslashContinuesPrompt(.ordered));
}

test "Pi path markers yield to word and line deletion keys" {
    const backspace: Key = .{ .code = .backspace };
    try std.testing.expect(editsMarkers(.pasted_path, backspace));
    try std.testing.expect(editsMarkers(.stable_number, backspace));
    try std.testing.expect(!editsMarkers(.ordered, backspace));
    try std.testing.expect(!editsMarkers(.pasted_path, .{ .code = .backspace, .phase = .release }));

    const word_backward: Key = .{ .code = .{ .char = .init("w") }, .mods = .{ .ctrl = true } };
    try std.testing.expect(editsMarkers(.pasted_path, word_backward));
    try std.testing.expect(!editsMarkers(.stable_number, word_backward));
    try std.testing.expect(editsMarkers(.pasted_path, .{ .code = .backspace, .mods = .{ .alt = true } }));
    try std.testing.expect(editsMarkers(.pasted_path, .{ .code = .{ .char = .init("k") }, .mods = .{ .ctrl = true } }));
    try std.testing.expect(!editsMarkers(.pasted_path, .{ .code = .{ .char = .init("v") }, .mods = .{ .ctrl = true } }));
    try std.testing.expect(!editsMarkers(.pasted_path, .{ .code = .{ .char = .init("a") } }));
}

test "preview dismissal deletes the child marker before retiring local media" {
    var capture: DismissCapture = .{ .layout_changed = true };
    var handler: DismissAttachmentHandler = .{ .effects = capture.effects() };

    try std.testing.expect(try handler.execute(@enumFromInt(3)));
    try std.testing.expectEqualSlices(Event, &.{ .plan, .deliver, .remove }, capture.events[0..capture.count]);

    capture = .{ .plan_available = false };
    handler = .{ .effects = capture.effects() };
    try std.testing.expect(!try handler.execute(@enumFromInt(3)));
    try std.testing.expectEqualSlices(Event, &.{.plan}, capture.events[0..capture.count]);
}

const ObserveCapture = @import("ObserveCapture.zig");

test "pane input mirrors marker deletion and submission into preview state" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const target: attachments.Target = .{ .pane_id = @enumFromInt(7), .pane_generation = 2 };
    var capture: ObserveCapture = .{ .target = target, .marker = @enumFromInt(3) };
    var handler: ObservePaneInputHandler = .{ .model = &model, .effects = capture.effects() };

    try std.testing.expect(!handler.execute(target.pane_id, .{ .key = .{ .code = .backspace } }));
    try std.testing.expectEqual(@as(attachments.Id, @enumFromInt(3)), capture.removed.?);

    _ = try model.beginClipboardCapture(target);
    try std.testing.expect(handler.execute(target.pane_id, .{ .key = .{ .code = .enter } }));
    try std.testing.expect(capture.prompt_removed);
    try std.testing.expect(model.clipboardCapture() == null);

    _ = try model.beginClipboardCapture(target);
    capture.marker = null;
    capture.pending_marker = true;
    try std.testing.expect(!handler.execute(target.pane_id, .{ .key = .{ .code = .delete } }));
    try std.testing.expect(model.clipboardCapture() == null);
}

test "an Enter the editor turns into a newline keeps previews and the capture" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const target: attachments.Target = .{ .pane_id = @enumFromInt(7), .pane_generation = 2 };
    var capture: ObserveCapture = .{ .target = target, .continues = true };
    var handler: ObservePaneInputHandler = .{ .model = &model, .effects = capture.effects() };

    _ = try model.beginClipboardCapture(target);
    try std.testing.expect(!handler.execute(target.pane_id, .{ .key = .{ .code = .enter } }));
    try std.testing.expect(!capture.prompt_removed);
    try std.testing.expect(model.clipboardCapture() != null);
}
