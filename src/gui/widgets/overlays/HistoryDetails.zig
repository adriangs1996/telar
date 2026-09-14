const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const labels = @import("history_labels.zig");
const HistoryDetails = @This();

history: *const client.HistoryPaletteState,
selection: u16,
header: [80]u8 = undefined,
header_len: usize = 0,
author: [80]u8 = undefined,
author_len: usize = 0,
timestamp: [80]u8 = undefined,
timestamp_len: usize = 0,
duration: [80]u8 = undefined,
duration_len: usize = 0,

/// Borrows a selected command and formats its bounded metadata on the stack.
/// Example: `var detail = HistoryDetails.init(history, selection);`.
pub fn init(history: *const client.HistoryPaletteState, selection: u16) HistoryDetails {
    const entry = &history.slice()[selection];
    var detail: HistoryDetails = .{ .history = history, .selection = selection };
    var exit_storage: [16]u8 = undefined;
    const exit = if (entry.exit_code) |code| std.fmt.bufPrint(&exit_storage, "{d}", .{code}) catch "?" else "unknown";
    detail.header_len = (std.fmt.bufPrint(&detail.header, "#{d}  {s}  exit {s}", .{ entry.id, @tagName(entry.status), exit }) catch @as([]u8, detail.header[0..0])).len;
    detail.author_len = (std.fmt.bufPrint(&detail.author, "{s}  pane {d}", .{ @tagName(entry.author), core.raw(entry.pane_id) }) catch @as([]u8, detail.author[0..0])).len;
    var duration_storage: [32]u8 = undefined;
    detail.duration_len = (std.fmt.bufPrint(&detail.duration, "Duration: {s}", .{labels.duration(entry.duration_ns, &duration_storage)}) catch @as([]u8, detail.duration[0..0])).len;

    if (entry.started_at_ms < 0 or entry.started_at_ms > 253402300799999) {
        const unavailable = "Timestamp unavailable";
        @memcpy(detail.timestamp[0..unavailable.len], unavailable);
        detail.timestamp_len = unavailable.len;
    } else {
        const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divTrunc(entry.started_at_ms, 1000)) };
        const day = epoch.getEpochDay().calculateYearDay();
        const month = day.calculateMonthDay();
        const clock = epoch.getDaySeconds();
        detail.timestamp_len = (std.fmt.bufPrint(&detail.timestamp, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{ day.year, @intFromEnum(month.month), month.day_index + 1, clock.getHoursIntoDay(), clock.getMinutesIntoHour(), clock.getSecondsIntoMinute() }) catch @as([]u8, detail.timestamp[0..0])).len;
    }

    return detail;
}

/// Example: `for (detail.texts()) |text| { ... }`.
pub fn texts(detail: *const HistoryDetails) [8][]const u8 {
    const entry = &detail.history.slice()[detail.selection];
    return .{
        detail.header[0..detail.header_len],
        detail.history.commandAt(detail.selection) orelse entry.commandSlice(),
        entry.cwdSlice(),
        detail.author[0..detail.author_len],
        detail.timestamp[0..detail.timestamp_len],
        detail.duration[0..detail.duration_len],
        detail.history.outputHint(),
        detail.history.outputSlice(),
    };
}
