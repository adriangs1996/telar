//! Owned input semantics for one delivered widget. No projection, text slice,
//! Canvas or widget pointer crosses the presentation boundary.
const core = @import("telar-core");
const client = @import("telar-client");
const history_action = @import("history_action.zig");
const Id = @import("Id.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const ThreadItemControl = @import("ThreadItemControl.zig");
const MessageLinkControl = @import("MessageLinkControl.zig");
const AgentControl = @import("AgentControl.zig");
const ComposerSelector = @import("ComposerSelector.zig");
const ComposerChoice = @import("ComposerChoice.zig");
const CompletionChoice = @import("CompletionChoice.zig");
const PathCompletionChoice = @import("PathCompletionChoice.zig");
const Target = @This();

id: Id = .{},
namespace: u64 = 0,
bounds: Rect,
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
thread_prefetch: ?core.agent_history.Direction = null,
thread_has_older: bool = false,
thread_has_newer: bool = false,
label: [128]u8 = undefined,
label_len: u8 = 0,
/// Editors with a domain-specific Tab action can opt out of traversal.
traverse_tab: bool = true,

pub const Field = enum { name, directory };
pub const PromptAction = enum { submit, cancel };
pub const Action = union(enum) {
    intent: client.Intent,
    text_field: Field,
    composer: core.PaneId,
    change_review: core.PaneId,
    transcript: core.PaneId,
    thread_item: ThreadItemControl,
    message_link: MessageLinkControl,
    agent_control: AgentControl,
    composer_selector: ComposerSelector,
    composer_choice: ComposerChoice,
    composer_completion: CompletionChoice,
    prompt: PromptAction,
    complete_path: PathCompletionChoice,
    history: history_action.Action,
    resize_sidebar,
    custom: u64,
};

/// Example: `const pane_id = target.paneId() orelse return;`
pub fn paneId(self: Target) ?core.PaneId {
    return switch (self.action) {
        .composer, .transcript, .change_review => |id| id,
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
pub fn activatable(self: Target) bool {
    return switch (self.action) {
        .change_review, .intent, .prompt, .complete_path, .history, .agent_control, .composer_selector, .composer_choice, .composer_completion, .thread_item => true,
        else => false,
    };
}

/// Half-open device pixels shared with drawing.
/// Example: `if (target.contains(.{ pointer.x, pointer.y })) ...`
pub fn contains(self: Target, point: [2]f64) bool {
    return point[0] >= self.bounds.x and point[1] >= self.bounds.y and point[0] < @as(f64, self.bounds.x) + self.bounds.width and point[1] < @as(f64, self.bounds.y) + self.bounds.height;
}

/// Copies a short accessible label, preserving UTF-8 boundaries.
/// Example: `const target = value.labelled("Create tab");`
pub fn labelled(self: Target, text: []const u8) Target {
    var result = self;
    var len = @min(text.len, result.label.len);
    while (len > 0 and len < text.len and text[len] & 0xc0 == 0x80) {
        len -= 1;
    }

    @memcpy(result.label[0..len], text[0..len]);
    result.label_len = @intCast(len);
    return result;
}
