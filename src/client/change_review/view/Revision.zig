const std = @import("std");
const Lines = @import("telar-core").ChangeReviewDiffLines;
const File = @import("ReviewFile.zig");
const Row = @import("ReviewLine.zig");
const limits = @import("limits.zig");
const Self = @This();

source: []const u8 = "",
files: [limits.files]File = undefined,
file_count: usize = 0,
rows: [limits.lines]Row = undefined,
row_count: usize = 0,

/// Replaces the index while borrowing immutable source retained by its owner.
/// Example: `try revision.load(source);`
pub fn load(self: *Self, source: []const u8) !void {
    self.* = .{ .source = source };
    errdefer self.* = .{};
    var lines: Lines = .{ .text = source };
    var hunk: usize = 0;
    while (true) {
        const start = lines.index;
        const line = lines.next() orelse break;
        if (line.kind == .file) {
            if (self.file_count == limits.files) {
                return error.ReviewFileLimit;
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
                return error.ReviewLineLimit;
            }

            self.rows[self.row_count] = .{ .value = line, .offset = @intFromPtr(line.text.ptr) - @intFromPtr(source.ptr), .file = self.file_count - 1, .hunk = hunk };
            self.row_count += 1;
            self.files[self.file_count - 1].last = self.row_count;
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

    try std.testing.expectError(error.ReviewFileLimit, revision.load("Added overflow.zig\n@@ -0,0 +1 @@\n+new\n" ** (limits.files + 1)));
    try std.testing.expectEqual(@as(usize, 0), revision.file_count);
    try std.testing.expectEqual(@as(usize, 0), revision.row_count);
    try std.testing.expectEqualStrings("", revision.source);
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
