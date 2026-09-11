const Pane = @This();
const std = @import("std");
const source_namespace = @import("pane_support.zig");
const damage = @import("damage.zig");
const Spec = @import("Spec.zig");
const frames = @import("frame.zig");
gpa: std.mem.Allocator,
id: source_namespace.schema.PaneId,
location: source_namespace.schema.TabLocation,
buffer: source_namespace.ui.Buffer,
damage_rows: []damage.DamageRow,
attached: bool,
attachment_generation: u64 = 0,
cursor: source_namespace.schema.frame.Cursor = .{},
mouse: source_namespace.schema.frame.Mouse = .{},
input_modes: source_namespace.schema.frame.InputModes = .{},
pointer_shape: source_namespace.schema.frame.PointerShape = .default,
scroll: source_namespace.schema.frame.Scroll,
applied_frame_id: u64 = 0,
pending_frame_id: u64 = 0,
graphics_placeholder: bool = false,
cwd: []u8 = &.{},
foreground_name: [source_namespace.schema.max_foreground_name_bytes]u8 = @splat(0),
foreground_name_len: u8 = 0,
progress_state: source_namespace.schema.PaneProgressState = .remove,
progress_percent: ?u8 = null,
title: []u8 = &.{},

pub const Initial = struct { spec: Spec, attached: bool };

/// Reserves cells and row damage for one validated pane. Example: var pane = try Pane.init(gpa, initial);
pub fn init(gpa: std.mem.Allocator, initial: Initial) !Pane {
    if (initial.spec.pane_id == .invalid) {
        return error.InvalidPaneId;
    }

    try initial.spec.size.validate();
    var buffer = try source_namespace.ui.Buffer.init(gpa, initial.spec.size.cols, initial.spec.size.rows);
    errdefer buffer.deinit();

    const rows = try gpa.alloc(damage.DamageRow, initial.spec.size.rows);
    @memset(rows, .{});
    return .{
        .gpa = gpa,
        .id = initial.spec.pane_id,
        .location = initial.spec.location,
        .buffer = buffer,
        .damage_rows = rows,
        .attached = initial.attached,
        .scroll = .{ .total_rows = initial.spec.size.rows, .offset = 0 },
    };
}

pub fn deinit(pane: *Pane) void {
    pane.gpa.free(pane.cwd);
    pane.gpa.free(pane.title);
    pane.gpa.free(pane.damage_rows);
    pane.buffer.deinit();
}

/// Applies a decoded frame after identity and base admission. Only a
/// snapshot may resize storage. Example: const work = try pane.applyFrame(frame);
pub fn applyFrame(pane: *Pane, frame: source_namespace.schema.frame.FrameView) !frames.Applied {
    if (frame.pane_id != pane.id) {
        return error.PaneMismatch;
    }

    if (frame.base_frame_id != 0 and frame.base_frame_id != pane.applied_frame_id) {
        return error.FrameBaseMismatch;
    }

    const resized = pane.buffer.w != frame.cols or pane.buffer.h != frame.rows;
    const replacement_damage = if (resized) try pane.gpa.alloc(damage.DamageRow, frame.rows) else null;
    errdefer if (replacement_damage) |rows| pane.gpa.free(rows);

    const applied = try frames.applyBuffer(&pane.buffer, &pane.cursor, frame);
    pane.mouse = frame.mouse;
    pane.input_modes = frame.input_modes;
    pane.pointer_shape = frame.pointer_shape;
    pane.scroll = frame.scroll;
    if (replacement_damage) |rows| {
        @memset(rows, .{});
        pane.gpa.free(pane.damage_rows);
        pane.damage_rows = rows;
    } else {
        var spans = frame.spans();
        while (try spans.next()) |span| {
            pane.markSpan(span.start, span.cell_count);
        }
    }

    pane.applied_frame_id = frame.frame_id;
    pane.pending_frame_id = frame.frame_id;
    return applied;
}

/// Retires only the exact pending presentation. Example: pane.commitPresentation(frame_id);
pub fn commitPresentation(pane: *Pane, frame_id: u64) void {
    if (pane.pending_frame_id != frame_id) {
        return;
    }

    for (pane.damage_rows) |*row| {
        row.clear();
    }

    pane.pending_frame_id = 0;
}

/// Marks a validated range of owned cells. Example: pane.markSpan(1, 2);
pub fn markSpan(pane: *Pane, start: u32, count: u32) void {
    damage.markRows(pane.damage_rows, pane.buffer.w, .{ .start = start, .count = count });
}

/// Owns the full path and reports changes to its bounded display name.
/// Example: const changed = try pane.setCwd("/work/telar");
pub fn setCwd(pane: *Pane, path: []const u8) !bool {
    std.debug.assert(path.len != 0 and path.len <= source_namespace.schema.max_cwd_bytes);
    if (std.mem.eql(u8, pane.cwd, path)) {
        return false;
    }

    const display_changed = !std.mem.eql(u8, pane.cwdName(), source_namespace.displayCwdName(path));
    const replacement = try pane.gpa.dupe(u8, path);
    pane.gpa.free(pane.cwd);
    pane.cwd = replacement;
    return display_changed;
}

pub fn cwdName(pane: *const Pane) []const u8 {
    return source_namespace.displayCwdName(pane.cwd);
}

pub fn cwdSlice(pane: *const Pane) []const u8 {
    return pane.cwd;
}

/// Replaces a validated foreground label without allocation. Example: _ = pane.setForegroundName("zsh");
pub fn setForegroundName(pane: *Pane, name: []const u8) bool {
    std.debug.assert(name.len != 0 and name.len <= pane.foreground_name.len);
    if (std.mem.eql(u8, pane.foregroundName(), name)) {
        return false;
    }

    @memcpy(pane.foreground_name[0..name.len], name);
    pane.foreground_name_len = @intCast(name.len);
    return true;
}

pub fn foregroundName(pane: *const Pane) []const u8 {
    return pane.foreground_name[0..pane.foreground_name_len];
}

/// Replaces a semantic progress report without allocation. Example: _ = pane.setProgress(progress);
pub fn setProgress(pane: *Pane, progress: source_namespace.schema.PaneProgress) bool {
    if (pane.progress_state == progress.state and pane.progress_percent == progress.percent) {
        return false;
    }

    pane.progress_state = progress.state;
    pane.progress_percent = progress.percent;
    return true;
}

/// Owns a validated window title independently of its request buffer. Example: _ = try pane.setTitle("vim");
pub fn setTitle(pane: *Pane, title: []const u8) !bool {
    std.debug.assert(title.len <= source_namespace.schema.max_pane_title_bytes);
    if (std.mem.eql(u8, pane.title, title)) {
        return false;
    }

    const replacement = if (title.len != 0) try pane.gpa.dupe(u8, title) else &[_]u8{};
    pane.gpa.free(pane.title);
    pane.title = @constCast(replacement);
    return true;
}

pub fn titleSlice(pane: *const Pane) []const u8 {
    return pane.title;
}
