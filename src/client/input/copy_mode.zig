//! Copy mode: enters and leaves copy mode and applies its commands and search
//! matches.
const data = @import("model");
const copy_mode_tests = @import("../copy_mode_tests.zig");
const core = @import("telar-core");
const name_prompt = @import("name_prompt.zig");
const link_opening = @import("../links/link_opening.zig");
const pane_viewport = @import("../panes/pane_viewport.zig");
const Client = @import("../execution/Client.zig");

/// Semantic actions include native conversation readers in copy-mode policy.
/// Example: `_ = copy_mode.copyModeActive(client);`
pub fn copyModeActive(client: *const Client) bool {
    return data.copy_mode.isActive(&client.model) or client.host_input_source.threadCopyModeActive();
}

/// Leaves copy mode without copying the current selection.
/// Example: `_ = try copy_mode.leaveCopyMode(client);`
pub fn leaveCopyMode(client: *Client) !CopyModeOutcome {
    const outcome = try applyCopyMode(client, .leave);
    const native = client.host_input_source.leaveThreadCopyMode();
    return if (outcome == .unchanged and native) .exited else outcome;
}

/// Example: `_ = try copy_mode.applyCopyMode(client, command);`
pub fn applyCopyMode(client: *Client, command: data.CopyModeCommand) !CopyModeOutcome {
    defer {
        if (command == .cancel_pointer or (command == .pointer and command.pointer.release)) {
            data.copy_mode.finishPointerGesture(&client.model);
        }
    }

    const plan = data.copy_mode.planCommand(&client.model, command) orelse return .unchanged;
    if (plan.open_link) |target| {
        _ = try link_opening.openLink(client, target);

        return .unchanged;
    }

    if (plan.selection) |selection| {
        try client.model.to_runtime.push(
            .{
                .copy_selection = selection,
            },
        );
    }

    const commit = data.copy_mode.commitPlan(&client.model, plan) orelse return .unchanged;
    if (commit.viewport) |viewport| {
        try pane_viewport.deliverPaneViewport(client, viewport);
    }

    if (plan.search) |direction| {
        _ = name_prompt.openNamePrompt(
            &client.model,
            .{
                .copy_search = direction,
            },
        );
    }

    return if (commit.active) .changed else .exited;
}

/// Enters copy mode on the attached focused pane.
pub fn enterCopyMode(client: *Client) bool {
    const tab = client.model.tabs.activeSlot() orelse return false;
    const pane = data.tab_layout.focusedPaneConst(&client.model, tab) orelse return false;
    if (pane.kind == .agent) {
        if (!pane.attached or data.copy_mode.isActive(&client.model) or client.model.name_prompt.active() or client.model.pane_paste != null) {
            return false;
        }

        return client.host_input_source.enterThreadCopyMode(pane.id);
    }

    return data.copy_mode.enter(&client.model);
}

/// Applies one runtime search reply to the active copy-mode state.
pub fn applyPaneMatches(client: *Client, view: core.PaneMatchesView) !CopyModeOutcome {
    var storage: [core.max_search_matches]core.SearchMatch = undefined;
    var count: usize = 0;
    var iterator = view.matches();
    while (try iterator.next()) |match| {
        if (count == storage.len) {
            break;
        }
        storage[count] = match;
        count += 1;
    }

    return applyCopyMode(
        client,
        .{
            .matches = .{
                .pane_id = view.pane_id,
                .matches = storage[0..count],
            },
        },
    );
}

test "copy mode delegates agent readers after admission and preserves terminal behavior" {
    try copy_mode_tests.agentReaders(enterCopyMode);
}

const CopyModeOutcome = enum {
    unchanged,
    changed,
    exited,
};
