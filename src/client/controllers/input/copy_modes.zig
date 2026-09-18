//! Adapts client ports to the copy-mode application use case.

const Client = @import("../../AttachedClient.zig");
const PointerPressType = @import("../../input/PointerPress.zig");
const PointerMotionType = @import("../../input/PointerMotion.zig");
const ApplicationInputCopyModeOutcome = @import("../../application/input/copy_mode.zig").Outcome;
const KeyType = @import("../../input/Key.zig");
const PaneMatchesViewType = @import("telar-core").PaneMatchesView;
const max_search_matches = @import("telar-core").max_search_matches;
const SearchMatchType = @import("telar-core").SearchMatch;
const CopyModeHandlerType = @import("../../application/input/CopyModeHandler.zig");
const pane_viewports = @import("../panes/pane_viewports.zig");
const TargetType = @import("../../links/LinkTarget.zig");
const link_openings = @import("link_openings.zig");
const InputCopyModeDirection = @import("../../input/copy_mode.zig").Direction;
const name_prompts_module = @import("name_prompts.zig");
const CopySelectionType = @import("telar-core").CopySelection;
const runtime_transport = @import("../../entrypoints/runtime_io.zig");

/// Semantic actions include native conversation readers in copy-mode policy.
/// Example: `if (copy_modes.active(client)) try copy_modes.leave(client);`
pub fn active(client: *const Client) bool {
    return client.model.copyModeActive() or client.host_input_source.threadCopyModeActive();
}

/// Enters copy mode on the attached focused pane.
///
/// ```zig
/// _ = enter(client);
/// ```
pub fn enter(client: *Client) bool {
    const tab = client.model.activeTabModelConst() orelse return false;
    const pane = tab.focusedPaneConst() orelse return false;
    if (pane.kind == .agent) {
        if (!pane.attached or client.model.copyModeActive() or client.model.name_prompt.active() or client.model.pane_paste != null) {
            return false;
        }

        return client.host_input_source.enterThreadCopyMode(pane.id);
    }

    var use_case = handler(client);

    return use_case.enter();
}

/// Starts a pane-local mouse selection after focus and ownership resolution.
/// Example: `_ = beginPointer(client, press);`.
pub fn beginPointer(client: *Client, press: PointerPressType) bool {
    var use_case = handler(client);

    return use_case.beginPointer(press);
}

/// Extends or copies the captured mouse selection through the copy transaction.
/// Example: `_ = try pointer(client, motion);`.
pub fn pointer(client: *Client, motion: PointerMotionType) !ApplicationInputCopyModeOutcome {
    var use_case = handler(client);

    return use_case.execute(.{ .pointer = motion });
}

/// Cancels mouse highlighting and physical capture without touching keyboard copy mode.
/// Example: `_ = try cancelPointer(client);`.
pub fn cancelPointer(client: *Client) !ApplicationInputCopyModeOutcome {
    var use_case = handler(client);

    return use_case.execute(.cancel_pointer);
}

/// Routes one host key through copy-mode semantics.
///
/// ```zig
/// _ = try key(client, pressed);
/// ```
pub fn key(client: *Client, pressed: KeyType) !ApplicationInputCopyModeOutcome {
    var use_case = handler(client);

    return use_case.execute(.{ .key = pressed });
}

/// Moves the copy cursor vertically from a host-wheel delta.
///
/// ```zig
/// _ = try vertical(client, -3);
/// ```
pub fn vertical(client: *Client, delta: i32) !ApplicationInputCopyModeOutcome {
    var use_case = handler(client);

    return use_case.execute(.{ .vertical = delta });
}

/// Leaves copy mode without copying the current selection.
///
/// ```zig
/// _ = try leave(client);
/// ```
pub fn leave(client: *Client) !ApplicationInputCopyModeOutcome {
    var use_case = handler(client);
    const outcome = try use_case.execute(.leave);
    const native = client.host_input_source.leaveThreadCopyMode();
    return if (outcome == .unchanged and native) .exited else outcome;
}

/// Applies one runtime search reply to the active copy-mode state.
///
/// ```zig
/// _ = try matches(client, view);
/// ```
pub fn matches(client: *Client, view: PaneMatchesViewType) !ApplicationInputCopyModeOutcome {
    var storage: [max_search_matches]SearchMatchType = undefined;
    var count: usize = 0;
    var iterator = view.matches();
    while (try iterator.next()) |match| {
        if (count == storage.len) {
            break;
        }
        storage[count] = match;
        count += 1;
    }

    var use_case = handler(client);
    return use_case.execute(.{ .matches = .{ .pane_id = view.pane_id, .matches = storage[0..count] } });
}

fn handler(client: *Client) CopyModeHandlerType {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .copy = copySelection,
            .open_search = openSearch,
            .open_link = openLink,
            .viewport = pane_viewports.effects(client),
        },
    };
}

fn openLink(context: *anyopaque, target: TargetType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    _ = try link_openings.apply(client, target);
}

fn openSearch(context: *anyopaque, direction: InputCopyModeDirection) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const name_prompts = name_prompts_module;

    _ = name_prompts.beginCopySearch(client, direction);
}

fn copySelection(context: *anyopaque, selection: CopySelectionType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try runtime_transport.enqueue(client, .{ .copy_selection = selection });
}

test "copy mode delegates agent readers after admission and preserves terminal behavior" {
    const std = @import("std");
    const core = @import("telar-core");
    const app = try std.testing.allocator.create(Client);
    defer std.testing.allocator.destroy(app);
    app.* = undefined;
    app.model = @import("../../model/Model.zig").init(std.testing.allocator, true);
    defer app.model.deinit();
    const pane_id: core.PaneId = @enumFromInt(1);
    try app.model.workspace.bootstrap(.{ .pane_id = pane_id, .location = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) }, .size = .{ .cols = 10, .rows = 5 } });
    const pane = app.model.workspace.findPane(pane_id).?;
    pane.kind = .agent;
    var received: ?core.PaneId = null;
    app.host_input_source = .{ .context = &received, .resume_read_fn = undefined, .route_prompt_bytes_fn = undefined, .adopt_bindings_fn = undefined };
    const revision = app.model.copy_revision;
    try std.testing.expect(!enter(app));
    try std.testing.expect(!active(app));
    try std.testing.expect(app.model.copy_state == null);
    app.host_input_source.enter_thread_copy_mode_fn = captureThreadCopyMode;
    app.host_input_source.thread_copy_mode_active_fn = threadCopyModeActive;
    app.host_input_source.leave_thread_copy_mode_fn = leaveThreadCopyMode;
    try std.testing.expect(enter(app));
    try std.testing.expectEqual(pane_id, received.?);
    try std.testing.expect(app.model.copy_state == null);
    try std.testing.expectEqual(revision, app.model.copy_revision);
    try std.testing.expect(active(app));
    try std.testing.expectEqual(.exited, try leave(app));
    try std.testing.expect(!active(app));
    try std.testing.expect(received == null);
    pane.attached = false;
    try std.testing.expect(!enter(app));
    pane.attached = true;
    app.model.name_prompt.begin(.create_workspace);
    try std.testing.expect(!enter(app));
    app.model.name_prompt = .{};
    app.model.pane_paste = .{ .pane_id = pane_id, .bracketed_paste = false };
    try std.testing.expect(!enter(app));
    app.model.pane_paste = null;
    try std.testing.expect(received == null);
    pane.kind = .terminal;
    try std.testing.expect(enter(app));
    try std.testing.expect(app.model.copyModeActive());
    try std.testing.expect(received == null);
}

fn captureThreadCopyMode(context: *anyopaque, pane_id: @import("telar-core").PaneId) bool {
    const received: *?@import("telar-core").PaneId = @ptrCast(@alignCast(context));
    received.* = pane_id;
    return true;
}

fn threadCopyModeActive(context: *anyopaque) bool {
    const received: *?@import("telar-core").PaneId = @ptrCast(@alignCast(context));
    return received.* != null;
}

fn leaveThreadCopyMode(context: *anyopaque) bool {
    const received: *?@import("telar-core").PaneId = @ptrCast(@alignCast(context));
    const changed = received.* != null;
    received.* = null;
    return changed;
}
