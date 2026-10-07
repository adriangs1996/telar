//! Application policy binding local previews to one agent prompt's image markers.
const keyinput = @import("keyinput");
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
pub fn editsMarkers(policy: model_data.AttachmentMarkerPolicy, key: keyinput.Key) bool {
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

fn isLetter(key: keyinput.Key, letter: u8) bool {
    return switch (key.code) {
        .char => |char| char.len == 1 and std.ascii.toLower(char.bytes[0]) == letter,
        else => false,
    };
}
