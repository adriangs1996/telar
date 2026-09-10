//! Pane membership, navigation and layout state independent of presentation.
const std = @import("std");
const core = @import("telar-core");
const schema = core.schema;
const ui = core.ui;
const client_panes = @import("../panes/root.zig");
const frame_apply = client_panes.frame;
const layout_mod = @import("layout.zig");
const input = @import("../input/root.zig");
pub const Pane = client_panes.Pane;
pub const max_panes = layout_mod.max_panes;
pub const PresentationCommit = client_panes.PresentationCommit;
const PaneIndex = core.fixed_index.SlotIndex(max_panes * 2);

pub const MetadataChange = enum {
    unchanged,
    stored,
    display_changed,
};

pub const PaneSpec = client_panes.Spec;

pub const PaneSplit = struct {
    existing_pane: schema.PaneId,
    new_pane: schema.PaneId,
    location: schema.TabLocation,
    axis: layout_mod.Axis,
    area: ui.Rect,
};

pub const DiscoveredPane = struct {
    pane_id: schema.PaneId,
    location: schema.TabLocation,
    area: ui.Rect,
};

pub const PaneMousePlan = struct {
    pane_id: schema.PaneId,
    content: ui.Rect,
    protocol: schema.frame.Mouse,
    alternate_scroll: bool,
    at_bottom: bool,
};

pub const Model = struct {
    gpa: std.mem.Allocator,
    layout: layout_mod.Layout = .{},
    panes: [max_panes]?Pane = [_]?Pane{null} ** max_panes,
    pane_index: PaneIndex = .{},
    pane_count: usize = 0,
    location: ?schema.TabLocation = null,
    cell_width_px: u16 = 0,
    cell_height_px: u16 = 0,
    layout_snapshot: layout_mod.Snapshot = .{},

    pub fn init(gpa: std.mem.Allocator) Model {
        return .{ .gpa = gpa };
    }

    pub fn deinit(model: *Model) void {
        for (&model.panes) |*slot| {
            if (slot.*) |*pane| {
                pane.deinit();
            }
            slot.* = null;
        }
        model.pane_count = 0;
        model.pane_index.reset();
    }

    pub fn setPaneGaps(model: *Model, enabled: bool) void {
        _ = model.layout.setPaneGaps(enabled);
    }

    /// Iterates the live panes without exposing the slot array.
    pub const PaneIterator = struct {
        panes: *[max_panes]?Pane,
        index: usize = 0,

        pub fn next(iterator: *PaneIterator) ?*Pane {
            while (iterator.index < max_panes) {
                const slot = &iterator.panes[iterator.index];
                iterator.index += 1;
                if (slot.*) |*pane| {
                    return pane;
                }
            }
            return null;
        }
    };

    pub fn paneIterator(model: *Model) PaneIterator {
        return .{ .panes = &model.panes };
    }

    pub fn focusedPane(model: *Model) ?*Pane {
        const pane_id = model.layout.focused() orelse return null;
        return model.find(pane_id);
    }

    pub fn focusedPaneConst(model: *const Model) ?*const Pane {
        const pane_id = model.layout.focused() orelse return null;
        return model.findConst(pane_id);
    }

    pub fn displayIndex(model: *const Model, pane_id: schema.PaneId) ?u16 {
        return model.layout.displayIndex(pane_id);
    }

    pub fn find(model: *Model, pane_id: schema.PaneId) ?*Pane {
        if (pane_id == .invalid) {
            return null;
        }
        const slot = model.pane_index.get(schema.id.raw(pane_id)) orelse return null;
        return &model.panes[slot].?;
    }

    pub fn findConst(model: *const Model, pane_id: schema.PaneId) ?*const Pane {
        if (pane_id == .invalid) {
            return null;
        }
        const slot = model.pane_index.get(schema.id.raw(pane_id)) orelse return null;
        return &model.panes[slot].?;
    }

    /// Stores one pane working directory and reports whether its bounded
    /// display name changed. Rendering caches remain untouched.
    ///
    /// ```zig
    /// const change = try model.setPaneCwd(pane_id, "/work/telar");
    /// ```
    pub fn setPaneCwd(model: *Model, pane_id: schema.PaneId, path: []const u8) !MetadataChange {
        const pane = model.find(pane_id) orelse return .unchanged;
        if (std.mem.eql(u8, pane.cwdSlice(), path)) {
            return .unchanged;
        }

        return if (try pane.setCwd(path)) .display_changed else .stored;
    }

    /// Stores one pane foreground label without mutating composition caches.
    ///
    /// ```zig
    /// const change = model.setPaneForeground(pane_id, "zsh");
    /// ```
    pub fn setPaneForeground(model: *Model, pane_id: schema.PaneId, name: []const u8) MetadataChange {
        const pane = model.find(pane_id) orelse return .unchanged;

        return if (pane.setForegroundName(name)) .display_changed else .unchanged;
    }

    /// Stores one pane window title without mutating composition caches.
    ///
    /// ```zig
    /// const change = model.setPaneTitle(pane_id, "vim README.md");
    /// ```
    pub fn setPaneTitle(model: *Model, pane_id: schema.PaneId, title: []const u8) !MetadataChange {
        const pane = model.find(pane_id) orelse return .unchanged;

        return if (try pane.setTitle(title)) .display_changed else .unchanged;
    }

    /// Adds the first pane and establishes the model location.
    ///
    /// ```zig
    /// try model.addRoot(.{ .pane_id = pane_id, .location = location, .size = size });
    /// ```
    pub fn addRoot(model: *Model, spec: PaneSpec) !void {
        if (model.pane_count != 0) {
            return error.ModelNotEmpty;
        }

        try model.insertPane(spec, true);
        errdefer _ = model.removePane(spec.pane_id);
        try model.layout.addRoot(spec.pane_id);
        model.location = spec.location;
    }

    /// Adds a pane by splitting an existing pane within the current workbench.
    ///
    /// ```zig
    /// try model.split(.{ .existing_pane = first, .new_pane = second, .location = location, .axis = .horizontal, .area = area });
    /// ```
    pub fn split(model: *Model, request: PaneSplit) !void {
        const prospective = model.prospectiveSplit(.{
            .pane_id = request.existing_pane,
            .axis = request.axis,
        }, request.area) orelse
            return error.PaneTooSmall;
        const size = rectSize(prospective.new_content) orelse return error.PaneTooSmall;

        try model.insertPane(.{
            .pane_id = request.new_pane,
            .location = request.location,
            .size = size,
        }, true);
        errdefer _ = model.removePane(request.new_pane);
        try model.layout.split(.{
            .existing_pane = request.existing_pane,
            .new_pane = request.new_pane,
            .axis = request.axis,
        });
    }

    /// Adds panes discovered in a location snapshot. Reconstructed layouts are
    /// intentionally local and deterministic: each additional pane splits the
    /// currently focused leaf left-to-right. The runtime owns membership, so a
    /// pane the area cannot fit still joins the layout, detached and without
    /// visible content until the geometry changes.
    ///
    /// ```zig
    /// try model.addDiscovered(.{ .pane_id = pane_id, .location = location, .area = area });
    /// ```
    pub fn addDiscovered(model: *Model, discovered: DiscoveredPane) !void {
        if (model.find(discovered.pane_id) != null) {
            return;
        }

        const focused = model.layout.focused() orelse {
            const size = rectSize(discovered.area) orelse placeholder_size;
            try model.insertPane(.{
                .pane_id = discovered.pane_id,
                .location = discovered.location,
                .size = size,
            }, false);
            errdefer _ = model.removePane(discovered.pane_id);
            try model.layout.addRoot(discovered.pane_id);
            model.location = discovered.location;

            return;
        };

        const size = if (model.prospectiveSplit(.{ .pane_id = focused, .axis = .horizontal }, discovered.area)) |prospective|
            rectSize(prospective.new_content) orelse placeholder_size
        else
            placeholder_size;

        try model.insertPane(.{
            .pane_id = discovered.pane_id,
            .location = discovered.location,
            .size = size,
        }, false);
        errdefer _ = model.removePane(discovered.pane_id);
        try model.layout.split(.{
            .existing_pane = focused,
            .new_pane = discovered.pane_id,
            .axis = .horizontal,
        });
    }

    pub fn restoreDisplayOrder(model: *Model, pane_ids: []const schema.PaneId, focused_pane: schema.PaneId) !void {
        if (pane_ids.len != model.pane_count) {
            return error.UnexpectedPaneCount;
        }
        for (pane_ids) |pane_id|
            if (model.find(pane_id) == null) return error.PaneNotFound;
        try model.layout.restoreDisplayOrder(pane_ids, focused_pane);
    }

    /// Restores a saved split tree when it matches the model pane membership.
    ///
    /// ```zig
    /// const restored = model.restoreSavedLayout(saved, .{ .ids = pane_ids, .focused = focused_pane });
    /// ```
    pub fn restoreSavedLayout(model: *Model, saved: layout_mod.Layout, panes: layout_mod.PaneSet) bool {
        if (panes.ids.len != model.pane_count) {
            return false;
        }

        for (panes.ids) |pane_id|
            if (model.find(pane_id) == null) return false;

        if (!model.layout.restoreSaved(saved, panes)) {
            return false;
        }

        return true;
    }

    pub fn markAttached(model: *Model, pane_id: schema.PaneId) !void {
        const pane = model.find(pane_id) orelse return error.PaneNotFound;
        pane.attached = true;
    }

    pub fn removePane(model: *Model, pane_id: schema.PaneId) bool {
        var removed = false;
        for (&model.panes) |*slot| {
            const pane = if (slot.*) |*value| value else continue;
            if (pane.id != pane_id) {
                continue;
            }
            pane.deinit();
            slot.* = null;
            model.pane_count -= 1;
            removed = true;
            break;
        }
        if (removed) {
            model.pane_index.remove(schema.id.raw(pane_id));
        }
        _ = model.layout.remove(pane_id);
        if (model.pane_count == 0) {
            model.location = null;
        }
        return removed;
    }

    pub fn focusPane(model: *Model, pane_id: schema.PaneId) bool {
        if (!model.layout.focusPane(pane_id)) {
            return false;
        }
        return true;
    }

    pub fn focusDirection(model: *Model, direction: layout_mod.Direction, area: ui.Rect) ?schema.PaneId {
        _ = model.layout.focused() orelse return null;
        const focused = model.layout.focusDirection(direction, area) orelse return null;
        return focused;
    }

    pub fn resizeFocused(model: *Model, direction: layout_mod.Direction, area: ui.Rect) bool {
        if (!model.layout.resizeFocused(direction, area)) {
            return false;
        }
        return true;
    }

    pub fn toggleFullscreen(model: *Model) bool {
        if (!model.layout.toggleFullscreen()) {
            return false;
        }
        return true;
    }

    pub fn applyFrame(model: *Model, frame: schema.frame.FrameView) !frame_apply.Applied {
        const pane = model.find(frame.pane_id) orelse return error.PaneNotFound;
        return pane.applyFrame(frame);
    }

    pub fn contentSize(self: *Model, pane_id: schema.PaneId, area: ui.Rect) ?schema.TerminalSize {
        const view = self.layoutSnapshot(area).find(pane_id) orelse return null;
        var size = rectSize(view.content) orelse return null;
        size.cell_width_px = self.cell_width_px;
        size.cell_height_px = self.cell_height_px;
        return size;
    }

    pub fn viewForPane(self: *Model, pane_id: schema.PaneId, area: ui.Rect) ?layout_mod.View {
        return self.layoutSnapshot(area).find(pane_id);
    }

    /// Resolves one pointer event to a visible pane and returns only the state
    /// required by mouse-input policy. Wheel events target the pane under the
    /// pointer; every other event targets the focused pane.
    ///
    /// ```zig
    /// const plan = model.planPaneMouse(event, area) orelse return;
    /// ```
    pub fn planPaneMouse(self: *Model, event: input.Mouse, area: ui.Rect) ?PaneMousePlan {
        const snapshot = self.layoutSnapshot(area);
        const wheel = event.kind == .scroll_up or event.kind == .scroll_down;
        var pane = self.focusedPane() orelse return null;
        if (wheel) {
            for (snapshot.views()) |candidate| {
                if (!candidate.content.contains(event.x, event.y)) {
                    continue;
                }

                pane = self.find(candidate.pane_id) orelse return null;
                break;
            }
        }

        const view = snapshot.find(pane.id) orelse return null;
        if (!view.content.contains(event.x, event.y)) {
            return null;
        }

        return paneMousePlan(pane, view.content);
    }

    /// Resolves the focused pane without consulting pointer coordinates.
    /// Example: `const plan = model.planFocusedPaneMouse(area) orelse return;`.
    pub fn planFocusedPaneMouse(self: *Model, area: ui.Rect) ?PaneMousePlan {
        const pane = self.focusedPane() orelse return null;
        const view = self.layoutSnapshot(area).find(pane.id) orelse return null;

        if (view.content.w == 0 or view.content.h == 0) {
            return null;
        }

        return paneMousePlan(pane, view.content);
    }

    pub fn layoutSnapshot(model: *Model, area: ui.Rect) *const layout_mod.Snapshot {
        if (model.layout_snapshot.revision != model.layout.currentRevision() or
            !std.meta.eql(model.layout_snapshot.area, area))
        {
            model.layout.snapshot(area, &model.layout_snapshot);
        }
        return &model.layout_snapshot;
    }

    /// Computes a split preview against the model's current pane membership.
    ///
    /// ```zig
    /// const split = model.prospectiveSplit(.{ .pane_id = pane_id, .axis = .horizontal }, area);
    /// ```
    pub fn prospectiveSplit(model: *Model, target: layout_mod.SplitTarget, area: ui.Rect) ?layout_mod.ProspectiveSplit {
        return model.layoutSnapshot(area).prospectiveSplit(target, model.pane_count);
    }

    pub fn setCellSize(model: *Model, width: u16, height: u16) void {
        if (model.cell_width_px == width and model.cell_height_px == height) {
            return;
        }
        model.cell_width_px = width;
        model.cell_height_px = height;
    }

    /// Sets one pane's cell fallback and reports whether composition changed.
    ///
    /// ```zig
    /// if (model.setGraphicsPlaceholder(pane_id, true)) scheduleObservation();
    /// ```
    pub fn setGraphicsPlaceholder(model: *Model, pane_id: schema.PaneId, visible: bool) bool {
        const pane = model.find(pane_id) orelse return false;
        if (pane.graphics_placeholder == visible) {
            return false;
        }
        pane.graphics_placeholder = visible;

        return true;
    }

    /// Retires only the damage and frame identifiers included in a successful
    /// host presentation. A stale commit cannot consume newer pane work.
    ///
    /// ```zig
    /// model.commitPresentation(commit);
    /// ```
    pub fn commitPresentation(model: *Model, commit: PresentationCommit) void {
        if (!std.meta.eql(model.location, commit.location)) {
            return;
        }

        for (commit.slice()) |presented| {
            const pane = model.find(presented.pane_id) orelse continue;
            pane.commitPresentation(presented.frame_id);
        }
    }

    fn insertPane(model: *Model, spec: PaneSpec, attached: bool) !void {
        if (spec.pane_id == .invalid) {
            return error.InvalidPaneId;
        }

        if (model.find(spec.pane_id) != null) {
            return error.DuplicatePane;
        }

        if (model.pane_count == max_panes) {
            return error.PaneLimitReached;
        }

        for (&model.panes, 0..) |*slot, slot_index| {
            if (slot.* == null) {
                slot.* = try Pane.init(model.gpa, .{
                    .spec = spec,
                    .attached = attached,
                });
                model.pane_count += 1;
                model.indexPane(spec.pane_id, @intCast(slot_index));

                return;
            }
        }
        unreachable;
    }

    fn indexPane(model: *Model, pane_id: schema.PaneId, pane_slot: u8) void {
        model.pane_index.put(schema.id.raw(pane_id), pane_slot);
    }

    fn paneMousePlan(pane: *const Pane, content: ui.Rect) PaneMousePlan {
        return .{
            .pane_id = pane.id,
            .content = content,
            .protocol = pane.mouse,
            .alternate_scroll = pane.input_modes.alternate_screen and pane.input_modes.alternate_scroll,
            .at_bottom = pane.scroll.atBottom(pane.buffer.h),
        };
    }
};

pub fn rectSize(rect: ui.Rect) ?schema.TerminalSize {
    if (rect.w == 0 or rect.h == 0) {
        return null;
    }
    return .{ .cols = rect.w, .rows = rect.h };
}

const placeholder_size: schema.TerminalSize = .{ .cols = 1, .rows = 1 };

pub const CopyProjection = struct {
    pane_id: schema.PaneId,
    view: input.copy_mode.View,
};
