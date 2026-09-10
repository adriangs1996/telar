//! One client-owned projection of a runtime pane. No presentation resources.

const std = @import("std");
const core = @import("telar-core");
const damage = @import("damage.zig");
const frames = @import("frame.zig");
const schema = core.schema;
const ui = core.ui;
const max_cwd_name_bytes = 48;

pub const Spec = struct {
    pane_id: schema.PaneId,
    location: schema.TabLocation,
    size: schema.TerminalSize,
};

pub const Pane = struct {
    gpa: std.mem.Allocator,
    id: schema.PaneId,
    location: schema.TabLocation,
    buffer: ui.Buffer,
    damage_rows: []damage.DamageRow,
    attached: bool,
    attachment_generation: u64 = 0,
    cursor: schema.frame.Cursor = .{},
    mouse: schema.frame.Mouse = .{},
    input_modes: schema.frame.InputModes = .{},
    pointer_shape: schema.frame.PointerShape = .default,
    scroll: schema.frame.Scroll,
    applied_frame_id: u64 = 0,
    pending_frame_id: u64 = 0,
    graphics_placeholder: bool = false,
    cwd: []u8 = &.{},
    foreground_name: [schema.max_foreground_name_bytes]u8 = @splat(0),
    foreground_name_len: u8 = 0,
    progress_state: schema.PaneProgressState = .remove,
    progress_percent: ?u8 = null,
    title: []u8 = &.{},

    pub const Initial = struct { spec: Spec, attached: bool };

    /// Reserves cells and row damage for one validated pane. Example: var pane = try Pane.init(gpa, initial);
    pub fn init(gpa: std.mem.Allocator, initial: Initial) !Pane {
        if (initial.spec.pane_id == .invalid) {
            return error.InvalidPaneId;
        }

        try initial.spec.size.validate();
        var buffer = try ui.Buffer.init(gpa, initial.spec.size.cols, initial.spec.size.rows);
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
    pub fn applyFrame(pane: *Pane, frame: schema.frame.FrameView) !frames.Applied {
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
        std.debug.assert(path.len != 0 and path.len <= schema.max_cwd_bytes);
        if (std.mem.eql(u8, pane.cwd, path)) {
            return false;
        }

        const display_changed = !std.mem.eql(u8, pane.cwdName(), displayCwdName(path));
        const replacement = try pane.gpa.dupe(u8, path);
        pane.gpa.free(pane.cwd);
        pane.cwd = replacement;
        return display_changed;
    }

    pub fn cwdName(pane: *const Pane) []const u8 {
        return displayCwdName(pane.cwd);
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
    pub fn setProgress(pane: *Pane, progress: schema.PaneProgress) bool {
        if (pane.progress_state == progress.state and pane.progress_percent == progress.percent) {
            return false;
        }

        pane.progress_state = progress.state;
        pane.progress_percent = progress.percent;
        return true;
    }

    /// Owns a validated window title independently of its request buffer. Example: _ = try pane.setTitle("vim");
    pub fn setTitle(pane: *Pane, title: []const u8) !bool {
        std.debug.assert(title.len <= schema.max_pane_title_bytes);
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
};

fn displayCwdName(path: []const u8) []const u8 {
    if (path.len == 0) {
        return "";
    }

    const basename = cwdBaseName(path);
    if (!validCwdName(basename)) {
        return "";
    }

    var end = @min(basename.len, max_cwd_name_bytes);
    while (end < basename.len and end > 0 and basename[end] & 0b1100_0000 == 0b1000_0000) {
        end -= 1;
    }

    return basename[0..end];
}

fn cwdBaseName(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and isPathSeparator(path[end - 1])) {
        end -= 1;
    }

    const trimmed = path[0..end];
    if (trimmed.len == 1 and isPathSeparator(trimmed[0])) {
        return trimmed;
    }

    const separator = std.mem.lastIndexOfAny(u8, trimmed, "/\\") orelse return trimmed;
    const name = trimmed[separator + 1 ..];
    return if (name.len == 0) trimmed else name;
}

fn validCwdName(name: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(name)) {
        return false;
    }

    for (name) |byte| {
        if (byte < 0x20 or byte == 0x7f) {
            return false;
        }
    }

    return true;
}

fn isPathSeparator(byte: u8) bool {
    return byte == '/' or byte == '\\';
}

test "pane cwd names use a bounded basename" {
    try std.testing.expectEqualStrings("telar", cwdBaseName("/work/telar"));
    try std.testing.expectEqualStrings("telar", cwdBaseName("/work/telar/"));
    try std.testing.expectEqualStrings("/", cwdBaseName("/"));
    try std.testing.expectEqualStrings("api", cwdBaseName("C:\\work\\api\\"));
    try std.testing.expectEqualStrings("relative", cwdBaseName("relative"));

    var pane: Pane = undefined;
    pane.gpa = std.testing.allocator;
    pane.cwd = &.{};
    defer pane.gpa.free(pane.cwd);
    const long_name = [_]u8{'x'} ** (max_cwd_name_bytes + 1);
    try std.testing.expect(try pane.setCwd("/work/telar"));
    try std.testing.expectEqualStrings("telar", pane.cwdName());
    try std.testing.expect(try pane.setCwd(&long_name));
    try std.testing.expectEqual(@as(usize, max_cwd_name_bytes), pane.cwdName().len);
    try std.testing.expect(try pane.setCwd("/work/\xff"));
    try std.testing.expectEqualStrings("", pane.cwdName());
    try std.testing.expect(!try pane.setCwd("/work/\x1b[31m"));
    try std.testing.expect(!try pane.setCwd("/other/\x1b[31m"));
    try std.testing.expectEqualStrings("/other/\x1b[31m", pane.cwdSlice());
}

test {
    _ = @import("tests.zig");
}
