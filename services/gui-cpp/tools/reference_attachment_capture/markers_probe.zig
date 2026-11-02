const std = @import("std");
const cellgrid = @import("cellgrid");
const core = @import("telar-core");
const data = @import("model");
const markers = @import("client/attachments/markers.zig");
const MarkerScan = @import("client/attachments/MarkerScan.zig");
const MarkerScreen = @import("client/attachments/MarkerScreen.zig");
const path = data.attachments_path_marker;
const MarkerPosition = @import("client/attachments/MarkerPosition.zig");
const RemovalPlan = @import("client/attachments/MarkerRemovalPlan.zig");
extern "c" fn getchar() c_int;
extern "c" fn putchar(c_int) c_int;
const record_tag: c_int = 1;
const inverse_mask: u64 = 16;
const maximum_rows: u64 = 16;
const maximum_columns: u64 = 4096;
const path_capacity: usize = 8;

fn read() !u64 {
    var value: u64 = 0;
    for (0..@sizeOf(u64)) |index| {
        const byte = getchar();
        if (byte < 0) {
            return error.TruncatedInput;
        }
        const shift: u6 = @intCast(index * @bitSizeOf(u8));
        value |= @as(u64, @intCast(byte)) << shift;
    }

    return value;
}

fn write(value: u64) !void {
    for (0..@sizeOf(u64)) |index| {
        const shift: u6 = @intCast(index * @bitSizeOf(u8));
        if (putchar(@intCast((value >> shift) & std.math.maxInt(u8))) < 0) {
            return error.WriteFailed;
        }
    }
}

fn point(value: cellgrid.Point) !void {
    try write(value.x);
    try write(value.y);
}

fn numeric(value: ?MarkerPosition) !void {
    try write(@intFromBool(value != null));
    const marker = value orelse return;
    try write(marker.number);
    try point(marker.start);
    try point(marker.end);
}

fn plan(value: RemovalPlan.MarkerRemovalPlan) !void {
    switch (value) {
        .unreachable_marker => try write(0),
        .limited => |reach| {
            try write(1);
            try write(if (std.mem.eql(u8, reach.limit.name, "attachments.max_marker_navigation_steps")) 1 else 2);
            try write(reach.requested orelse std.math.maxInt(u64));
        },
        .planned => |removal| {
            try write(2);
            try write(@intFromEnum(removal.direction));
            try write(removal.steps);
            try write(@intFromEnum(removal.deletion));
            try write(removal.deletions);
            try write(removal.keyCount());
        },
    }
}

fn observe(screen: MarkerScreen, number: u16) !void {
    var scan: MarkerScan = .{ .buffer = screen.buffer };
    while (scan.next()) |marker| {
        try numeric(marker);
    }
    try numeric(null);
    try numeric(markers.findMarker(screen.buffer, number, screen.cursor));
    try write(@intFromBool(markers.markerPresent(screen.buffer, number)));
    try write(@intFromBool(markers.markerTouchesCursor(screen.buffer, .{ .ordinal = number, .cursor = screen.cursor, .deletion = .backward })));
    try write(@intFromBool(markers.markerTouchesCursor(screen.buffer, .{ .ordinal = number, .cursor = screen.cursor, .deletion = .forward })));
    try write(@intFromBool(markers.promptContinuesAtCursor(screen)));
    try write(markers.atomicSteps(screen.buffer, screen.cursor.y, .{ .from = 0, .to = screen.cursor.x }) orelse std.math.maxInt(u64));
    try plan(markers.planPlaceholderRemoval(if (number != 0) number else null, 0, screen));
    var paths: [path_capacity]data.Marker = undefined;
    const count = path.collect(screen.buffer, &paths);
    try write(count);
    for (paths[0..count]) |marker| {
        for (marker.uuid) |byte| {
            try write(byte);
        }
        try write(marker.start.x);
        try write(marker.start.y);
        try write(marker.end.x);
        try write(marker.end.y);
        try write(marker.cells orelse std.math.maxInt(u64));
        try write(@intFromBool(path.cursorAt(markers.pathScreen(screen), marker.start)));
        try write(@intFromBool(path.cursorAt(markers.pathScreen(screen), marker.end)));
        try write(path.cursorOnRow(markers.pathScreen(screen), marker.end.y) orelse std.math.maxInt(u64));
    }
    try plan(markers.planPathRemoval(if (count != 0) paths[0].uuid else null, screen));
}

pub fn main() !void {
    const gpa = std.heap.c_allocator;
    while (true) {
        const tag = getchar();
        if (tag < 0) {
            return;
        }
        if (tag != record_tag) {
            return error.InvalidProbeRecord;
        }

        const columns = try read();
        const rows = try read();
        if (columns == 0 or rows == 0 or columns > maximum_columns or rows > maximum_rows) {
            return error.InvalidProbeGrid;
        }
        const cursor: core.Cursor = .{ .x = @intCast(try read()), .y = @intCast(try read()), .visible = try read() != 0 };
        const number: u16 = @intCast(try read());
        if (cursor.x > columns or cursor.y >= rows) {
            return error.InvalidProbeCursor;
        }
        var buffer = try cellgrid.Buffer.init(gpa, @intCast(columns), @intCast(rows));
        defer buffer.deinit();
        for (buffer.cells) |*cell| {
            cell.len = @intCast(try read());
            cell.width = @intCast(try read());
            cell.style.flags.inverse = try read() & inverse_mask != 0;
            if (cell.len > cellgrid.Cell.max_bytes or cell.width > 2) {
                return error.InvalidProbeCell;
            }
            for (cell.bytes[0..cell.len]) |*byte| {
                byte.* = @intCast(try read());
            }
        }
        try observe(.{ .buffer = &buffer, .cursor = cursor }, number);
    }
}
