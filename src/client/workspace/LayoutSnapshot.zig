const RectType = @import("telar-core").Rect;
const Metrics = @import("Metrics.zig");
const max_panes_per_tab = @import("telar-core").max_panes_per_tab;
const View = @import("LayoutView.zig");
const layout_support = @import("layout_support.zig");
const PaneIdType = @import("telar-core").PaneId;
const raw_module = @import("telar-core").raw;
const PaneBottomReservation = @import("PaneBottomReservation.zig");
const std = @import("std");
const SplitTarget = @import("SplitTarget.zig");
const ProspectiveSplit = @import("ProspectiveSplit.zig");
const SnapshotReset = @import("SnapshotReset.zig");
/// Immutable geometry consumed by every subsystem during a frame. Building it
/// is O(panes); pane lookup is bounded open addressing with no allocations.
const Snapshot = @This();

area: RectType = .{},
revision: u64 = 0,
pane_gaps: bool = true,
metrics: Metrics = .{},
storage: [max_panes_per_tab]View = undefined,
len: u8 = 0,
index: layout_support.ViewIndex = .{},

pub fn views(snapshot: *const Snapshot) []const View {
    return snapshot.storage[0..snapshot.len];
}

pub fn find(snapshot: *const Snapshot, pane_id: PaneIdType) ?View {
    if (pane_id == .invalid) {
        return null;
    }
    const view_index = snapshot.index.get(raw_module(pane_id)) orelse return null;
    return snapshot.storage[view_index];
}

/// Shortens one pane and returns the area immediately below it. The other
/// pane rectangles remain unchanged.
///
/// ```zig
/// const shelf = snapshot.reserveBelowPane(reservation);
/// ```
pub fn reserveBelowPane(snapshot: *Snapshot, reservation: ?PaneBottomReservation) RectType {
    const requested = reservation orelse return .{};
    const view_index = snapshot.index.get(raw_module(requested.pane_id)) orelse return .{};
    const view = &snapshot.storage[view_index];
    const available = view.outer.h -| requested.minimum_pane_height;
    const height = @min(requested.preferred_height, available);
    if (height < requested.minimum_height) {
        return .{};
    }

    const pane, const reserved = view.outer.splitBottom(height);
    const borderless = std.meta.eql(view.outer, view.content);
    view.outer = pane;
    view.content = if (borderless) pane else pane.inner(snapshot.metrics.border);

    return reserved;
}

/// Computes the two content regions produced by splitting one pane.
///
/// ```zig
/// const split = snapshot.prospectiveSplit(.{ .pane_id = pane_id, .axis = .horizontal }, pane_count);
/// ```
pub fn prospectiveSplit(snapshot: *const Snapshot, target: SplitTarget, pane_count: usize) ?ProspectiveSplit {
    if (pane_count == max_panes_per_tab) {
        return null;
    }

    const view = snapshot.find(target.pane_id) orelse return null;
    const minimum_pane_extent = snapshot.metrics.minimumPaneExtent();
    const minimum_split_extent = 2 * minimum_pane_extent + snapshot.metrics.gutter(snapshot.pane_gaps);
    const enough_space = switch (target.axis) {
        .horizontal => view.outer.w >= minimum_split_extent and view.outer.h >= minimum_pane_extent,
        .vertical => view.outer.w >= minimum_pane_extent and view.outer.h >= minimum_split_extent,
    };
    if (!enough_space) {
        return null;
    }

    const first, const second = layout_support.splitArea(.{
        .area = view.outer,
        .axis = target.axis,
        .ratio = layout_support.default_split_ratio,
        .gap = snapshot.metrics.gutter(snapshot.pane_gaps),
    });

    return .{
        .existing_content = first.inner(snapshot.metrics.border),
        .new_content = second.inner(snapshot.metrics.border),
    };
}

pub fn focusTarget(snapshot: *const Snapshot, current_id: PaneIdType, direction: layout_support.Direction) ?PaneIdType {
    const source = snapshot.find(current_id) orelse return null;
    var candidate: ?PaneIdType = null;
    var best_score: u64 = std.math.maxInt(u64);
    const source_x = layout_support.center(source.outer.x, source.outer.w);
    const source_y = layout_support.center(source.outer.y, source.outer.h);
    for (snapshot.views()) |view| {
        if (view.pane_id == current_id) {
            continue;
        }
        const candidate_x = layout_support.center(view.outer.x, view.outer.w);
        const candidate_y = layout_support.center(view.outer.y, view.outer.h);
        const source_left: u32 = source.outer.x;
        const source_top: u32 = source.outer.y;
        const source_right = source_left + source.outer.w;
        const source_bottom = source_top + source.outer.h;
        const candidate_left: u32 = view.outer.x;
        const candidate_top: u32 = view.outer.y;
        const candidate_right = candidate_left + view.outer.w;
        const candidate_bottom = candidate_top + view.outer.h;
        const primary, const secondary, const forward = switch (direction) {
            .left => .{
                source_left -| candidate_right,
                layout_support.distance(source_y, candidate_y) / 2,
                candidate_right <= source_left,
            },
            .right => .{
                candidate_left -| source_right,
                layout_support.distance(source_y, candidate_y) / 2,
                candidate_left >= source_right,
            },
            .up => .{
                source_top -| candidate_bottom,
                layout_support.distance(source_x, candidate_x) / 2,
                candidate_bottom <= source_top,
            },
            .down => .{
                candidate_top -| source_bottom,
                layout_support.distance(source_x, candidate_x) / 2,
                candidate_top >= source_bottom,
            },
        };
        if (!forward) {
            continue;
        }
        const score = @as(u64, primary) * 65536 + secondary;
        if (score < best_score) {
            best_score = score;
            candidate = view.pane_id;
        }
    }
    return candidate;
}

pub fn reset(snapshot: *Snapshot, state: SnapshotReset) void {
    snapshot.area = state.area;
    snapshot.revision = state.revision;
    snapshot.pane_gaps = state.pane_gaps;
    snapshot.metrics = state.metrics;
    snapshot.len = 0;
    snapshot.index.reset();
}

pub fn append(snapshot: *Snapshot, view: View) void {
    const view_index = snapshot.len;
    snapshot.storage[view_index] = view;
    snapshot.len += 1;
    snapshot.index.put(raw_module(view.pane_id), view_index);
}
