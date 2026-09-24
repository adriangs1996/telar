//! Incremental, allocation-free search of a terminal's scrollback: a
//! Knuth-Morris-Pratt matcher over codepoints, ASCII case folded unless the
//! needle has an uppercase letter, advanced a bounded number of rows per
//! call so a search never stalls the caller.
const std = @import("std");
const SearchLimits = @import("SearchLimits.zig");

/// `Match` is the caller's result type with `x: u16`, `y: u32` and `len: u16`.
/// Example: `const Search = GenericSearch(SearchMatch, limits);`
pub fn Type(comptime Match: type, comptime limits: SearchLimits) type {
    return struct {
        const Cursor = @This();

        pub const rows_per_turn = limits.rows_per_turn;

        needle: [limits.needle_codepoints]u21 = undefined,
        prefix: [limits.needle_codepoints]usize = undefined,
        needle_len: usize = 0,
        fold: bool = true,
        revision: ?u64 = null,
        next_row: usize = 0,
        end_row: usize = 0,
        matches: [limits.matches]Match = undefined,
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
        /// `pane` provides `ingest_pending`, `search_revision` and a ghostty-vt
        /// `terminal`.
        /// Example: `if (try cursor.advance(pane)) publish(cursor);`.
        pub fn advance(self: *Cursor, pane: anytype) !bool {
            if (pane.ingest_pending) {
                return false;
            }
            if (self.needle_len == 0) {
                return true;
            }

            const pages = &pane.terminal.screens.active.pages;
            if (self.revision) |revision| {
                if (revision != pane.search_revision) {
                    return error.SearchInvalidated;
                }
            } else {
                self.revision = pane.search_revision;
                self.end_row = pages.total_rows;
                self.next_row = self.end_row -| limits.rows;
                self.truncated = self.next_row != 0;
            }

            const end = @min(self.end_row, self.next_row + limits.rows_per_turn);
            while (self.next_row < end) : (self.next_row += 1) {
                const pin = pages.pin(.{ .screen = .{ .x = 0, .y = @intCast(self.next_row) } }) orelse continue;
                var columns: [limits.columns]u16 = undefined;
                var row_length: usize = 0;
                var matched: usize = 0;
                for (pin.cells(.all), 0..) |cell, column| {
                    if (row_length == columns.len) {
                        self.truncated = true;
                        break;
                    }
                    if (cell.wide == .spacer_tail or cell.wide == .spacer_head) {
                        continue;
                    }

                    columns[row_length] = @intCast(column);
                    row_length += 1;
                    const point = self.normalize(if (cell.hasText()) cell.codepoint() else ' ');
                    while (matched != 0 and point != self.needle[matched]) {
                        matched = self.prefix[matched - 1];
                    }
                    if (point == self.needle[matched]) {
                        matched += 1;
                    }
                    if (matched != self.needle_len) {
                        continue;
                    }
                    if (self.count == self.matches.len) {
                        self.truncated = true;
                        return true;
                    }

                    const first = columns[row_length - self.needle_len];
                    self.matches[self.count] = .{
                        .x = first,
                        .y = @intCast(self.next_row),
                        .len = @as(u16, @intCast(column)) - first + 1,
                    };
                    self.count += 1;
                    matched = 0;
                }
            }

            return self.next_row == self.end_row;
        }

        fn normalize(self: *const Cursor, point: u21) u21 {
            return if (self.fold and point < 128) std.ascii.toLower(@intCast(point)) else point;
        }
    };
}
