const PaneIteratorType = @import("PaneIterator.zig");
const PresentationCommitType = @import("../panes/PresentationCommit.zig");
const std = @import("std");
const LayoutType = @import("WorkspaceLayout.zig");
const max_panes_per_tab = @import("telar-core").max_panes_per_tab;
const PaneType = @import("../panes/Pane.zig");
const multiplexer = @import("multiplexer.zig");
const TabLocationType = @import("telar-core").TabLocation;
const LayoutSnapshot = @import("LayoutSnapshot.zig");
const PaneIdType = @import("telar-core").PaneId;
const raw_module = @import("telar-core").raw;
const Spec = @import("../panes/Spec.zig");
const PaneSplit = @import("PaneSplit.zig");
const DiscoveredPane = @import("DiscoveredPane.zig");
const PaneSetType = @import("PaneSet.zig");
const layout_mod = @import("layout_support.zig");
const RectType = @import("telar-core").Rect;
const FrameViewType = @import("telar-core").FrameView;
const AppliedType = @import("../panes/Applied.zig");
const TerminalSizeType = @import("telar-core").TerminalSize;
const ViewType = @import("LayoutView.zig");
const MouseType = @import("../input/Mouse.zig");
const PaneMousePlan = @import("PaneMousePlan.zig");
const SplitTargetType = @import("SplitTarget.zig");
const ProspectiveSplitType = @import("ProspectiveSplit.zig");
const Model = @This();

/// Captures all active-tab panes, including panes hidden by fullscreen.
/// Example: `const commit = model.presentationCommit();`.
pub fn presentationCommit(model: *const Model) PresentationCommitType {
    var commit: PresentationCommitType = .{ .location = model.location };
    for (&model.panes) |*slot| {
        const pane = if (slot.*) |*value| value else continue;
        commit.append(pane);
    }
    return commit;
}

gpa: std.mem.Allocator,
layout: LayoutType = .{},
panes: [max_panes_per_tab]?PaneType = [_]?PaneType{null} ** max_panes_per_tab,
pane_index: multiplexer.PaneIndex = .{},
pane_count: usize = 0,
location: ?TabLocationType = null,
cell_width_px: u16 = 0,
cell_height_px: u16 = 0,
layout_snapshot: LayoutSnapshot = .{},

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

pub const PaneIterator = @import("PaneIterator.zig");

pub fn paneIterator(model: *Model) PaneIteratorType {
    return .{ .panes = &model.panes };
}

pub fn focusedPane(model: *Model) ?*PaneType {
    const pane_id = model.layout.focused() orelse return null;
    return model.find(pane_id);
}

pub fn focusedPaneConst(model: *const Model) ?*const PaneType {
    const pane_id = model.layout.focused() orelse return null;
    return model.findConst(pane_id);
}

pub fn displayIndex(model: *const Model, pane_id: PaneIdType) ?u16 {
    return model.layout.displayIndex(pane_id);
}

pub fn find(model: *Model, pane_id: PaneIdType) ?*PaneType {
    if (pane_id == .invalid) {
        return null;
    }
    const slot = model.pane_index.get(raw_module(pane_id)) orelse return null;
    return &model.panes[slot].?;
}

pub fn findConst(model: *const Model, pane_id: PaneIdType) ?*const PaneType {
    if (pane_id == .invalid) {
        return null;
    }
    const slot = model.pane_index.get(raw_module(pane_id)) orelse return null;
    return &model.panes[slot].?;
}

/// Stores one pane working directory and reports whether its bounded
/// display name changed. Rendering caches remain untouched.
///
/// ```zig
/// const change = try model.setPaneCwd(pane_id, "/work/telar");
/// ```
pub fn setPaneCwd(model: *Model, pane_id: PaneIdType, path: []const u8) !multiplexer.MetadataChange {
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
pub fn setPaneForeground(model: *Model, pane_id: PaneIdType, name: []const u8) multiplexer.MetadataChange {
    const pane = model.find(pane_id) orelse return .unchanged;

    return if (pane.setForegroundName(name)) .display_changed else .unchanged;
}

/// Stores one pane window title without mutating composition caches.
///
/// ```zig
/// const change = model.setPaneTitle(pane_id, "vim README.md");
/// ```
pub fn setPaneTitle(model: *Model, pane_id: PaneIdType, title: []const u8) !multiplexer.MetadataChange {
    const pane = model.find(pane_id) orelse return .unchanged;

    return if (try pane.setTitle(title)) .display_changed else .unchanged;
}

/// Adds the first pane and establishes the model location.
///
/// ```zig
/// try model.addRoot(.{ .pane_id = pane_id, .location = location, .size = size });
/// ```
pub fn addRoot(model: *Model, spec: Spec) !void {
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
    const size = multiplexer.rectSize(prospective.new_content) orelse return error.PaneTooSmall;

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
        const size = multiplexer.rectSize(discovered.area) orelse multiplexer.placeholder_size;
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
        multiplexer.rectSize(prospective.new_content) orelse multiplexer.placeholder_size
    else
        multiplexer.placeholder_size;

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

pub fn restoreDisplayOrder(model: *Model, pane_ids: []const PaneIdType, focused_pane: PaneIdType) !void {
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
pub fn restoreSavedLayout(model: *Model, saved: LayoutType, panes: PaneSetType) bool {
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

/// Installs an attachment identity allocated by the owning client model.
/// Example: `try model.markAttached(pane_id, generation);`.
pub fn markAttached(model: *Model, pane_id: PaneIdType, generation: u64) !void {
    const pane = model.find(pane_id) orelse return error.PaneNotFound;
    if (pane.attached) {
        return;
    }

    pane.attached = true;
    pane.attachment_generation = generation;
}

pub fn removePane(model: *Model, pane_id: PaneIdType) bool {
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
        model.pane_index.remove(raw_module(pane_id));
    }
    _ = model.layout.remove(pane_id);
    if (model.pane_count == 0) {
        model.location = null;
    }
    return removed;
}

pub fn focusPane(model: *Model, pane_id: PaneIdType) bool {
    if (!model.layout.focusPane(pane_id)) {
        return false;
    }
    return true;
}

pub fn focusDirection(model: *Model, direction: layout_mod.Direction, area: RectType) ?PaneIdType {
    _ = model.layout.focused() orelse return null;
    const focused = model.layout.focusDirection(direction, area) orelse return null;
    return focused;
}

pub fn resizeFocused(model: *Model, direction: layout_mod.Direction, area: RectType) bool {
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

pub fn applyFrame(model: *Model, frame: FrameViewType) !AppliedType {
    const pane = model.find(frame.pane_id) orelse return error.PaneNotFound;
    return pane.applyFrame(frame);
}

pub fn contentSize(self: *Model, pane_id: PaneIdType, area: RectType) ?TerminalSizeType {
    const view = self.layoutSnapshot(area).find(pane_id) orelse return null;
    var size = multiplexer.rectSize(view.content) orelse return null;
    size.cell_width_px = self.cell_width_px;
    size.cell_height_px = self.cell_height_px;
    return size;
}

pub fn viewForPane(self: *Model, pane_id: PaneIdType, area: RectType) ?ViewType {
    return self.layoutSnapshot(area).find(pane_id);
}

/// Resolves one pointer event to a visible pane and returns only the state
/// required by mouse-input policy. Wheel events target the pane under the
/// pointer; every other event targets the focused pane.
///
/// ```zig
/// const plan = model.planPaneMouse(event, area) orelse return;
/// ```
pub fn planPaneMouse(self: *Model, event: MouseType, area: RectType) ?PaneMousePlan {
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
pub fn planFocusedPaneMouse(self: *Model, area: RectType) ?PaneMousePlan {
    const pane = self.focusedPane() orelse return null;
    const view = self.layoutSnapshot(area).find(pane.id) orelse return null;

    if (view.content.w == 0 or view.content.h == 0) {
        return null;
    }

    return paneMousePlan(pane, view.content);
}

pub fn layoutSnapshot(model: *Model, area: RectType) *const LayoutSnapshot {
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
pub fn prospectiveSplit(model: *Model, target: SplitTargetType, area: RectType) ?ProspectiveSplitType {
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
pub fn setGraphicsPlaceholder(model: *Model, pane_id: PaneIdType, visible: bool) bool {
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
/// const acknowledged = model.commitPresentation(commit);
/// ```
pub fn commitPresentation(model: *Model, commit: PresentationCommitType) PresentationCommitType {
    var accepted: PresentationCommitType = .{ .location = commit.location };
    if (!std.meta.eql(model.location, commit.location)) {
        return accepted;
    }

    for (commit.slice()) |presented| {
        const pane = model.find(presented.pane_id) orelse continue;
        if (pane.attached != presented.attached or pane.attachment_generation != presented.attachment_generation) {
            continue;
        }

        pane.commitPresentation(presented.frame_id);
        accepted.panes[accepted.len] = presented;
        accepted.len += 1;
    }

    return accepted;
}

fn insertPane(model: *Model, spec: Spec, attached: bool) !void {
    if (spec.pane_id == .invalid) {
        return error.InvalidPaneId;
    }

    if (model.find(spec.pane_id) != null) {
        return error.DuplicatePane;
    }

    if (model.pane_count == max_panes_per_tab) {
        return error.PaneLimitReached;
    }

    for (&model.panes, 0..) |*slot, slot_index| {
        if (slot.* == null) {
            slot.* = try PaneType.init(model.gpa, .{
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

fn indexPane(model: *Model, pane_id: PaneIdType, pane_slot: u8) void {
    model.pane_index.put(raw_module(pane_id), pane_slot);
}

fn paneMousePlan(pane: *const PaneType, content: RectType) PaneMousePlan {
    return .{
        .pane_id = pane.id,
        .content = content,
        .protocol = pane.mouse,
        .alternate_scroll = pane.input_modes.alternate_screen and pane.input_modes.alternate_scroll,
        .at_bottom = pane.scroll.atBottom(pane.buffer.h),
    };
}
