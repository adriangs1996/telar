//! Presentation-owned targets plus client-owned transient editor state.
const std_module = @import("std");
const Registry = @import("Registry.zig");
const native = @import("../../native/native.zig");
const core = @import("telar-core");
const labels = @import("labels.zig");
const client = @import("telar-client");
const Canvas = @import("../Canvas.zig");
const GenericPresentedState = @import("../../render/GenericPresentedState.zig").Type;
const Dispatcher = @import("Dispatcher.zig");
const Geometry = @import("EditorGeometry.zig");
const Preedit = @import("Preedit.zig");
const Target = @import("Target.zig");
const Id = @import("Id.zig");
const CompletionsState = @import("CompletionState.zig");
const CopyFeedback = @import("../CopyFeedback.zig");
const MessageLinkPreview = @import("../MessageLinkPreview.zig");
const TabDropSlots = @import("TabDropSlots.zig");
const TabMotions = @import("../TabMotions.zig");
const PasteBuffer = @import("PasteBuffer.zig");
const ThreadExpansions = @import("ThreadExpansions.zig");
const ThreadScrollAnchor = @import("ThreadScrollAnchor.zig");
const ThreadScrollMotions = @import("ThreadScrollMotions.zig");
const ThreadSelection = @import("ThreadSelection.zig");
const ThreadTextStore = @import("ThreadTextStore.zig");
const MessageLayoutCache = @import("../MessageLayoutCache.zig");
const MessageHeights = @import("../MessageHeights.zig");
const ImagePreview = @import("ImagePreview.zig");
const AgentReview = @import("AgentReview.zig");
const ComposerMenuState = @import("ComposerMenuState.zig");
const PendingCut = @import("PendingCut.zig");
const PendingPaste = @import("PendingPaste.zig");
const ThreadCopy = @import("ThreadCopy.zig");
const ThreadItemControl = @import("ThreadItemControl.zig");
const FrameClock = @import("../../animation/FrameClock.zig");
const ChromeRegistration = @import("ChromeRegistration.zig");
const Overlays = @import("../overlays/Overlays.zig");
const TabMoveIntent = ?client.TabMoveIntent;

const State = @This();

dispatcher: Dispatcher = .{},
completions: CompletionsState = .{},
message_link_preview: ?MessageLinkPreview = null,
copy_feedback: CopyFeedback = .{},
tab_drag: client.TabDrag = .{},
tab_drag_step: f64 = 4,
tab_drop_slots: TabDropSlots = .{},
tab_motions: TabMotions = .{},
tab_pointer: [2]f64 = .{ 0, 0 },
tab_grab_offset: f64 = 0,
tab_drop_pending: TabMoveIntent = null,
editors: GenericPresentedState(Editors) = .{},
preedit: Preedit = .{},
prompt_generation: u64 = 0,
paste_owner: ?Id = null,
paste_consumed: bool = false,
paste_buffer: PasteBuffer = .{},
paste_selection: [2]u32 = .{ 0, 0 },
paste_revision: u64 = 0,
directory_scroll_remainder: f64 = 0,
history_scroll_remainder: f64 = 0,
thread_expansions: ThreadExpansions = .{},
thread_anchor: ThreadScrollAnchor = .{},
thread_scroll: ThreadScrollMotions = .{},
thread_selection: ThreadSelection = .{},
thread_text: ?*ThreadTextStore = null,
message_layout: ?*MessageLayoutCache = null,
message_layout_allocator: std_module.mem.Allocator = undefined,
message_heights: ?*MessageHeights = null,
image_preview: ?ImagePreview = null,
approval_review: ?AgentReview = null,
composer_menu: ComposerMenuState = .{},
history_scroll_generation: u64 = 0,
history_scroll_inspecting: bool = false,
native_nodes: [Registry.capacity]native.AccessibilityNode = undefined,
pending_cuts: [4]?PendingCut = @splat(null),
pending_pastes: [4]?PendingPaste = @splat(null),
pending_thread_copies: [4]?ThreadCopy = @splat(null),
copied_item: ?ThreadItemControl = null,
copied_until_ns: u64 = 0,

/// Includes reads still converting an image, so send cannot strand a late attachment.
/// Example: `if (state.pastingImage(pane_id)) disableSend();`
pub fn pastingImage(self: *const State, pane_id: core.PaneId) bool {
    for (self.pending_pastes) |pending| {
        const paste = pending orelse continue;
        const target = self.dispatcher.maps.presented().find(paste.owner) orelse continue;
        if (target.action == .composer and target.action.composer == pane_id) {
            return true;
        }
    }

    return false;
}

/// Reserves bounded geometry for long messages during frame preparation only.
/// Example: `const cache = try state.messageLayout(canvas.atlas.allocator);`
pub fn messageLayout(self: *State, allocator: std_module.mem.Allocator) !*MessageLayoutCache {
    if (self.message_layout == null) {
        const cache = try allocator.create(MessageLayoutCache);
        cache.* = .{};
        self.message_layout = cache;
        self.message_layout_allocator = allocator;
    }

    return self.message_layout.?;
}

/// Retains message heights once a conversation is measured; shares the
/// layout cache allocator. Example: `const heights = try state.messageHeights(allocator);`
pub fn messageHeights(self: *State, allocator: std_module.mem.Allocator) !*MessageHeights {
    _ = try self.messageLayout(allocator);
    if (self.message_heights == null) {
        const heights = try self.message_layout_allocator.create(MessageHeights);
        heights.* = .{};
        self.message_heights = heights;
    }

    return self.message_heights.?;
}

/// Owns text hit geometry only when an agent conversation is prepared.
/// Example: `const text = try state.threadText(canvas.atlas.allocator);`
pub fn threadText(self: *State, allocator: std_module.mem.Allocator) !*ThreadTextStore {
    if (self.thread_text == null) {
        const store = try allocator.create(ThreadTextStore);
        store.* = .{ .allocator = allocator };
        self.thread_text = store;
    }
    return self.thread_text.?;
}

/// Releases disposable geometry after the host stops delivering frames.
/// Example: `state.deinit();`
pub fn deinit(self: *State) void {
    if (self.thread_text) |store| {
        store.allocator.destroy(store);
        self.thread_text = null;
    }
    if (self.message_heights) |heights| {
        self.message_layout_allocator.destroy(heights);
        self.message_heights = null;
    }

    if (self.message_layout) |cache| {
        self.message_layout_allocator.destroy(cache);
        self.message_layout = null;
    }
}

/// Call only when the copy indicator is visible. Example: `const copied = state.threadCopied(control, canvas.animation);`
pub fn threadCopied(self: *const State, control: ThreadItemControl, animation: ?*FrameClock) bool {
    const copied = self.copied_item orelse return false;
    const clock = animation orelse return false;
    if (!copied.sameItem(control) or clock.now_ns >= self.copied_until_ns) {
        return false;
    }

    clock.requestAt(self.copied_until_ns);
    return true;
}

/// Example: `if (state.threadExpanded(control)) drawToolOutput();`
pub fn threadExpanded(self: *const State, control: ThreadItemControl) bool {
    return self.thread_expansions.contains(control);
}

/// Cancelling provisional text changes pixels even when committed text and
/// selection stay untouched. Example: `state.cancelComposition();`
pub fn cancelComposition(self: *State) void {
    if (self.preedit.owner != null) {
        self.preedit.clear();
        self.dispatcher.revision +%= 1;
    }
}

/// Example: `state.begin(projection.prompt != null);`
pub fn begin(self: *State, modal: bool) void {
    self.thread_anchor.prepared = null;
    self.dispatcher.begin().modal_layer = if (modal) 1 else 0;
    _ = self.editors.begin();
    if (self.thread_text) |store| {
        _ = store.maps.begin();
    }
}

/// Imports existing chrome's semantic controls with their exact rectangles.
/// Example: `try state.chrome(canvas, &chrome);`
pub fn chrome(self: *State, canvas: *Canvas, input: ChromeRegistration) !void {
    self.tab_drag_step = canvas.chrome.px(4);
    const value = input.chrome;
    if (value.prepared().bands.sidebar.width > 0) {
        _ = try self.dispatcher.add((Target{ .bounds = value.prepared().bands.sidebar, .action = .{ .custom = 1 }, .namespace = 1, .focusable = false, .role = 6 }).labelled("Agents"));
    }

    for (value.prepared().band_hits.items[0..value.prepared().band_hits.len]) |hit| {
        const action: Target.Action = switch (hit.action) {
            .intent => |intent| if (intent == .none) continue else .{ .intent = intent },
            .resize_sidebar => .resize_sidebar,
            .pane_content => continue,
        };
        const target: Target = .{ .bounds = hit.area, .action = action, .focusable = action != .resize_sidebar };
        _ = try self.dispatcher.add(target.labelled(labels.forAction(input.projection, action)));
    }

    if (self.dispatcher.focused) |id| {
        if (self.dispatcher.maps.prepared().find(id)) |target| {
            if (target.action != .text_field and target.action != .composer and self.dispatcher.maps.prepared().modal_layer == 0) {
                try canvas.ringAt(target.bounds, .{ .color = canvas.theme.palette.accent, .width = 1, .radius = 4 });
            }
        }
    }
}

/// Imports modal result rows after their field, preserving painter priority.
/// Example: `try state.overlays(canvas, &overlays);`
pub fn overlays(self: *State, canvas: *Canvas, value: *Overlays) !void {
    const notifications = &value.prepared().notifications;
    for (notifications.hits[0..notifications.count]) |hit| {
        _ = try self.dispatcher.add(hit);
    }

    const palette = &value.prepared().palette;
    for (palette.rows[0..palette.count], 0..) |row, index| {
        _ = try self.dispatcher.add(.{ .id = .{ .generation = self.prompt_generation }, .bounds = canvas.rect(row), .action = .{ .intent = .{ .prompt_row = palette.first + @as(u16, @intCast(index)) } }, .layer = 1, .focusable = false });
    }
}

/// Example: `state.seal();`
pub fn seal(self: *State) void {
    self.dispatcher.seal();
    self.editors.seal();
    if (self.thread_text) |store| {
        store.maps.seal();
    }
}

/// Example: `state.present(delivered);`
pub fn present(self: *State, delivered: bool) void {
    self.dispatcher.present(delivered);
    self.editors.present(delivered);
    if (self.thread_text) |store| {
        store.maps.present(delivered);
    }
    if (!delivered) {
        return;
    }

    if (self.composer_menu.selector != null) {
        var found = false;
        for (self.dispatcher.maps.presented().targets[0..self.dispatcher.maps.presented().len]) |target| {
            if (target.action == .composer_choice and target.action.composer_choice.menu_generation == self.composer_menu.generation and target.action.composer_choice.index == self.composer_menu.selected) {
                _ = self.dispatcher.focus(target.id);
                found = true;
                break;
            }
        }

        if (!found) {
            self.composer_menu.selector = null;
        }
    }

    if (self.image_preview != null) {
        for (self.dispatcher.maps.presented().targets[0..self.dispatcher.maps.presented().len]) |target| {
            if (target.layer == 1 and target.focusable and target.action == .agent_control and target.action.agent_control.kind == .close_image) {
                _ = self.dispatcher.focus(target.id);
                break;
            }
        }
    }

    if (self.composer_menu.selector == null and self.image_preview == null) {
        for (self.editors.presented().items[0..self.editors.presented().len]) |editor| {
            if (editor.preferred) {
                if (self.dispatcher.focusedTarget()) |focused| {
                    if (focused.action == .composer_selector or focused.action == .agent_control or focused.action == .thread_item or focused.action == .transcript) {
                        break;
                    }
                }

                _ = self.dispatcher.focus(editor.id);
                break;
            }
        }
    }

    if (self.preedit.owner) |owner| {
        if (self.dispatcher.focused == null or !self.dispatcher.focused.?.eql(owner)) {
            self.preedit.clear();
        }
    }
}

test "long message geometry is lazy reusable and released by its original allocator" {
    const std = @import("std");
    var state: State = .{};
    defer state.deinit();
    try std.testing.expect(state.message_layout == null);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, state.messageLayout(failing.allocator()));
    try std.testing.expect(state.message_layout == null);
    const retained = try state.messageLayout(std.testing.allocator);
    try std.testing.expectEqual(retained, try state.messageLayout(failing.allocator()));
    try std.testing.expect(@sizeOf(MessageLayoutCache) <= 256 * 1024);
    state.deinit();
    try std.testing.expect(state.message_layout == null);
}

const Editors = struct {
    pub const capacity = 16;
    items: [capacity]Geometry = undefined,
    len: usize = 0,

    /// Example: `try editors.add(geometry);`
    pub fn add(self: *Editors, geometry: Geometry) !void {
        if (self.len == capacity) {
            return error.WidgetEditorCapacityExceeded;
        }

        self.items[self.len] = geometry;
        self.len += 1;
    }

    /// Example: `const geometry = editors.find(target.id) orelse return;`
    pub fn find(self: *const Editors, id: Id) ?Geometry {
        for (self.items[0..self.len]) |item| {
            if (item.id.eql(id)) {
                return item;
            }
        }

        return null;
    }
};
