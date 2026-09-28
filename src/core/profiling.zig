const std = @import("std");
const root = @import("root");
const ProfileCounters = @import("ProfileCounters.zig");

pub const enabled = @hasDecl(root, "telar_profile_counts") and root.telar_profile_counts;
pub const timing_enabled = @hasDecl(root, "telar_profile_timing") and root.telar_profile_timing;
pub const active = enabled or timing_enabled;
pub const catalog_version = 1;
pub const max_threads = 64;
pub const max_metrics = 128;
pub const Metric = enum {
    review_draw,
    review_search_rows,
    review_search_bytes,
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
        .review_draw => "calls",
        .review_search_rows => "rows",
        .review_search_bytes => "logical_bytes",
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
    };
}

/// Names the measured code boundary. Example: `const source = profiling.source(.gui_draw);`
pub fn source(metric: Metric) []const u8 {
    return switch (metric) {
        .review_draw => "Paint.draw",
        .review_search_rows => "Paint.searchStatus",
        .review_search_bytes => "Paint.searchStatus",
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
    };
}

/// Explains inclusion limits. Example: `const coverage = profiling.coverage(.gui_draw);`
pub fn coverage(metric: Metric) []const u8 {
    return switch (metric) {
        .review_draw => "review draw entry",
        .review_search_rows => "file rows traversed to compute match count",
        .review_search_bytes => "sum of searched line lengths, not repeated substring probes",
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
