//! Owned input semantics for one delivered widget. No projection, text slice,
//! Canvas or widget pointer crosses the presentation boundary.
const Target = @This();

id: @import("Id.zig") = .{},
namespace: u64 = 0,
bounds: @import("../../render/Rect.zig"),
action: Action,
layer: u8 = 0,
focusable: bool = true,
enabled: bool = true,
accepts_pointer: bool = true,
role: u8 = 2,
scroll_limit: f64 = 0,
scroll_step: f32 = 0,
thread_header_offset: f32 = 0,
thread_first_key: u64 = 0,
thread_last_key: u64 = 0,
thread_first_offset: f32 = 0,
thread_last_offset: f32 = 0,
thread_window_revision: u64 = 0,
thread_live_revision: u64 = 0,
thread_history_generation: u64 = 0,
thread_scroll_value: f64 = 0,
thread_anchor_revision: u64 = 0,
thread_resolved_scroll: f64 = 0,
thread_reanchor: bool = false,
thread_skip_folded: bool = false,
thread_prefetch: ?@import("telar-core").agent_history.Direction = null,
thread_has_older: bool = false,
thread_has_newer: bool = false,
label: [128]u8 = undefined,
label_len: u8 = 0,
/// Editors with a domain-specific Tab action can opt out of traversal.
traverse_tab: bool = true,

pub const Field = enum { name, directory };
pub const PromptAction = enum { submit, cancel };
pub const Action = union(enum) {
    intent: @import("telar-client").Intent,
    text_field: Field,
    composer: @import("telar-core").PaneId,
    transcript: @import("telar-core").PaneId,
    thread_item: @import("ThreadItemControl.zig"),
    message_link: @import("MessageLinkControl.zig"),
    agent_control: @import("AgentControl.zig"),
    composer_selector: @import("ComposerSelector.zig"),
    composer_choice: @import("ComposerChoice.zig"),
    composer_completion: @import("CompletionChoice.zig"),
    prompt: PromptAction,
    complete_path: @import("PathCompletionChoice.zig"),
    history: @import("history_action.zig").Action,
    resize_sidebar,
    custom: u64,
};

/// Example: `const pane_id = target.paneId() orelse return;`
pub fn paneId(target: Target) ?@import("telar-core").PaneId {
    return switch (target.action) {
        .composer, .transcript => |id| id,
        .agent_control => |control| control.pane_id,
        .thread_item => |control| control.pane_id,
        .message_link => |control| control.owner.pane_id,
        .composer_selector => |selector| selector.pane_id,
        .composer_choice => |choice| choice.selector.pane_id,
        .composer_completion => |choice| choice.pane_id,
        else => null,
    };
}

/// Example: `if (target.activatable()) exposePressAction();`
pub fn activatable(target: Target) bool {
    return switch (target.action) {
        .intent, .prompt, .complete_path, .history, .agent_control, .composer_selector, .composer_choice, .composer_completion, .thread_item => true,
        else => false,
    };
}

/// Half-open device pixels shared with drawing.
/// Example: `if (target.contains(.{ pointer.x, pointer.y })) ...`
pub fn contains(target: Target, point: [2]f64) bool {
    return point[0] >= target.bounds.x and point[1] >= target.bounds.y and point[0] < @as(f64, target.bounds.x) + target.bounds.width and point[1] < @as(f64, target.bounds.y) + target.bounds.height;
}

/// Copies a short accessible label, preserving UTF-8 boundaries.
/// Example: `const target = value.labelled("Create tab");`
pub fn labelled(target: Target, text: []const u8) Target {
    var result = target;
    var len = @min(text.len, result.label.len);
    while (len > 0 and len < text.len and text[len] & 0xc0 == 0x80) {
        len -= 1;
    }

    @memcpy(result.label[0..len], text[0..len]);
    result.label_len = @intCast(len);
    return result;
}
