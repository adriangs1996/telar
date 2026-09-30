//! Incremental, allocation-free search of a terminal's scrollback: a
//! Knuth-Morris-Pratt matcher over codepoints, ASCII case folded unless the
//! needle has an uppercase letter, advanced a bounded number of rows per
//! call so a search never stalls the caller. Rows are searched from the
//! newest back, so a search with more matches than it keeps keeps the ones
//! nearest the prompt.
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
        /// Rows still to search are `first_row..next_row`, taken newest
        /// first, so the matches kept are the newest ones.
        first_row: usize = 0,
        next_row: usize = 0,
        /// Matches found so far, newest first; `ordered` copies them out in
        /// document order.
        matches: [limits.matches]Match = undefined,
        count: u16 = 0,
        /// Some match or row was left out; the flags below say which bound.
        truncated: bool = false,
        /// Rows older than the newest `limits.rows` were not searched.
        rows_cut: bool = false,
        /// Cells past `limits.columns` of some row were not searched.
        columns_cut: bool = false,
        /// Older matches did not fit `limits.matches`.
        matches_cut: bool = false,

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

        /// Advances against an idle pane from the newest row back;
        /// changes invalidate all partial results. Returns true once the
        /// search is complete: every row searched, or the matches full.
        /// `pane` provides `ingest_pending`, `search_revision` and a
        /// ghostty-vt `terminal`.
        /// Example: `if (try cursor.advance(pane)) publish(cursor.ordered(&storage));`.
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
                self.next_row = pages.total_rows;
                self.first_row = self.next_row -| limits.rows;
                self.rows_cut = self.first_row != 0;
                self.truncated = self.rows_cut;
            }

            const stop = @max(self.first_row, self.next_row -| limits.rows_per_turn);
            while (self.next_row > stop) {
                self.next_row -= 1;
                if (!self.searchRow(pages, self.next_row)) {
                    self.first_row = self.next_row;
                    return true;
                }
            }

            return self.next_row == self.first_row;
        }

        /// Copies the matches found so far into `output` in document order.
        /// Example: `const found = cursor.ordered(&storage);`.
        pub fn ordered(self: *const Cursor, output: []Match) []Match {
            const count = @min(output.len, self.count);
            for (output[0..count], 0..) |*match, index| {
                match.* = self.matches[self.count - 1 - index];
            }

            return output[0..count];
        }

        /// Adds one row's matches, rightmost first. Returns false once a
        /// match did not fit, which ends the search.
        fn searchRow(self: *Cursor, pages: anytype, row: usize) bool {
            const pin = pages.pin(.{ .screen = .{ .x = 0, .y = @intCast(row) } }) orelse return true;
            var columns: [limits.columns]u16 = undefined;
            var found: [limits.columns]Match = undefined;
            var found_count: usize = 0;
            var row_length: usize = 0;
            var matched: usize = 0;
            for (pin.cells(.all), 0..) |cell, column| {
                if (row_length == columns.len) {
                    self.columns_cut = true;
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

                const first = columns[row_length - self.needle_len];
                found[found_count] = .{
                    .x = first,
                    .y = @intCast(row),
                    .len = @as(u16, @intCast(column)) - first + 1,
                };
                found_count += 1;
                matched = 0;
            }

            while (found_count != 0) {
                if (self.count == self.matches.len) {
                    self.matches_cut = true;
                    self.truncated = true;
                    return false;
                }

                found_count -= 1;
                self.matches[self.count] = found[found_count];
                self.count += 1;
            }

            return true;
        }

        fn normalize(self: *const Cursor, point: u21) u21 {
            return if (self.fold and point < 128) std.ascii.toLower(@intCast(point)) else point;
        }
    };
}
