const keyinput = @import("keyinput");
const cellgrid = @import("cellgrid");
const std = @import("std");
const builtin = @import("builtin");
const DamageRow = cellgrid.DamageRow;
const Applied = @import("Applied.zig");
const frames = @import("frame.zig");
const damage = cellgrid.damage;
const pane_support = @import("pane_support.zig");
const Pane = @This();
const core = @import("telar-core");

gpa: std.mem.Allocator,
id: core.PaneId,
location: core.TabLocation,
buffer: cellgrid.Buffer,
text_metadata: *core.TextMetadata,
damage_rows: []DamageRow,
attached: bool,
attachment_generation: u64 = 0,
cursor: core.Cursor = .{},
mouse: core.Mouse = .{},
input_modes: keyinput.InputModes = .{},
pointer_shape: core.PointerShape = .default,
scroll: core.Scroll,
applied_frame_id: u64 = 0,
pending_frame_id: u64 = 0,
graphics_placeholder: bool = false,
cwd: []u8 = &.{},
foreground_name: [core.max_foreground_name_bytes]u8 = @splat(0),
foreground_name_len: u8 = 0,
progress_state: core.PaneProgressState = .remove,
progress_percent: ?u8 = null,
title: []u8 = &.{},
pane_generation: u64 = 0,

pub const Initial = @import("Initial.zig");

/// Reserves cells and row damage for one validated pane. Example: var pane = try Pane.init(gpa, initial);
pub fn init(gpa: std.mem.Allocator, initial: Initial) !Pane {
    if (initial.spec.pane_id == .invalid) {
        return error.InvalidPaneId;
    }

    try initial.spec.size.validate();
    var buffer = try cellgrid.Buffer.init(gpa, initial.spec.size.cols, initial.spec.size.rows);
    errdefer buffer.deinit();

    const rows = try gpa.alloc(DamageRow, initial.spec.size.rows);
    errdefer gpa.free(rows);
    @memset(rows, .{});
    const text_metadata = try gpa.create(core.TextMetadata);
    errdefer gpa.destroy(text_metadata);
    text_metadata.* = try .init(gpa, initial.spec.size.rows);
    return .{
        .text_metadata = text_metadata,
        .gpa = gpa,
        .id = initial.spec.pane_id,
        .location = initial.spec.location,
        .buffer = buffer,
        .damage_rows = rows,
        .attached = initial.attached,
        .scroll = .{ .total_rows = initial.spec.size.rows, .offset = 0 },
    };
}

pub fn deinit(self: *Pane) void {
    self.gpa.free(self.cwd);
    self.gpa.free(self.title);
    self.gpa.free(self.damage_rows);
    self.text_metadata.deinit(self.gpa);
    self.gpa.destroy(self.text_metadata);
    self.buffer.deinit();
}

/// Applies a decoded frame after identity and base admission. Only a
/// snapshot may resize storage. Example: const work = try pane.applyFrame(frame);
pub fn applyFrame(self: *Pane, frame: core.FrameView) !Applied {
    core.profiling.add(.pane_apply_frame, 1);
    if (frame.pane_id != self.id) {
        return error.PaneMismatch;
    }

    if (frame.base_frame_id != 0 and frame.base_frame_id != self.applied_frame_id) {
        return error.FrameBaseMismatch;
    }

    const metadata = if (frame.text_metadata) |value|
        try core.TextMetadataView.decode(value.encoded, .{ frame.cols, frame.rows })
    else if (frame.base_frame_id == 0)
        return error.MissingSnapshotMetadata
    else
        null;
    const resized = self.buffer.w != frame.cols or self.buffer.h != frame.rows;
    if (resized and frame.base_frame_id != 0) {
        if (!builtin.is_test) {
            std.log.err(
                "pane {any}: patch frame={d} base={d}, applied={d}, incoming={d}x{d}, buffer={d}x{d}",
                .{
                    self.id,
                    frame.frame_id,
                    frame.base_frame_id,
                    self.applied_frame_id,
                    frame.cols,
                    frame.rows,
                    self.buffer.w,
                    self.buffer.h,
                },
            );
        }

        return error.PatchSizeMismatch;
    }

    try self.text_metadata.reserve(self.gpa, frame.rows);
    const replacement_damage = if (resized) try self.gpa.alloc(DamageRow, frame.rows) else null;
    errdefer if (replacement_damage) |rows| self.gpa.free(rows);

    const applied = try frames.applyBuffer(&self.buffer, &self.cursor, frame);
    if (metadata) |value| {
        self.text_metadata.replace(value);
    }

    self.mouse = frame.mouse;
    self.input_modes = frame.input_modes;
    self.pointer_shape = frame.pointer_shape;
    self.scroll = frame.scroll;
    if (replacement_damage) |rows| {
        @memset(rows, .{});
        self.gpa.free(self.damage_rows);
        self.damage_rows = rows;
    } else {
        var spans = frame.spans();
        while (try spans.next()) |span| {
            self.markSpan(span.start, span.cell_count);
        }
    }

    self.applied_frame_id = frame.frame_id;
    self.pending_frame_id = frame.frame_id;
    core.profiling.add(.pane_copy_cells, applied.cells);
    core.profiling.add(.pane_copy_bytes, applied.cells * @sizeOf(cellgrid.Cell));
    return applied;
}

/// Retires only the exact pending presentation. Example: pane.commitPresentation(frame_id);
pub fn commitPresentation(self: *Pane, frame_id: u64) void {
    if (self.pending_frame_id != frame_id) {
        return;
    }

    for (self.damage_rows) |*row| {
        row.clear();
    }

    self.pending_frame_id = 0;
}

/// Marks a validated range of owned cells. Example: pane.markSpan(1, 2);
pub fn markSpan(self: *Pane, start: u32, count: u32) void {
    damage.markRows(self.damage_rows, self.buffer.w, .{ .start = start, .count = count });
}

/// Owns the full path and reports changes to its bounded display name.
/// Example: const changed = try pane.setCwd("/work/telar");
pub fn setCwd(self: *Pane, path: []const u8) !bool {
    std.debug.assert(path.len != 0 and path.len <= core.max_cwd_bytes);
    if (std.mem.eql(u8, self.cwd, path)) {
        return false;
    }

    const display_changed = !std.mem.eql(u8, self.cwdName(), pane_support.displayCwdName(path));
    const replacement = try self.gpa.dupe(u8, path);
    self.gpa.free(self.cwd);
    self.cwd = replacement;
    return display_changed;
}

pub fn cwdName(self: *const Pane) []const u8 {
    return pane_support.displayCwdName(self.cwd);
}

pub fn cwdSlice(self: *const Pane) []const u8 {
    return self.cwd;
}

/// Replaces a validated foreground label without allocation. Example: _ = pane.setForegroundName("zsh");
pub fn setForegroundName(self: *Pane, name: []const u8) bool {
    std.debug.assert(name.len != 0 and name.len <= self.foreground_name.len);
    if (std.mem.eql(u8, self.foregroundName(), name)) {
        return false;
    }

    @memcpy(self.foreground_name[0..name.len], name);
    self.foreground_name_len = @intCast(name.len);
    return true;
}

pub fn foregroundName(self: *const Pane) []const u8 {
    return self.foreground_name[0..self.foreground_name_len];
}

/// Replaces a semantic progress report without allocation. Example: _ = pane.setProgress(progress);
pub fn setProgress(self: *Pane, progress: core.PaneProgress) bool {
    if (self.progress_state == progress.state and self.progress_percent == progress.percent) {
        return false;
    }

    self.progress_state = progress.state;
    self.progress_percent = progress.percent;
    return true;
}

/// Owns a validated window title independently of its request buffer. Example: _ = try pane.setTitle("vim");
pub fn setTitle(self: *Pane, title: []const u8) !bool {
    std.debug.assert(title.len <= core.max_pane_title_bytes);
    if (std.mem.eql(u8, self.title, title)) {
        return false;
    }

    const replacement = if (title.len != 0) try self.gpa.dupe(u8, title) else &[_]u8{};
    self.gpa.free(self.title);
    self.title = @constCast(replacement);
    return true;
}

pub fn titleSlice(self: *const Pane) []const u8 {
    return self.title;
}

/// Installs the current client attachment generation.
/// Example: `pane.attach(generation);`
pub fn attach(self: *Pane, generation: u64) void {
    self.attached = true;
    self.attachment_generation = generation;
}

/// Updates the runtime identity when the pane generation changes.
/// Example: `_ = pane.identify(generation);`
pub fn identify(self: *Pane, generation: u64) bool {
    if (self.pane_generation == generation) {
        return false;
    }

    self.pane_generation = generation;
    return true;
}
