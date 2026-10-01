//! Limit reached, window side: the safety net that keeps a limit error in a
//! frame's draw or update from closing the window. The window keeps its
//! previous frame, the limit is reported through the client's
//! `limit_reached`, and drawing waits until what the frame shows or the
//! viewport changes. Meanwhile the title names the limit, because a frame
//! that keeps failing cannot show its notice. Any other error still closes
//! the window through `gui.fail`. See `docs/flows/limit-reached.md`.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const GuiAdapter = @import("GuiAdapter.zig");
const Registry = @import("widgets/interaction/Registry.zig");
const RetainedCells = @import("render/RetainedCells.zig");
const GlyphAtlas = @import("text/GlyphAtlas.zig");
const native = @import("native/native.zig");
const LimitedFrame = @import("LimitedFrame.zig");
const Scene = @import("render/Scene.zig");
const BandHitMap = @import("widgets/BandHitMap.zig");
const HitMap = @import("widgets/HitMap.zig");
const frame_widget = @import("widgets/frame_widget.zig");
const State = @import("widgets/interaction/State.zig");
const AccessibilityTree = @import("native/AccessibilityTree.zig");
const TerminalRenderer = @import("render/TerminalRenderer.zig");
const event = @import("input/event.zig");
const CellMesh = @import("render/CellMesh.zig");
const InputQueue = @import("InputQueue.zig");
const WindowLimit = @import("WindowLimit.zig").WindowLimit;
const PaneImages = @import("image/PaneImages.zig");

/// The largest display scale a report names; a larger one reports this.
const max_reported_scale: f32 = 1024;

/// The cells one grid may hold, which a window measuring more cuts to.
pub const cell_count_limit = core.Limit.declare("protocol.max_cell_count", "cells", core.max_cell_count);

/// Room for the title's suffix: its words and a full limit name.
pub const title_suffix_bytes = 32 + core.Limit.max_name_bytes;

/// Where in the window a frame stopped.
pub const Route = enum {
    window_draw,
    window_update,
};

/// Reports a capacity error and returns true when the window goes on;
/// returns false for any other error, which the caller fails with.
///
/// ```zig
/// if (!limit_reached.absorb(gui, .window_update, err)) gui.fail(err);
/// ```
pub fn absorb(gui: *GuiAdapter, route: Route, err: anyerror) bool {
    switch (route) {
        inline else => |known| client.limit_reached.absorb(gui.app, @tagName(known), err, limitOf(err)) catch return false,
    }

    return true;
}

/// `absorb` for a frame drawn for `viewport`, which the window then holds
/// until what it shows or the viewport changes.
///
/// ```zig
/// if (!limit_reached.absorbFrame(gui, viewport, err)) gui.fail(err);
/// ```
pub fn absorbFrame(gui: *GuiAdapter, viewport: native.Viewport, err: anyerror) bool {
    if (!absorb(gui, .window_draw, err)) {
        return false;
    }

    // The notice above is part of what this frame would show, so the
    // window retries only once something after it changes.
    const name = if (limitOf(err)) |limit| limit.name else @errorName(err);
    gui.limited = LimitedFrame.init(gui.observation(), viewport, name);

    // A pump refreshes the title, which names the limit.
    gui.wake();
    return true;
}

/// What the window's title ends with while a frame is held at a limit;
/// empty otherwise.
/// Example: `const suffix = limit_reached.titleSuffix(gui, &buffer);`
pub fn titleSuffix(gui: *const GuiAdapter, buffer: *[title_suffix_bytes]u8) []const u8 {
    const limited = gui.limited orelse return "";
    return std.fmt.bufPrint(buffer, " \u{2014} limit reached: {s}", .{limited.limitName()}) catch "";
}

/// Reports the tables the frame just prepared filled: widgets, targets and
/// editors it drew without, since each table keeps what fits and counts the
/// rest. Called on the window loop after the scene prepared.
///
/// ```zig
/// limit_reached.reportFrame(gui, &scene);
/// ```
pub fn reportFrame(gui: *GuiAdapter, scene: *const Scene) void {
    const chrome = gui.chrome.prepared();
    reportDropped(gui, .frame_widgets, frame_widget.limit, frame_widget.capacity, scene.dropped_widgets);
    reportDropped(gui, .band_hits, BandHitMap.limit, chrome.band_hits.len, chrome.band_hits.dropped);
    reportDropped(gui, .cell_hits, HitMap.limit, chrome.hits.len, chrome.hits.dropped);

    const targets = gui.widgets.dispatcher.maps.prepared();
    reportDropped(gui, .widget_targets, Registry.limit, targets.len, targets.dropped);

    const editors = gui.widgets.editors.prepared();
    reportDropped(gui, .editors, State.editors_limit, editors.len, editors.dropped);

    const quads = &gui.renderer.quads;
    reportDropped(gui, .frame_quads, frameQuadLimit(gui), quads.items().len, quads.dropped);

    const cell_quads = &gui.renderer.cell_quads;
    reportDropped(gui, .cell_quads, CellMesh.limit, CellMesh.capacity, cell_quads.dropped);

    reportDropped(gui, .image_placements, PaneImages.limit, gui.images.placement_count, gui.images.dropped);
}

/// The quads this frame reserved: its cells, overlays and chrome.
fn frameQuadLimit(gui: *const GuiAdapter) core.Limit {
    return core.Limit.declare("render.frame_quad_budget", "quads", gui.renderer.quads.limit orelse 0);
}

/// The input callback's net: an event refused at a limit is reported under
/// the table that refused it and dropped alone. Returns false for any other
/// error, which the caller fails with.
/// Example: `if (!limit_reached.absorbInput(gui, decoded, err)) gui.fail(err);`
pub fn absorbInput(gui: *GuiAdapter, input: ?event.Event, err: anyerror) bool {
    const large = if (input) |value| switch (value) {
        .text => |text| text.target_id == 0,
        .paste, .clipboard => true,
        else => false,
    } else true;
    const limit: ?core.Limit = switch (err) {
        error.NativeInputFull => InputQueue.queue_limit,
        error.InputPoolFull => if (large) InputQueue.large_slots_limit else InputQueue.small_slots_limit,
        error.InputTooLarge => if (large) event.clipboard_limit else InputQueue.small_limit,
        else => null,
    };

    client.limit_reached.absorb(gui.app, "window_input", err, limit) catch return false;
    return true;
}

/// The viewport the window draws: a display scale past the renderer's
/// bound draws at the bound, with smaller glyphs, and is reported.
/// Example: `const viewport = limit_reached.boundViewport(gui, native_viewport);`
pub fn boundViewport(gui: *GuiAdapter, viewport: native.Viewport) native.Viewport {
    if (!(viewport.scale > TerminalRenderer.max_display_scale)) {
        reportEntering(gui, .display_scale, null);
        return viewport;
    }

    reportEntering(
        gui,
        .display_scale,
        .{
            .limit = TerminalRenderer.display_scale_limit,
            .requested = @intFromFloat(@ceil(@min(viewport.scale, max_reported_scale))),
        },
    );

    var bounded = viewport;
    bounded.scale = TerminalRenderer.max_display_scale;
    return bounded;
}

/// Reports the targets the last published accessibility tree left out.
/// Example: `limit_reached.reportAccessibility(gui);`
pub fn reportAccessibility(gui: *GuiAdapter) void {
    reportDropped(gui, .accessible_nodes, AccessibilityTree.limit, AccessibilityTree.capacity, gui.widgets.accessibility_dropped);
}

/// Reports `reach` when the window enters `which`; staying at it reports
/// nothing more, and a null reach, the window below it again, lets the
/// next entry report. A limit held for many frames counts once.
///
/// ```zig
/// limit_reached.reportEntering(gui, .grid_cells, if (cut) reach else null);
/// ```
pub fn reportEntering(gui: *GuiAdapter, which: WindowLimit, reach: ?core.LimitReach) void {
    const value = reach orelse {
        gui.reached.remove(which);
        return;
    };

    if (gui.reached.contains(which)) {
        return;
    }

    gui.reached.insert(which);
    client.limit_reached.report(gui.app, value);
}

fn reportDropped(gui: *GuiAdapter, which: WindowLimit, limit: core.Limit, kept: usize, dropped: usize) void {
    reportEntering(
        gui,
        which,
        if (dropped == 0) null else .{
            .limit = limit,
            .requested = kept + dropped,
        },
    );
}

/// Whether what the window would show is still the frame that stopped at a
/// limit, so asking for a draw would stop there again.
/// Example: `const due = needs and !limit_reached.holds(gui);`
pub fn holds(gui: *const GuiAdapter) bool {
    const limited = gui.limited orelse return false;
    return std.meta.eql(limited.observation, gui.observation());
}

/// `holds` for a draw at `viewport`: a new viewport measures again.
/// Example: `if (limit_reached.holdsFrame(gui, viewport)) return 0;`
pub fn holdsFrame(gui: *const GuiAdapter, viewport: native.Viewport) bool {
    const limited = gui.limited orelse return false;
    return std.meta.eql(limited.viewport, viewport) and holds(gui);
}

/// The named limit behind an error the window's own code raises.
fn limitOf(err: anyerror) ?core.Limit {
    return switch (err) {
        error.ScreenTooLarge => cell_count_limit,
        error.NativeCellBudgetExceeded => core.Limit.declare("render.retained_max_cells", "cells", RetainedCells.max_cells),
        error.AtlasFull => GlyphAtlas.side_limit,
        else => null,
    };
}
