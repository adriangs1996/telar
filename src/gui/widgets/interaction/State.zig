//! Presentation-owned targets plus client-owned transient editor state.
const Canvas = @import("../Canvas.zig");
const GenericPresentedState = @import("../../render/GenericPresentedState.zig").Type;
const Dispatcher = @import("Dispatcher.zig");
const Editors = @import("Editors.zig");
const Preedit = @import("Preedit.zig");
const Target = @import("Target.zig");
const Id = @import("Id.zig");
const State = @This();

dispatcher: Dispatcher = .{},
completions: @import("CompletionState.zig") = .{},
message_link_preview: ?@import("../MessageLinkPreview.zig") = null,
tab_drag: @import("telar-client").TabDrag = .{},
tab_drag_step: f64 = 4,
tab_drop_slots: @import("TabDropSlots.zig") = .{},
tab_motions: @import("../TabMotions.zig") = .{},
tab_pointer: [2]f64 = .{ 0, 0 },
tab_grab_offset: f64 = 0,
tab_drop_pending: ?@import("telar-client").TabMoveIntent = null,
editors: GenericPresentedState(Editors) = .{},
preedit: Preedit = .{},
prompt_generation: u64 = 0,
paste_owner: ?Id = null,
paste_consumed: bool = false,
paste_buffer: @import("PasteBuffer.zig") = .{},
paste_selection: [2]u32 = .{ 0, 0 },
paste_revision: u64 = 0,
directory_scroll_remainder: f64 = 0,
history_scroll_remainder: f64 = 0,
thread_scroll_remainder: f64 = 0,
thread_scroll_owner: ?Id = null,
thread_expansions: @import("ThreadExpansions.zig") = .{},
thread_anchor: @import("ThreadScrollAnchor.zig") = .{},
thread_selection: @import("ThreadSelection.zig") = .{},
thread_text: ?*@import("ThreadTextStore.zig") = null,
message_layout: ?*@import("../MessageLayoutCache.zig") = null,
message_layout_allocator: @import("std").mem.Allocator = undefined,
image_preview: ?@import("ImagePreview.zig") = null,
approval_review: ?@import("AgentReview.zig") = null,
composer_menu: @import("ComposerMenuState.zig") = .{},
history_scroll_generation: u64 = 0,
history_scroll_inspecting: bool = false,
native_nodes: [@import("Registry.zig").capacity]@import("../../native/native.zig").AccessibilityNode = undefined,
pending_cuts: [4]?@import("PendingCut.zig") = @splat(null),
pending_pastes: [4]?@import("PendingPaste.zig") = @splat(null),
pending_thread_copies: [4]?@import("ThreadCopy.zig") = @splat(null),
copied_item: ?@import("ThreadItemControl.zig") = null,
copied_until_ns: u64 = 0,

/// Includes reads still converting an image, so send cannot strand a late attachment.
/// Example: `if (state.pastingImage(pane_id)) disableSend();`
pub fn pastingImage(state: *const State, pane_id: @import("telar-core").PaneId) bool {
    for (state.pending_pastes) |pending| {
        const paste = pending orelse continue;
        const target = state.dispatcher.maps.presented().find(paste.owner) orelse continue;
        if (target.action == .composer and target.action.composer == pane_id) {
            return true;
        }
    }

    return false;
}

/// Reserves bounded geometry for long messages during frame preparation only.
/// Example: `const cache = try state.messageLayout(canvas.atlas.allocator);`
pub fn messageLayout(state: *State, allocator: @import("std").mem.Allocator) !*@import("../MessageLayoutCache.zig") {
    if (state.message_layout == null) {
        const cache = try allocator.create(@import("../MessageLayoutCache.zig"));
        cache.* = .{};
        state.message_layout = cache;
        state.message_layout_allocator = allocator;
    }

    return state.message_layout.?;
}

/// Owns text hit geometry only when an agent conversation is prepared.
/// Example: `const text = try state.threadText(canvas.atlas.allocator);`
pub fn threadText(state: *State, allocator: @import("std").mem.Allocator) !*@import("ThreadTextStore.zig") {
    if (state.thread_text == null) {
        const store = try allocator.create(@import("ThreadTextStore.zig"));
        store.* = .{ .allocator = allocator };
        state.thread_text = store;
    }
    return state.thread_text.?;
}

/// Releases disposable geometry after the host stops delivering frames.
/// Example: `state.deinit();`
pub fn deinit(state: *State) void {
    if (state.thread_text) |store| {
        store.allocator.destroy(store);
        state.thread_text = null;
    }
    if (state.message_layout) |cache| {
        state.message_layout_allocator.destroy(cache);
        state.message_layout = null;
    }
}

/// Call only when the copy indicator is visible. Example: `const copied = state.threadCopied(control, canvas.animation);`
pub fn threadCopied(state: *const State, control: @import("ThreadItemControl.zig"), animation: ?*@import("../../animation/FrameClock.zig")) bool {
    const copied = state.copied_item orelse return false;
    const clock = animation orelse return false;
    if (!copied.sameItem(control) or clock.now_ns >= state.copied_until_ns) {
        return false;
    }

    clock.requestAt(state.copied_until_ns);
    return true;
}

/// Example: `if (state.threadExpanded(control)) drawToolOutput();`
pub fn threadExpanded(state: *const State, control: @import("ThreadItemControl.zig")) bool {
    return state.thread_expansions.contains(control);
}

/// Cancelling provisional text changes pixels even when committed text and
/// selection stay untouched. Example: `state.cancelComposition();`
pub fn cancelComposition(state: *State) void {
    if (state.preedit.owner != null) {
        state.preedit.clear();
        state.dispatcher.revision +%= 1;
    }
}

/// Example: `state.begin(projection.prompt != null);`
pub fn begin(state: *State, modal: bool) void {
    state.thread_anchor.prepared = null;
    state.dispatcher.begin().modal_layer = if (modal) 1 else 0;
    _ = state.editors.begin();
    if (state.thread_text) |store| {
        _ = store.maps.begin();
    }
}

/// Imports existing chrome's semantic controls with their exact rectangles.
/// Example: `try state.chrome(canvas, &chrome);`
pub fn chrome(state: *State, canvas: *Canvas, input: @import("ChromeRegistration.zig")) !void {
    state.tab_drag_step = canvas.chrome.px(4);
    const value = input.chrome;
    if (value.prepared().bands.sidebar.width > 0) {
        _ = try state.dispatcher.add((Target{ .bounds = value.prepared().bands.sidebar, .action = .{ .custom = 1 }, .namespace = 1, .focusable = false, .role = 6 }).labelled("Agents"));
    }

    for (value.prepared().band_hits.items[0..value.prepared().band_hits.len]) |hit| {
        const action: Target.Action = switch (hit.action) {
            .intent => |intent| if (intent == .none) continue else .{ .intent = intent },
            .resize_sidebar => .resize_sidebar,
            .pane_content => continue,
        };
        const target: Target = .{ .bounds = hit.area, .action = action, .focusable = action != .resize_sidebar };
        _ = try state.dispatcher.add(target.labelled(@import("labels.zig").forAction(input.projection, action)));
    }

    if (state.dispatcher.focused) |id| {
        if (state.dispatcher.maps.prepared().find(id)) |target| {
            if (target.action != .text_field and target.action != .composer and state.dispatcher.maps.prepared().modal_layer == 0) {
                try canvas.ringAt(target.bounds, .{ .color = canvas.theme.palette.accent, .width = 1, .radius = 4 });
            }
        }
    }
}

/// Imports modal result rows after their field, preserving painter priority.
/// Example: `try state.overlays(canvas, &overlays);`
pub fn overlays(state: *State, canvas: *Canvas, value: *@import("../overlays/Overlays.zig")) !void {
    const notifications = &value.prepared().notifications;
    for (notifications.hits[0..notifications.count]) |hit| {
        _ = try state.dispatcher.add(hit);
    }

    const palette = &value.prepared().palette;
    for (palette.rows[0..palette.count], 0..) |row, index| {
        _ = try state.dispatcher.add(.{ .id = .{ .generation = state.prompt_generation }, .bounds = canvas.rect(row), .action = .{ .intent = .{ .prompt_row = palette.first + @as(u16, @intCast(index)) } }, .layer = 1, .focusable = false });
    }
}

/// Example: `state.seal();`
pub fn seal(state: *State) void {
    state.dispatcher.seal();
    state.editors.seal();
    if (state.thread_text) |store| {
        store.maps.seal();
    }
}

/// Example: `state.present(delivered);`
pub fn present(state: *State, delivered: bool) void {
    state.dispatcher.present(delivered);
    state.editors.present(delivered);
    if (state.thread_text) |store| {
        store.maps.present(delivered);
    }
    if (!delivered) {
        return;
    }

    if (state.composer_menu.selector != null) {
        var found = false;
        for (state.dispatcher.maps.presented().targets[0..state.dispatcher.maps.presented().len]) |target| {
            if (target.action == .composer_choice and target.action.composer_choice.menu_generation == state.composer_menu.generation and target.action.composer_choice.index == state.composer_menu.selected) {
                _ = state.dispatcher.focus(target.id);
                found = true;
                break;
            }
        }

        if (!found) {
            state.composer_menu.selector = null;
        }
    }

    if (state.image_preview != null) {
        for (state.dispatcher.maps.presented().targets[0..state.dispatcher.maps.presented().len]) |target| {
            if (target.layer == 1 and target.focusable and target.action == .agent_control and target.action.agent_control.kind == .close_image) {
                _ = state.dispatcher.focus(target.id);
                break;
            }
        }
    }

    if (state.composer_menu.selector == null and state.image_preview == null) {
        for (state.editors.presented().items[0..state.editors.presented().len]) |editor| {
            if (editor.preferred) {
                if (state.dispatcher.focusedTarget()) |focused| {
                    if (focused.action == .composer_selector or focused.action == .agent_control or focused.action == .thread_item or focused.action == .transcript) {
                        break;
                    }
                }

                _ = state.dispatcher.focus(editor.id);
                break;
            }
        }
    }

    if (state.preedit.owner) |owner| {
        if (state.dispatcher.focused == null or !state.dispatcher.focused.?.eql(owner)) {
            state.preedit.clear();
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
    try std.testing.expect(@sizeOf(@import("../MessageLayoutCache.zig")) <= 256 * 1024);
    state.deinit();
    try std.testing.expect(state.message_layout == null);
}
