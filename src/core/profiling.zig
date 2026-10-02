const std = @import("std");
const root = @import("root");
const ProfileCounters = @import("ProfileCounters.zig");

pub const enabled = @hasDecl(root, "telar_profile_counts") and root.telar_profile_counts;
pub const timing_enabled = @hasDecl(root, "telar_profile_timing") and root.telar_profile_timing;
pub const active = enabled or timing_enabled;
pub const catalog_version = 2;
pub const max_threads = 64;
pub const max_metrics = 128;
pub const Metric = enum {
    tui_compose,
    tui_flush,

    gui_update,
    gui_dispatch,
    gui_input_drain,
    gui_draw,
    gui_complete,
    client_receive,
    client_apply_frame,
    pane_apply_frame,
    pane_find,
    pane_find_found,
    pane_iterator,
    pane_slots,
    layout_query,
    layout_rebuild,
    gui_scene,
    gui_pane_draw,
    gui_cell_visit,
    gui_ink_visit,
    mesh_compare,
    mesh_hit,
    mesh_rebuild,
    mesh_items,
    gui_quads,
    runtime_ingest,
    runtime_ingest_bytes,
    runtime_blit,
    runtime_damage,
    runtime_rows,
    runtime_scanned_cells,
    runtime_equal,
    pane_copy_cells,
    pane_copy_bytes,

    // One per `Runtime.update` call, by event tag. `Runtime.zig` fails to
    // compile when a tag has no metric here.
    runtime_event_execution_finished,
    runtime_event_accepted,
    runtime_event_handshaken,
    runtime_event_client_message,
    runtime_event_client_sent,
    runtime_event_cell_publication_due,
    runtime_event_history_response,
    runtime_event_pane_input_written,
    runtime_event_pane_response_written,
    runtime_event_pane_output,
    runtime_event_pane_ingested,
    runtime_event_pane_observed,
    runtime_event_pane_media,
    runtime_event_pane_exit,
    runtime_event_pane_search,
    runtime_event_pane_descent,
    runtime_event_telemetry_tick,
    runtime_event_telemetry_written,
    runtime_event_proxy_capture,
    runtime_event_plugin_effects,
    runtime_event_agent_tick,
    runtime_event_agent_description,
    runtime_event_engine_response,
    runtime_event_metrics_tick,
    runtime_event_metrics_sampled,
    runtime_event_checkpoint_written,
    runtime_event_git_status,
    runtime_event_worktree_git,
    runtime_event_worktree_detected,
    runtime_event_editor_opened,
    runtime_event_session_name,
    runtime_event_path_index_built,
    runtime_event_paths_found,
    runtime_event_stopped,

    runtime_flush,
    runtime_flush_passes,
    runtime_pane_slots,
    runtime_live_panes,
    runtime_prepare,
    runtime_pending_scans,
    runtime_attachment_slots,
    runtime_eligibility_checks,
    runtime_eligible_attachments,
    runtime_lane_offers,
    runtime_foreground_slots,
    runtime_commits,
    runtime_attachment_commits,
    runtime_cell_commits,
};
pub const Phase = enum { gui_draw, gui_scene, runtime_ingest, client_frame };
threadlocal var registered: bool = false;
threadlocal var local: ?*ProfileCounters = null;

comptime {
    std.debug.assert(std.enums.values(Metric).len <= max_metrics);
}

/// Adds work to this thread's bank. Example: `profiling.add(.gui_draw, 1);`
pub inline fn add(metric: Metric, amount: u64) void {
    if (comptime enabled) {
        if (bank()) |counters| {
            counters.add(metric, amount);
        }
    }
}

/// Reads the wall clock only in timing builds. Example: `const start = profiling.start(io);`
pub inline fn start(io: std.Io) u64 {
    if (comptime timing_enabled) {
        return @intCast(@max(0, std.Io.Clock.awake.now(io).nanoseconds));
    }
    return 0;
}

/// Records a synchronous phase. Example: `profiling.finish(io, .gui_draw, start);`
pub inline fn finish(io: std.Io, phase: Phase, started: u64) void {
    if (comptime timing_enabled) {
        if (bank()) |counters| {
            counters.histograms[@intFromEnum(phase)].observe(start(io) -| started);
        }
    }
}

/// Copies only the current writer's counters. Example: `const before = profiling.snapshot();`
pub fn snapshot() ProfileCounters {
    if (comptime active) {
        if (bank()) |counters| {
            return counters.*;
        }
    }
    return .{};
}

/// Describes the exact catalog coverage. Example: `const unit = profiling.unit(.gui_draw);`
pub fn unit(metric: Metric) []const u8 {
    return switch (metric) {
        .tui_compose => "calls",
        .tui_flush => "calls",

        .gui_update => "calls",
        .gui_dispatch => "events",
        .gui_input_drain => "calls",
        .gui_draw => "calls",
        .gui_complete => "calls",
        .client_receive => "calls",
        .client_apply_frame => "calls",
        .pane_apply_frame => "calls",
        .pane_find => "calls",
        .pane_find_found => "lookups",
        .pane_iterator => "calls",
        .pane_slots => "slots",
        .layout_query => "calls",
        .layout_rebuild => "snapshots",
        .gui_scene => "calls",
        .gui_pane_draw => "calls",
        .gui_cell_visit => "cells",
        .gui_ink_visit => "cells",
        .mesh_compare => "calls",
        .mesh_hit => "cells",
        .mesh_rebuild => "cells",
        .mesh_items => "calls",
        .gui_quads => "quads",
        .runtime_ingest => "calls",
        .runtime_ingest_bytes => "bytes",
        .runtime_blit => "calls",
        .runtime_damage => "calls",
        .runtime_rows => "rows",
        .runtime_scanned_cells => "cells",
        .runtime_equal => "calls",
        .pane_copy_cells => "cells",
        .pane_copy_bytes => "logical_bytes",

        .runtime_event_execution_finished,
        .runtime_event_accepted,
        .runtime_event_handshaken,
        .runtime_event_client_message,
        .runtime_event_client_sent,
        .runtime_event_cell_publication_due,
        .runtime_event_history_response,
        .runtime_event_pane_input_written,
        .runtime_event_pane_response_written,
        .runtime_event_pane_output,
        .runtime_event_pane_ingested,
        .runtime_event_pane_observed,
        .runtime_event_pane_media,
        .runtime_event_pane_exit,
        .runtime_event_pane_search,
        .runtime_event_pane_descent,
        .runtime_event_telemetry_tick,
        .runtime_event_telemetry_written,
        .runtime_event_proxy_capture,
        .runtime_event_plugin_effects,
        .runtime_event_agent_tick,
        .runtime_event_agent_description,
        .runtime_event_engine_response,
        .runtime_event_metrics_tick,
        .runtime_event_metrics_sampled,
        .runtime_event_checkpoint_written,
        .runtime_event_git_status,
        .runtime_event_worktree_git,
        .runtime_event_worktree_detected,
        .runtime_event_editor_opened,
        .runtime_event_session_name,
        .runtime_event_path_index_built,
        .runtime_event_paths_found,
        .runtime_event_stopped => "events",

        .runtime_flush => "calls",
        .runtime_flush_passes => "passes",
        .runtime_pane_slots => "slots",
        .runtime_live_panes => "panes",
        .runtime_prepare => "calls",
        .runtime_pending_scans => "calls",
        .runtime_attachment_slots => "slots",
        .runtime_eligibility_checks => "calls",
        .runtime_eligible_attachments => "attachments",
        .runtime_lane_offers => "calls",
        .runtime_foreground_slots => "slots",
        .runtime_commits => "messages",
        .runtime_attachment_commits => "messages",
        .runtime_cell_commits => "frames",
    };
}

/// Names the measured code boundary. Example: `const source = profiling.source(.gui_draw);`
pub fn source(metric: Metric) []const u8 {
    return switch (metric) {
        .tui_compose => "Compositor.render",
        .tui_flush => "Screen.flush",

        .gui_update => "GuiAdapter.update",
        .gui_dispatch => "GuiAdapter.dispatch",
        .gui_input_drain => "GuiAdapter.drainInput",
        .gui_draw => "GuiAdapter.draw",
        .gui_complete => "GuiAdapter.complete",
        .client_receive => "Client.receiveRuntime",
        .client_apply_frame => "Client.receivePaneFrame",
        .pane_apply_frame => "Pane.applyFrame",
        .pane_find => "MultiplexerModel.find/findConst",
        .pane_find_found => "MultiplexerModel.find/findConst",
        .pane_iterator => "GenericPaneIterator.next",
        .pane_slots => "GenericPaneIterator.next",
        .layout_query => "tab_layout.snapshot",
        .layout_rebuild => "tab_layout.snapshot",
        .gui_scene => "Scene.prepare",
        .gui_pane_draw => "TerminalRenderer.drawPane",
        .gui_cell_visit => "TerminalRenderer.drawPane",
        .gui_ink_visit => "TerminalRenderer.drawPane",
        .mesh_compare => "TerminalRenderer.drawPane -> CellMesh.matches",
        .mesh_hit => "TerminalRenderer.drawPane",
        .mesh_rebuild => "TerminalRenderer.drawPane -> CellMesh.replace",
        .mesh_items => "TerminalRenderer.drawPane -> CellMesh.items",
        .gui_quads => "TerminalRenderer.drawPane",
        .runtime_ingest => "pane_pipeline.ingestPane",
        .runtime_ingest_bytes => "pane_pipeline.ingestPane",
        .runtime_blit => "blit.blit",
        .runtime_damage => "damage.collectSpans",
        .runtime_rows => "damage.collectSpans",
        .runtime_scanned_cells => "damage.collectSpans",
        .runtime_equal => "damage.collectSpans -> Cell.eqlPublic",
        .pane_copy_cells => "Pane.applyFrame",
        .pane_copy_bytes => "Pane.applyFrame",

        .runtime_event_execution_finished,
        .runtime_event_accepted,
        .runtime_event_handshaken,
        .runtime_event_client_message,
        .runtime_event_client_sent,
        .runtime_event_cell_publication_due,
        .runtime_event_history_response,
        .runtime_event_pane_input_written,
        .runtime_event_pane_response_written,
        .runtime_event_pane_output,
        .runtime_event_pane_ingested,
        .runtime_event_pane_observed,
        .runtime_event_pane_media,
        .runtime_event_pane_exit,
        .runtime_event_pane_search,
        .runtime_event_pane_descent,
        .runtime_event_telemetry_tick,
        .runtime_event_telemetry_written,
        .runtime_event_proxy_capture,
        .runtime_event_plugin_effects,
        .runtime_event_agent_tick,
        .runtime_event_agent_description,
        .runtime_event_engine_response,
        .runtime_event_metrics_tick,
        .runtime_event_metrics_sampled,
        .runtime_event_checkpoint_written,
        .runtime_event_git_status,
        .runtime_event_worktree_git,
        .runtime_event_worktree_detected,
        .runtime_event_editor_opened,
        .runtime_event_session_name,
        .runtime_event_path_index_built,
        .runtime_event_paths_found,
        .runtime_event_stopped => "Runtime.update",

        .runtime_flush => "client_delivery.flush",
        .runtime_flush_passes => "client_delivery.flush",
        .runtime_pane_slots => "client_delivery.flush",
        .runtime_live_panes => "client_delivery.flush",
        .runtime_prepare => "Delivery.prepare",
        .runtime_pending_scans => "Delivery.pendingAttachments",
        .runtime_attachment_slots => "Delivery.pendingAttachments",
        .runtime_eligibility_checks => "Delivery.pendingAttachments -> Attachment.hasDelivery",
        .runtime_eligible_attachments => "Delivery.pendingAttachments -> Attachment.hasDelivery",
        .runtime_lane_offers => "Delivery.prepareAttachment -> Delivery.candidate",
        .runtime_foreground_slots => "Delivery.prepareForeground",
        .runtime_commits => "Delivery.commit",
        .runtime_attachment_commits => "Delivery.commit",
        .runtime_cell_commits => "Delivery.commit",
    };
}

/// Explains inclusion limits. Example: `const coverage = profiling.coverage(.gui_draw);`
pub fn coverage(metric: Metric) []const u8 {
    return switch (metric) {
        .tui_compose => "entry",
        .tui_flush => "entry",

        .gui_update => "function entry",
        .gui_dispatch => "all dispatched GUI events",
        .gui_input_drain => "function entry",
        .gui_draw => "includes rejected preparation",
        .gui_complete => "includes stale completions",
        .client_receive => "function entry",
        .client_apply_frame => "includes ignored frames",
        .pane_apply_frame => "model function entry",
        .pane_find => "both mutable and const entries",
        .pane_find_found => "successful index resolution",
        .pane_iterator => "includes exhausted iterator calls",
        .pane_slots => "slots inspected, including empty",
        .layout_query => "cached accessor only",
        .layout_rebuild => "cache misses only",
        .gui_scene => "function entry",
        .gui_pane_draw => "visible pane draws",
        .gui_cell_visit => "first-pass cells",
        .gui_ink_visit => "second-pass cells",
        .mesh_compare => "this call site only",
        .mesh_hit => "successful retained comparison",
        .mesh_rebuild => "this call site only",
        .mesh_items => "two per fully drawn cell",
        .gui_quads => "emitted terminal quads including cursor",
        .runtime_ingest => "worker entry",
        .runtime_ingest_bytes => "submitted bytes including failed attempts",
        .runtime_blit => "function entry",
        .runtime_damage => "function entry",
        .runtime_rows => "dirty rows visited",
        .runtime_scanned_cells => "dirty row lengths",
        .runtime_equal => "comparison sites in this function only",
        .pane_copy_cells => "successfully applied frame cells",
        .pane_copy_bytes => "applied cells multiplied by Cell size, not DRAM traffic",

        .runtime_event_execution_finished,
        .runtime_event_accepted,
        .runtime_event_handshaken,
        .runtime_event_client_message,
        .runtime_event_client_sent,
        .runtime_event_cell_publication_due,
        .runtime_event_history_response,
        .runtime_event_pane_input_written,
        .runtime_event_pane_response_written,
        .runtime_event_pane_output,
        .runtime_event_pane_ingested,
        .runtime_event_pane_observed,
        .runtime_event_pane_media,
        .runtime_event_pane_exit,
        .runtime_event_pane_search,
        .runtime_event_pane_descent,
        .runtime_event_telemetry_tick,
        .runtime_event_telemetry_written,
        .runtime_event_proxy_capture,
        .runtime_event_plugin_effects,
        .runtime_event_agent_tick,
        .runtime_event_agent_description,
        .runtime_event_engine_response,
        .runtime_event_metrics_tick,
        .runtime_event_metrics_sampled,
        .runtime_event_checkpoint_written,
        .runtime_event_git_status,
        .runtime_event_worktree_git,
        .runtime_event_worktree_detected,
        .runtime_event_editor_opened,
        .runtime_event_session_name,
        .runtime_event_path_index_built,
        .runtime_event_paths_found => "entry, before dispatch; includes events a limit stops",
        .runtime_event_stopped => "entry; no flush follows",

        .runtime_flush => "every caller: Runtime.update after each non-stop event, and IdleDelivery fixtures",
        .runtime_flush_passes => "delivery passes; a pass repeats only after a client drop",
        .runtime_pane_slots => "media and damage pass slots, including empty; not collect or foreground scans",
        .runtime_live_panes => "PaneStore.count at the media and damage pass, which changes no rows",
        .runtime_prepare => "every entry, including ones that stage nothing",
        .runtime_pending_scans => "prepare calls that reached the cell lane",
        .runtime_attachment_slots => "one client's attachment slots per scan, including empty",
        .runtime_eligibility_checks => "one per live attachment of the scanned client; not safe-build idle proofs",
        .runtime_eligible_attachments => "checks that answered true",
        .runtime_lane_offers => "candidate calls on pending attachments in every lane, staged, empty or failed; not safe-build idle proofs",
        .runtime_foreground_slots => "pane slots scanned for unattached foregrounds, including empty",
        .runtime_commits => "staged messages committed before their socket write, every effect",
        .runtime_attachment_commits => "commits of an attachment lane: cells, metadata, exit or graphics",
        .runtime_cell_commits => "attachment commits carrying a cell frame or snapshot",
    };
}

fn bank() ?*ProfileCounters {
    if (comptime active) {
        if (!registered) {
            local = root.profile_store.register(std.Thread.getCurrentId());
            registered = true;
        }
        return local;
    }
    return null;
}
