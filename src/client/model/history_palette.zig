//! Bounded storage for the latest history-palette results. The palette only
//! shows the newest reply for the newest query, so stale replies are ignored
//! by request id instead of queued.

const HistoryPaletteState = @import("HistoryPaletteState.zig");
const std = @import("std");
const HistoryScopeType = @import("telar-core").HistoryScope;
const PageResultType = @import("PageResult.zig");
const HistoryEntryType = @import("telar-core").HistoryEntry;
const HistoryOutputType = @import("telar-core").HistoryOutput;
const max_history_command_bytes_module = @import("telar-core").max_history_command_bytes;

pub const max_command_bytes = 512;
pub const max_entry_cwd_bytes = 256;
pub const max_command_storage = 768 * 1024;

test "page results commit metadata once and stale replies cannot alter it" {
    var state: HistoryPaletteState = .{};
    try std.testing.expect(state.beginPageRequest(1, .cwd));
    try std.testing.expectEqual(HistoryScopeType.cwd, state.effective_scope);
    try std.testing.expect(state.beginPageRequest(2, .workspace));
    const before = state.revision;
    const page: PageResultType = .{ .request_id = 2, .entries = &.{}, .snapshot_id = 30, .has_more = true, .now_ms = 100 };
    var stale = page;
    stale.request_id = 1;
    stale.snapshot_id = 99;
    try std.testing.expect(!state.acceptPageResult(stale));
    try std.testing.expectEqual(before, state.revision);
    try std.testing.expectEqual(@as(u64, 0), state.snapshot_id);
    try std.testing.expect(state.acceptPageResult(page));
    try std.testing.expectEqual(before + 1, state.revision);
    try std.testing.expectEqual(@as(u64, 30), state.snapshot_id);
    try std.testing.expectEqual(@as(i64, 100), state.now_ms);
    try std.testing.expect(state.has_more);
    try std.testing.expect(!state.acceptPageResult(page));
    try std.testing.expectEqual(before + 1, state.revision);
}

pub fn copyBounded(buffer: []u8, source: []const u8) u16 {
    var len = @min(buffer.len, source.len);
    while (len < source.len and len > 0 and source[len] & 0xc0 == 0x80) {
        len -= 1;
    }

    @memcpy(buffer[0..len], source[0..len]);
    return @intCast(len);
}

test "only the awaited reply lands and commands stay bounded" {
    var state: HistoryPaletteState = .{};
    state.begin();
    try std.testing.expect(state.beginPageRequest(7, .global));

    const long = "x" ** (max_command_bytes + 32);
    const entries = [_]HistoryEntryType{
        .{
            .id = 1,
            .pane_id = @enumFromInt(1),
            .started_at_ms = 0,
            .duration_ns = 0,
            .exit_code = 0,
            .status = .completed,
            .command = "git status",
            .cwd = "/work",
            .workspace_path = "/work",
        },
        .{
            .id = 2,
            .pane_id = @enumFromInt(1),
            .started_at_ms = 0,
            .duration_ns = 0,
            .exit_code = null,
            .status = .interrupted,
            .command = long,
            .cwd = "/work",
            .workspace_path = "/work",
        },
    };

    try std.testing.expect(!state.acceptPageResult(.{ .request_id = 6, .entries = &entries, .snapshot_id = 0, .has_more = false, .now_ms = 0 }));
    try std.testing.expectEqual(@as(u8, 0), state.len);

    try std.testing.expect(state.acceptPageResult(.{ .request_id = 7, .entries = &entries, .snapshot_id = 0, .has_more = false, .now_ms = 0 }));
    try std.testing.expectEqual(@as(u8, 2), state.len);
    try std.testing.expectEqualStrings("git status", state.slice()[0].commandSlice());
    try std.testing.expectEqual(@as(u16, max_command_bytes), state.slice()[1].command_len);
}

test "history retains full command bytes and rejects actions on stale results" {
    var state: HistoryPaletteState = .{};
    try state.prepare(std.testing.allocator);
    defer state.deinit();
    var command = [_]u8{'x'} ** (max_command_bytes + 100);
    const entry: HistoryEntryType = .{ .id = 7, .pane_id = @enumFromInt(1), .started_at_ms = 123, .duration_ns = 9000, .exit_code = 1, .status = .completed, .command = &command, .cwd = "/work", .workspace_path = "/work" };
    try std.testing.expect(state.beginPageRequest(1, .global));
    try std.testing.expect(state.acceptPageResult(.{ .request_id = 1, .entries = &.{entry}, .snapshot_id = 0, .has_more = false, .now_ms = 0 }));
    command[0] = 'z';

    const full = state.commandAt(0).?;
    try std.testing.expectEqual(@as(usize, max_command_bytes + 100), full.len);
    try std.testing.expectEqual(@as(u8, 'x'), full[0]);
    try std.testing.expectEqual(@as(i64, 123), state.slice()[0].started_at_ms);
    try std.testing.expect(state.beginPageRequest(2, .global));
    try std.testing.expect(state.commandAt(0) == null);
}

test "inspector owns output and ignores replies and failures from replaced selections" {
    var state: HistoryPaletteState = .{};
    try state.prepare(std.testing.allocator);
    defer state.deinit();
    try std.testing.expect(state.track(5));
    state.expectOutput(.{ .request_id = 5, .id = 10 });
    try std.testing.expect(state.track(6));
    state.expectOutput(.{ .request_id = 6, .id = 11 });
    var content = [_]u8{ 'o', 'k' };
    const reply: HistoryOutputType = .{ .request_id = @enumFromInt(6), .id = 11, .truncated = true, .observed_bytes = 100, .content = &content };
    try std.testing.expect(state.applyOutput(reply));
    content[0] = 'x';
    try std.testing.expectEqualStrings("ok", state.outputSlice());
    try std.testing.expect(state.output_truncated);
    try std.testing.expect(state.fail(.{ .request_id = @enumFromInt(5), .code = .resource_limit, .message = "old failure" }));
    try std.testing.expect(state.output_phase == .ready);
    state.clearOutput();
    try std.testing.expect(!state.applyOutput(reply));
}

test "captured truncation blocks paste and unicode previews end at a codepoint boundary" {
    var state: HistoryPaletteState = .{};
    const command = "x" ** (max_command_bytes - 1) ++ "é";
    const entry: HistoryEntryType = .{ .id = 7, .pane_id = @enumFromInt(1), .started_at_ms = 0, .duration_ns = 0, .exit_code = null, .status = .completed, .command = command, .cwd = "", .workspace_path = "", .command_truncated = true };
    try std.testing.expect(state.beginPageRequest(1, .global));
    try std.testing.expect(state.acceptPageResult(.{ .request_id = 1, .entries = &.{entry}, .snapshot_id = 0, .has_more = false, .now_ms = 0 }));
    try std.testing.expect(state.commandAt(0) == null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(state.slice()[0].commandSlice()));
    try std.testing.expectEqual(@as(u16, max_command_bytes - 1), state.slice()[0].command_len);
}

test "command storage exhaustion uses one correlated full-command fallback" {
    var state: HistoryPaletteState = .{};
    try state.prepare(std.testing.allocator);
    defer state.deinit();
    const command = "x" ** max_history_command_bytes_module;
    var entries: [14]HistoryEntryType = undefined;
    for (&entries, 0..) |*entry, index| {
        entry.* = .{ .id = index + 1, .pane_id = @enumFromInt(1), .started_at_ms = 0, .duration_ns = 0, .exit_code = 0, .status = .completed, .command = command, .cwd = "", .workspace_path = "" };
    }

    try std.testing.expect(state.beginPageRequest(1, .global));
    try std.testing.expect(state.acceptPageResult(.{ .request_id = 1, .entries = &entries, .snapshot_id = 0, .has_more = false, .now_ms = 0 }));
    try std.testing.expect(state.commandAt(13) == null);
    try std.testing.expect(state.track(2));
    state.expectFull(.{ .request_id = 2, .id = 14 });
    try std.testing.expect(!state.applyFull(3, entries[13..14]));
    try std.testing.expect(state.applyFull(2, entries[13..14]));
    try std.testing.expectEqualStrings(command, state.commandAt(13).?);
    try std.testing.expect(state.commandAt(12) == null);
    try std.testing.expect(state.beginPageRequest(4, .global));
    try std.testing.expect(!state.applyFull(2, entries[13..14]));
    try std.testing.expect(state.commandAt(13) == null);
}
