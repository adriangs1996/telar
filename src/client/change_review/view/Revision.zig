const core = @import("telar-core");
const std = @import("std");
const File = @import("ReviewFile.zig");
const Row = @import("ReviewLine.zig");
const limits = @import("limits.zig");
const Self = @This();

source: []const u8 = "",
files: [limits.files]File = undefined,
file_count: usize = 0,
rows: [limits.lines]Row = undefined,
row_count: usize = 0,
/// Files and rows of the edition past `limits.files` or `limits.lines`,
/// which the view leaves out; `source` then ends where they begin.
omitted_files: usize = 0,
omitted_rows: usize = 0,
/// Which of the two limits cut the edition, when one did.
cut: ?core.Limit = null,

/// Replaces the index while borrowing immutable source retained by its owner.
/// An edition past the view's limits keeps its first files and rows, and
/// `reach` says which limit cut it.
/// Example: `try revision.load(source);`
pub fn load(self: *Self, source: []const u8) !void {
    self.* = .{ .source = source };
    errdefer self.* = .{};
    var lines: core.ChangeReviewDiffLines = .{ .text = source };
    var hunk: usize = 0;
    while (true) {
        const start = lines.index;
        const line = lines.next() orelse break;
        if (line.kind == .file) {
            if (self.file_count == limits.files) {
                self.leaveOut(&lines, start, limits.files_limit);
                self.omitted_files += 1;
                break;
            }

            if (self.file_count > 0) {
                self.files[self.file_count - 1].end = start;
                self.files[self.file_count - 1].last = self.row_count;
            }

            self.files[self.file_count] = .{ .path = line.text, .start = start, .end = source.len, .first = self.row_count, .last = self.row_count, .counts = lines.counts() };
            self.file_count += 1;
        } else if (line.kind == .hunk) {
            hunk += 1;
        } else if (self.file_count > 0 and (line.old != null or line.new != null)) {
            if (self.row_count == limits.lines) {
                self.leaveOut(&lines, start, limits.lines_limit);
                self.omitted_rows += 1;
                break;
            }

            self.rows[self.row_count] = .{ .value = line, .offset = @intFromPtr(line.text.ptr) - @intFromPtr(source.ptr), .file = self.file_count - 1, .hunk = hunk };
            self.row_count += 1;
            self.files[self.file_count - 1].last = self.row_count;
        }
    }
}

/// The limit that cut this edition, with how many files or rows it has.
///
/// ```zig
/// if (revision.reach()) |reach| limit_reached.report(client, reach);
/// ```
pub fn reach(self: *const Self) ?core.LimitReach {
    const limit = self.cut orelse return null;
    const files_cut = std.mem.eql(u8, limit.name, limits.files_limit.name);
    const total = if (files_cut) self.file_count + self.omitted_files else self.row_count + self.omitted_rows;
    return .{
        .limit = limit,
        .requested = total,
    };
}

/// Ends the view at `start`, the line past a limit, and counts the files
/// and numbered rows after it. A last file the cut left without rows goes
/// too, since a file the view shows needs a row to select.
fn leaveOut(self: *Self, lines: *core.ChangeReviewDiffLines, start: usize, limit: core.Limit) void {
    self.cut = limit;
    self.source = self.source[0..start];
    if (self.file_count > 0) {
        self.files[self.file_count - 1].end = start;
    }

    if (self.file_count > 1 and self.files[self.file_count - 1].first == self.files[self.file_count - 1].last) {
        self.file_count -= 1;
        self.omitted_files += 1;
        self.source = self.source[0..self.files[self.file_count].start];
    }

    while (lines.next()) |line| {
        if (line.kind == .file) {
            self.omitted_files += 1;
        } else if (line.kind != .hunk and (line.old != null or line.new != null)) {
            self.omitted_rows += 1;
        }
    }
}

/// Rejects editions whose files cannot provide a valid line selection.
/// Example: `try revision.ensureReviewable();`
pub fn ensureReviewable(self: *const Self) !void {
    if (self.file_count == 0) {
        return error.ReviewEmptyRevision;
    }

    for (self.files[0..self.file_count]) |file| {
        if (file.path.len == 0) {
            return error.ReviewFileWithoutPath;
        }

        if (file.first == file.last) {
            return error.ReviewFileWithoutLines;
        }
    }
}

/// Resolves a path within this edition without assuming another edition's order.
/// Example: `const index = revision.findFile(path) orelse 0;`
pub fn findFile(self: *const Self, path: []const u8) ?usize {
    for (self.files[0..self.file_count], 0..) |file, index| {
        if (std.mem.eql(u8, file.path, path)) {
            return index;
        }
    }

    return null;
}

pub fn text(self: *const Self, file: usize) []const u8 {
    const entry = self.files[file];
    return self.source[entry.start..entry.end];
}

pub fn findRow(self: *const Self, offset: usize) ?usize {
    var low: usize = 0;
    var high = self.row_count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (self.rows[middle].offset <= offset) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    if (low == 0) {
        return null;
    }
    const row = self.rows[low - 1];
    return if (offset <= row.offset + row.value.text.len) low - 1 else null;
}

test "review row lookup resolves wrapped source offsets and excludes headers" {
    const source = "Updated file.zig\n@@ -1 +1 @@\n-before\n+after\n";
    var revision: Self = .{};
    try revision.load(source);
    try std.testing.expect(revision.findRow(0) == null);
    for (revision.rows[0..revision.row_count], 0..) |row, index| {
        try std.testing.expectEqual(index, revision.findRow(row.offset).?);
        try std.testing.expectEqual(index, revision.findRow(row.offset + row.value.text.len).?);
    }
    try std.testing.expect(revision.findRow(source.len) == null);
}

test "review prototype revision reload replaces every indexed file and row" {
    var revision: Self = .{};
    try revision.load("Updated old.zig\n@@ -1 +1 @@\n-before\n+after\nUpdated other.go\n@@ -0,0 +1 @@\n+package main\n");
    try revision.ensureReviewable();
    revision.files[0].reviewed = true;

    const source = "Added new.rs\n@@ -0,0 +1 @@\n+fn main() {}\n";
    try revision.load(source);
    try revision.ensureReviewable();
    try std.testing.expectEqual(@as(usize, 1), revision.file_count);
    try std.testing.expectEqual(@as(usize, 1), revision.row_count);
    try std.testing.expectEqualStrings(source, revision.text(0));
    try std.testing.expectEqualStrings("new.rs", revision.files[0].path);
    try std.testing.expect(!revision.files[0].reviewed);
    try std.testing.expectEqual(@as(usize, 0), revision.files[0].first);
    try std.testing.expectEqual(@as(usize, 1), revision.files[0].last);
    try std.testing.expectEqual(@as(?usize, null), revision.findFile("old.zig"));
    try std.testing.expectEqual(@as(?usize, 0), revision.findFile("new.rs"));
}

test "an edition past the view's file limit keeps its first files and names the limit" {
    const file = "Added overflow.zig\n@@ -0,0 +1 @@\n+new\n";
    var revision: Self = .{};
    try revision.load(file ** limits.files);
    try std.testing.expectEqual(@as(usize, limits.files), revision.file_count);
    try std.testing.expect(revision.reach() == null);

    const source = file ** (limits.files + 2);
    try revision.load(source);
    try revision.ensureReviewable();
    try std.testing.expectEqual(@as(usize, limits.files), revision.file_count);
    try std.testing.expectEqual(@as(usize, limits.files), revision.row_count);
    try std.testing.expectEqual(@as(usize, 2), revision.omitted_files);
    try std.testing.expectEqualStrings(source[0 .. file.len * limits.files], revision.source);
    try std.testing.expectEqualStrings(file, revision.text(limits.files - 1));

    const cut = revision.reach().?;
    try std.testing.expectEqualStrings("change_review.view_files", cut.limit.name);
    try std.testing.expectEqual(@as(?u64, limits.files + 2), cut.requested);
}

test "an edition past the view's row limit keeps its first rows and names the limit" {
    const rows = limits.lines + 3;
    const header = std.fmt.comptimePrint("Added long.zig\n@@ -0,0 +1,{d} @@\n", .{rows});
    const row = "+x\n";
    const source = header ++ row ** rows ++ "Added next.zig\n@@ -0,0 +1 @@\n+y\n";
    var revision: Self = .{};
    try revision.load(source);
    try revision.ensureReviewable();
    try std.testing.expectEqual(@as(usize, limits.lines), revision.row_count);
    try std.testing.expectEqual(@as(usize, 1), revision.file_count);
    try std.testing.expectEqual(@as(usize, 4), revision.omitted_rows);
    try std.testing.expectEqual(@as(usize, 1), revision.omitted_files);
    try std.testing.expectEqual(header.len + row.len * limits.lines, revision.source.len);
    try std.testing.expectEqual(revision.source.len, revision.files[0].end);

    const cut = revision.reach().?;
    try std.testing.expectEqualStrings("change_review.view_lines", cut.limit.name);
    try std.testing.expectEqual(@as(?u64, rows + 1), cut.requested);
}

test "a row limit at the first row of a file leaves that file out and keeps the files before it" {
    const header = std.fmt.comptimePrint("Added full.zig\n@@ -0,0 +1,{d} @@\n", .{limits.lines});
    const row = "+x\n";
    const first = header ++ row ** limits.lines;
    const source = first ++ "Added next.zig\n@@ -0,0 +1,2 @@\n+y\n+z\n";
    var revision: Self = .{};
    try revision.load(source);
    try revision.ensureReviewable();
    try std.testing.expectEqual(@as(usize, 1), revision.file_count);
    try std.testing.expectEqual(@as(usize, limits.lines), revision.row_count);
    try std.testing.expectEqual(@as(usize, 1), revision.omitted_files);
    try std.testing.expectEqual(@as(usize, 2), revision.omitted_rows);
    try std.testing.expectEqualStrings(first, revision.source);
    try std.testing.expectEqual(first.len, revision.files[0].end);
    try std.testing.expectEqualStrings("change_review.view_lines", revision.reach().?.limit.name);
}

test "review prototype live editions require a path and numbered rows in every file" {
    var revision: Self = .{};
    try revision.load("");
    try std.testing.expectError(error.ReviewEmptyRevision, revision.ensureReviewable());
    try revision.load("@@ -1 +1 @@\n-before\n+after\n");
    try std.testing.expectError(error.ReviewEmptyRevision, revision.ensureReviewable());
    try revision.load("Updated binary.dat\nBinary files differ\n");
    try std.testing.expectError(error.ReviewFileWithoutLines, revision.ensureReviewable());
    try revision.load("Updated ok.zig\n@@ -1 +1 @@\n-old\n+new\nUpdated empty.zig\n");
    try std.testing.expectError(error.ReviewFileWithoutLines, revision.ensureReviewable());
    try revision.load("Updated \n@@ -1 +1 @@\n-old\n+new\n");
    try std.testing.expectError(error.ReviewFileWithoutPath, revision.ensureReviewable());
}
