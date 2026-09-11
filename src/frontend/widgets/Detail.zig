const Inspection = @import("Inspection.zig");
const std = @import("std");
const raw_module = @import("telar-core").raw;
const history_browser = @import("history_browser.zig");
const Detail = @This();

content: Inspection,
header: [80]u8 = undefined,
header_len: usize = 0,
author: [80]u8 = undefined,
author_len: usize = 0,
time: [80]u8 = undefined,
time_len: usize = 0,
duration: [80]u8 = undefined,
duration_len: usize = 0,

pub fn init(content: Inspection) Detail {
    var detail: Detail = .{ .content = content };
    const entry = content.entry;
    var exit_storage: [16]u8 = undefined;
    const exit = if (entry.exit_code) |code| std.fmt.bufPrint(&exit_storage, "{d}", .{code}) catch "?" else "unknown";
    const header: []const u8 = std.fmt.bufPrint(&detail.header, "#{d}  {s}  exit {s}", .{ entry.id, @tagName(entry.status), exit }) catch "";
    detail.header_len = header.len;
    const author: []const u8 = std.fmt.bufPrint(&detail.author, "{s}  pane {d}", .{ @tagName(entry.author), raw_module(entry.pane_id) }) catch "";
    detail.author_len = author.len;
    const time = history_browser.timestampText(entry.started_at_ms, &detail.time);
    detail.time_len = time.len;
    @memmove(detail.time[0..time.len], time);
    var duration_storage: [32]u8 = undefined;
    const duration: []const u8 = std.fmt.bufPrint(&detail.duration, "Duration: {s}", .{history_browser.durationText(entry.duration_ns, &duration_storage)}) catch "";
    detail.duration_len = duration.len;
    return detail;
}

pub fn texts(detail: *const Detail) [8][]const u8 {
    return .{ detail.header[0..detail.header_len], detail.content.entry.command, detail.content.entry.cwd, detail.author[0..detail.author_len], detail.time[0..detail.time_len], detail.duration[0..detail.duration_len], detail.content.output_hint, detail.content.output };
}
