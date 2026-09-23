//! Application policy binding local previews to one agent prompt's image markers.
const core = @import("telar-core");
const model_data = @import("model");

const std = @import("std");

/// Maps the marker scheme an agent's manifest declares to the client policy
/// that binds previews to prompt markers.
///
/// ```zig
/// const policy = markerPolicy(.pasted_path);
/// ```
pub fn markerPolicy(markers: core.AgentAttachmentMarkers) model_data.AttachmentMarkerPolicy {
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
pub fn backslashContinuesPrompt(policy: model_data.AttachmentMarkerPolicy) bool {
    return policy != .ordered;
}

/// Reports whether one accepted key may remove a learned marker from the
/// child's editor. Atomic placeholders only vanish on Backspace or Delete;
/// Pi's plain-text path also yields to its word and line deletion bindings.
///
/// ```zig
/// if (editsMarkers(policy, key)) store.expectMarkerDeletion(target);
/// ```
pub fn editsMarkers(policy: model_data.AttachmentMarkerPolicy, key: model_data.Key) bool {
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

fn isLetter(key: model_data.Key, letter: u8) bool {
    return switch (key.code) {
        .char => |char| char.len == 1 and std.ascii.toLower(char.bytes[0]) == letter,
        else => false,
    };
}

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
    const backspace: model_data.Key = .{ .code = .backspace };
    try std.testing.expect(editsMarkers(.pasted_path, backspace));
    try std.testing.expect(editsMarkers(.stable_number, backspace));
    try std.testing.expect(!editsMarkers(.ordered, backspace));
    try std.testing.expect(!editsMarkers(.pasted_path, .{ .code = .backspace, .phase = .release }));

    const word_backward: model_data.Key = .{ .code = .{ .char = .init("w") }, .mods = .{ .ctrl = true } };
    try std.testing.expect(editsMarkers(.pasted_path, word_backward));
    try std.testing.expect(!editsMarkers(.stable_number, word_backward));
    try std.testing.expect(editsMarkers(.pasted_path, .{ .code = .backspace, .mods = .{ .alt = true } }));
    try std.testing.expect(editsMarkers(.pasted_path, .{ .code = .{ .char = .init("k") }, .mods = .{ .ctrl = true } }));
    try std.testing.expect(!editsMarkers(.pasted_path, .{ .code = .{ .char = .init("v") }, .mods = .{ .ctrl = true } }));
    try std.testing.expect(!editsMarkers(.pasted_path, .{ .code = .{ .char = .init("a") } }));
}
