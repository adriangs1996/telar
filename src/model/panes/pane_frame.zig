//! A pane frame arriving from the runtime: admission against the pane's
//! applied base, cell replacement, and the acknowledgement or snapshot
//! request that answers it.
const copy_mode = @import("../input/copy_mode.zig");
const core = @import("telar-core");
const std = @import("std");
const ClientModel = @import("../state/ClientModel.zig");
const PaneFrameOutcome = @import("../model.zig").PaneFrameOutcome;

/// Applies one frame to an attached pane and queues its answer in
/// `model.to_runtime`: an acknowledgement when it applied, a snapshot
/// request when its base no longer matches. Detached and unknown panes
/// change nothing.
///
/// ```zig
/// const outcome = try pane_frame.receive(model, frame);
/// ```
pub fn receive(model: *ClientModel, frame: core.FrameView) !PaneFrameOutcome {
    const pane = model.panes.find(frame.pane_id) orelse return .detached;
    if (!pane.attached) {
        return .detached;
    }

    if (frame.base_frame_id != 0 and frame.base_frame_id != pane.applied_frame_id) {
        try model.to_runtime.push(.{
            .request_snapshot = .{
                .pane_id = frame.pane_id,
                .known_frame_id = pane.applied_frame_id,
            },
        });

        return .{
            .resync = .{
                .pane_id = frame.pane_id,
                .known_frame_id = pane.applied_frame_id,
            },
        };
    }

    const generation = if (pane.attachment_generation == 0) try model.allocateAttachmentGeneration() else pane.attachment_generation;
    const previous_scroll_offset = pane.scroll.offset;
    const applied = try pane.applyFrame(frame);
    pane.attach(generation);
    _ = copy_mode.reconcileFrame(model, .{
        .pane_id = frame.pane_id,
        .previous_offset = previous_scroll_offset,
        .scroll = frame.scroll,
    });
    model.frame_revision +%= 1;
    try model.to_runtime.push(.{
        .frame_ack = .{
            .pane_id = frame.pane_id,
            .frame_id = frame.frame_id,
        },
    });

    const active = model.activeTabLocation();
    return .{
        .applied = .{
            .pane_id = frame.pane_id,
            .location = pane.location,
            .frame_id = frame.frame_id,
            .graphics_visible = frame.scroll.atBottom(frame.rows) and
                active != null and std.meta.eql(active.?, pane.location),
            .snapshot = frame.base_frame_id == 0,
            .spans = applied.spans,
            .cells = applied.cells,
            .workspace_revision = model.workspace_revision,
            .tabs_revision = model.tabs_revision,
            .active_tab_revision = model.active_tab_revision,
            .panes_revision = model.panes_revision,
            .frame_revision = model.frame_revision,
        },
    };
}
