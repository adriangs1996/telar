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

/// Enters copy mode on the attached focused pane.
///
/// ```zig
/// _ = enter(client);
/// ```
pub fn enter(client: *Client) bool {
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

    return use_case.execute(.leave);
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
