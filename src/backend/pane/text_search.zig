//! Incremental copy-mode search. Each runtime turn inspects at most 32 rows.
const std = @import("std");
const core = @import("telar-core");
const schema = core.schema;
pub const max_rows = 10_000;
pub const max_cols = 512;

pub const Cursor = struct {
    pub const rows_per_turn = 32;
    needle: [schema.max_search_needle_bytes]u21 = undefined,
    prefix: [schema.max_search_needle_bytes]usize = undefined,
    needle_len: usize = 0,
    fold: bool = true,
    revision: ?u64 = null,
    next_row: usize = 0,
    end_row: usize = 0,
    matches: [schema.max_search_matches]schema.SearchMatch = undefined,
    count: u8 = 0,
    truncated: bool = false,

    /// Compiles an owned, linear-time matcher without allocating.
    /// Example: `var cursor = Cursor.init("error");`.
    pub fn init(text: []const u8) Cursor {
        var cursor: Cursor = .{};
        var iterator = std.unicode.Utf8View.initUnchecked(text).iterator();
        while (iterator.nextCodepoint()) |point| {
            if (cursor.needle_len == cursor.needle.len) {
                break;
            }

            cursor.needle[cursor.needle_len] = point;
            cursor.needle_len += 1;
            if (point < 128 and std.ascii.isUpper(@intCast(point))) {
                cursor.fold = false;
            }
        }

        for (cursor.needle[0..cursor.needle_len], 0..) |point, index| {
            cursor.needle[index] = cursor.normalize(point);
        }
        if (cursor.needle_len != 0) {
            cursor.prefix[0] = 0;
        }

        var length: usize = 0;
        var index: usize = 1;
        while (index < cursor.needle_len) : (index += 1) {
            while (length != 0 and cursor.needle[index] != cursor.needle[length]) {
                length = cursor.prefix[length - 1];
            }
            if (cursor.needle[index] == cursor.needle[length]) {
                length += 1;
            }

            cursor.prefix[index] = length;
        }

        return cursor;
    }

    /// Advances against an idle pane; changes invalidate all partial results.
    /// Example: `if (try cursor.advance(pane)) publish(cursor);`.
    pub fn advance(cursor: *Cursor, pane: anytype) !bool {
        if (pane.ingest_pending) {
            return false;
        }
        if (cursor.needle_len == 0) {
            return true;
        }

        const pages = &pane.terminal.screens.active.pages;
        if (cursor.revision) |revision| {
            if (revision != pane.search_revision) {
                return error.SearchInvalidated;
            }
        } else {
            cursor.revision = pane.search_revision;
            cursor.end_row = pages.total_rows;
            cursor.next_row = cursor.end_row -| max_rows;
            cursor.truncated = cursor.next_row != 0;
        }

        const end = @min(cursor.end_row, cursor.next_row + rows_per_turn);
        while (cursor.next_row < end) : (cursor.next_row += 1) {
            const pin = pages.pin(.{ .screen = .{ .x = 0, .y = @intCast(cursor.next_row) } }) orelse continue;
            var columns: [max_cols]u16 = undefined;
            var row_length: usize = 0;
            var matched: usize = 0;
            for (pin.cells(.all), 0..) |cell, column| {
                if (row_length == columns.len) {
                    cursor.truncated = true;
                    break;
                }
                if (cell.wide == .spacer_tail or cell.wide == .spacer_head) {
                    continue;
                }

                columns[row_length] = @intCast(column);
                row_length += 1;
                const point = cursor.normalize(if (cell.hasText()) cell.codepoint() else ' ');
                while (matched != 0 and point != cursor.needle[matched]) {
                    matched = cursor.prefix[matched - 1];
                }
                if (point == cursor.needle[matched]) {
                    matched += 1;
                }
                if (matched != cursor.needle_len) {
                    continue;
                }
                if (cursor.count == cursor.matches.len) {
                    cursor.truncated = true;
                    return true;
                }

                const first = columns[row_length - cursor.needle_len];
                cursor.matches[cursor.count] = .{
                    .x = first,
                    .y = @intCast(cursor.next_row),
                    .len = @as(u16, @intCast(column)) - first + 1,
                };
                cursor.count += 1;
                matched = 0;
            }
        }

        return cursor.next_row == cursor.end_row;
    }

    fn normalize(cursor: *const Cursor, point: u21) u21 {
        return if (cursor.fold and point < 128) std.ascii.toLower(@intCast(point)) else point;
    }
};
