//! Which pane frames one presentation carried, and retiring exactly those
//! after the host confirms delivery (docs/invariants.md#presentation-delivery).
const std = @import("std");
const ClientModel = @import("../state/ClientModel.zig");
const PresentationCommit = @import("PresentationCommit.zig");

/// Captures every pane of tab `slot`, including panes hidden by fullscreen.
/// Example: `const commit = presentation_delivery.capture(model, slot);`
pub fn capture(model: *const ClientModel, slot: usize) PresentationCommit {
    const location = model.tabs.location[slot];
    var commit: PresentationCommit = .{};
    var panes = model.panes.iterateConst(location.tab_id);
    while (panes.next()) |pane| {
        commit.location = location;
        commit.append(pane);
    }

    return commit;
}

/// Retires only the damage and frame ids a successful presentation
/// carried. A stale commit cannot consume newer pane work.
/// Example: `const accepted = presentation_delivery.retire(model, commit);`
pub fn retire(model: *ClientModel, commit: PresentationCommit) PresentationCommit {
    const location = commit.location orelse return .{};
    const slot = model.tabs.find(location.tab_id) orelse return .{};
    if (!std.meta.eql(model.tabs.location[slot], location) or model.panes.countIn(location.tab_id) == 0) {
        return .{};
    }

    var accepted: PresentationCommit = .{ .location = location };
    for (commit.slice()) |presented| {
        const pane = model.panes.findIn(location.tab_id, presented.pane_id) orelse continue;
        if (pane.attached != presented.attached or pane.attachment_generation != presented.attachment_generation) {
            continue;
        }

        pane.commitPresentation(presented.frame_id);
        accepted.panes[accepted.len] = presented;
        accepted.len += 1;
    }

    return accepted;
}
