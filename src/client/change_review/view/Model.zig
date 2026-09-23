const std = @import("std");
const Revision = @import("Revision.zig");
const Comment = @import("Comment.zig");
const Anchor = @import("Anchor.zig");
const limits = @import("limits.zig");
const data = @import("model");
const SearchMatch = @import("SearchMatch.zig");
const Self = @This();

revisions: [2]Revision = @splat(.{}),
revision: usize = 0,
file: usize = 0,
head: usize = 0,
tail: usize = 0,
visual: bool = false,
search: Search = .{},
comments: [limits.comments]Comment = @splat(.{}),
editing: ?usize = null,
expanded: ?usize = null,
available: bool = false,
status: []const u8 = "Local prototype · comments stay in this window",

pub fn current(self: *Self) *Revision {
    return &self.revisions[self.revision];
}

pub fn selectFile(self: *Self, file: usize) void {
    if (file >= self.current().file_count) {
        return;
    }

    self.file = file;
    self.search.match = null;
    self.head = self.current().files[file].first;
    self.cancelVisual();
    self.editing = null;
    self.expanded = null;
}

pub fn toggleVisual(self: *Self) void {
    self.visual = !self.visual;
    self.tail = self.head;
}

pub fn cancelVisual(self: *Self) void {
    self.visual = false;
    self.tail = self.head;
}

/// Extension cannot cross a hunk, file, revision or before/after side.
/// Example: `model.select(.{ row, @intFromBool(extend) });`
pub fn select(self: *Self, request: struct { row: usize, extend: bool }) void {
    const revision = self.current();
    if (request.row >= revision.row_count or revision.rows[request.row].file != self.file) {
        return;
    }

    const old = revision.rows[self.tail];
    const next = revision.rows[request.row];
    if (self.visual and request.extend and (old.hunk != next.hunk or old.before() != next.before())) {
        return;
    }

    if (!request.extend) {
        self.visual = false;
    }

    if (!request.extend or old.hunk != next.hunk or old.before() != next.before()) {
        self.tail = request.row;
    }

    self.head = request.row;
    self.search.match = null;
}

/// Moves by selectable lines, clamping at file and visual-selection boundaries.
/// Example: `model.move(.{ .delta = 12, .extend = model.visual });`
pub fn move(self: *Self, request: struct { delta: i32, extend: bool, hunk: bool = false }) void {
    if (request.delta == 0 or self.current().file_count == 0) {
        return;
    }

    if (request.hunk) {
        self.cancelVisual();
    }

    const revision = self.current();
    const file = revision.files[self.file];
    if (file.first == file.last) {
        return;
    }

    const current_hunk = revision.rows[self.head].hunk;
    const step: i64 = if (request.delta > 0) 1 else -1;
    var remaining = @abs(request.delta);
    var at: i64 = @intCast(self.head);
    while (true) {
        at += step;
        if (at < file.first or at >= file.last) {
            if (request.hunk) {
                if (request.delta > 0 and self.file + 1 < revision.file_count) {
                    self.selectFile(self.file + 1);
                } else if (request.delta < 0 and self.file > 0) {
                    self.selectFile(self.file - 1);
                    self.head = revision.files[self.file].last - 1;
                    self.tail = self.head;
                }
            }
            return;
        }

        const row: usize = @intCast(at);
        if (self.visual and revision.rows[row].hunk != current_hunk) {
            return;
        }

        if (request.hunk and revision.rows[row].hunk == current_hunk) {
            continue;
        }

        if (request.extend and revision.rows[row].before() != revision.rows[self.tail].before()) {
            continue;
        }

        self.select(.{ .row = row, .extend = request.extend });
        remaining -= 1;
        if (request.hunk or remaining == 0) {
            return;
        }
    }
}

/// Selects the first permitted line of the current file or visual range.
/// Example: `model.first();`
pub fn first(self: *Self) void {
    self.search.match = null;
    self.move(.{ .delta = -limits.lines, .extend = self.visual });
}

/// Selects the last permitted line of the current file or visual range.
/// Example: `model.last();`
pub fn last(self: *Self) void {
    self.search.match = null;
    self.move(.{ .delta = limits.lines, .extend = self.visual });
}

/// Searches literal UTF-8 text in the current file, starting with the selected line.
/// Example: `const found = model.startSearch("café");`
pub fn startSearch(self: *Self, query: []const u8) bool {
    if (!self.search.setQuery(query)) {
        return false;
    }

    return self.repeatSearch(.forward);
}

/// Finds the next occurrence with wrap, preserving visual hunk and side ownership.
/// Example: `const found = model.repeatSearch(.backward);`
pub fn repeatSearch(self: *Self, direction: Search.Direction) bool {
    const revision = self.current();
    const query = self.search.query.text();
    if (query.len == 0 or revision.file_count == 0) {
        return false;
    }

    const file = revision.files[self.file];
    const count = file.last - file.first;
    if (count == 0) {
        return false;
    }

    const origin = self.head - file.first;
    const previous = self.search.match;
    for (0..count + 1) |step| {
        const relative = switch (direction) {
            .forward => (origin + step) % count,
            .backward => (origin + count - step % count) % count,
        };
        const row_index = file.first + relative;
        const row = revision.rows[row_index];
        const anchor_row = revision.rows[self.tail];
        if (self.visual and (row.hunk != anchor_row.hunk or row.before() != anchor_row.before())) {
            continue;
        }

        const text = row.value.text;
        const cursor = if (step == 0 and previous != null and previous.?.row == self.head) previous else null;
        const at = switch (direction) {
            .forward => forward: {
                const start = if (cursor) |match| match.start + 1 else 0;
                break :forward if (start <= text.len) std.mem.indexOfPos(u8, text, start, query) else null;
            },
            .backward => backward: {
                const end = if (cursor) |match| @min(text.len, match.start + query.len - 1) else text.len;
                break :backward std.mem.lastIndexOf(u8, text[0..end], query);
            },
        } orelse continue;
        self.select(.{ .row = row_index, .extend = self.visual });
        self.search.match = .{ .row = row_index, .start = at, .end = at + query.len };
        return true;
    }

    self.search.match = null;
    return false;
}

/// Clears the committed query without changing the current line or visual anchor.
/// Example: `model.clearSearch();`
pub fn clearSearch(self: *Self) void {
    self.search = .{};
}

pub fn anchor(self: *Self) Anchor {
    return .{ .revision = self.revision, .file = self.file, .first = @min(self.head, self.tail), .last = @max(self.head, self.tail), .before = self.current().rows[self.head].before() };
}

/// Existing drafts at this anchor resume; all other drafts retain their owner.
/// Example: `model.comment();`
pub fn comment(self: *Self) void {
    const location = self.anchor();
    self.head = location.last;
    self.tail = location.first;
    for (&self.comments, 0..) |*entry, index| {
        if (entry.alive and entry.draft and std.meta.eql(entry.anchor, location)) {
            self.visual = false;
            self.editing = index;
            self.expanded = index;
            return;
        }
    }

    for (&self.comments, 0..) |*entry, index| {
        if (!entry.alive and !entry.pending) {
            entry.* = .{ .anchor = location, .alive = true };
            self.visual = false;
            self.editing = index;
            self.expanded = index;
            return;
        }
    }

    self.status = "Comment limit reached (32). Delete a comment to add another.";
}

pub fn save(self: *Self) void {
    const index = self.editing orelse return;
    const entry = &self.comments[index];
    if (std.mem.trim(u8, entry.body.text(), " \t\r\n").len == 0) {
        self.status = "Write a comment before saving.";
        return;
    }

    entry.draft = false;
    self.editing = null;
    self.status = "Comment saved locally. Nothing has been sent to an agent.";
}

pub fn simulate(self: *Self) void {
    if (self.available) {
        return;
    }

    self.available = true;
    for (self.revisions[0].files[0..self.revisions[0].file_count], 0..) |file, index| {
        const next = self.revisions[1].findFile(file.path) orelse continue;
        if (std.mem.eql(u8, self.revisions[0].text(index), self.revisions[1].text(next))) {
            self.revisions[1].files[next].reviewed = file.reviewed;
        }
    }

    self.status = "Edition 2 is available. Your current review has not moved.";
}

pub fn switchRevision(self: *Self) void {
    if (!self.available) {
        return;
    }

    const path = self.current().files[self.file].path;
    self.revision = 1 - self.revision;
    self.selectFile(self.current().findFile(path) orelse 0);
    self.status = "Comments and drafts remain attached to their original edition.";
}

const test_source = "Updated file.zig\n@@ -1,2 +1,2 @@\n-old\n+new\n context\n@@ -20 +20 @@\n-before\n+after\nUpdated other.go\n@@ -0,0 +1 @@\n+package main\n";

fn fixture() !*Self {
    const model = try std.testing.allocator.create(Self);
    errdefer std.testing.allocator.destroy(model);
    model.* = .{};
    try model.revisions[0].load(test_source);
    try model.revisions[1].load("Updated file.zig\n@@ -1 +1,2 @@\n-old\n+inserted\n+new\nUpdated other.go\n@@ -0,0 +1 @@\n+package main\n");
    model.selectFile(0);
    return model;
}

test "review prototype anchors keep editions files sides and hunk boundaries" {
    const model = try fixture();
    defer std.testing.allocator.destroy(model);
    model.select(.{ .row = 1, .extend = false });
    model.select(.{ .row = 2, .extend = true });
    try std.testing.expectEqual(@as(usize, 1), model.anchor().first);
    try std.testing.expectEqual(@as(usize, 2), model.anchor().last);
    model.select(.{ .row = 0, .extend = true });
    try std.testing.expect(model.anchor().before);
    try std.testing.expectEqual(model.head, model.tail);
    model.select(.{ .row = 4, .extend = true });
    try std.testing.expectEqual(model.head, model.tail);
    const before = model.head;
    model.select(.{ .row = 5, .extend = true });
    try std.testing.expectEqual(before, model.head);
    model.move(.{ .delta = -1, .extend = false, .hunk = true });
    try std.testing.expectEqual(@as(usize, 2), model.head);
}

test "review prototype drafts survive navigation and comments never migrate to new editions" {
    const model = try fixture();
    defer std.testing.allocator.destroy(model);
    model.select(.{ .row = 1, .extend = false });
    model.comment();
    const index = model.editing.?;
    _ = model.comments[index].body.replace(.{ 0, 0 }, "Check café and 界");
    const original = model.comments[index].anchor;
    model.selectFile(1);
    try std.testing.expect(model.editing == null);
    model.selectFile(0);
    model.select(.{ .row = 1, .extend = false });
    model.comment();
    try std.testing.expectEqual(index, model.editing.?);
    try std.testing.expectEqualStrings("Check café and 界", model.comments[index].body.text());
    model.save();
    try std.testing.expect(!model.comments[index].draft);
    model.current().files[0].reviewed = true;
    model.current().files[1].reviewed = true;
    model.simulate();
    try std.testing.expectEqual(@as(usize, 0), model.revision);
    model.switchRevision();
    try std.testing.expect(!model.current().files[0].reviewed);
    try std.testing.expect(model.current().files[1].reviewed);
    try std.testing.expectEqualDeep(original, model.comments[index].anchor);
    model.comment();
    try std.testing.expect(model.editing.? != index);
    model.switchRevision();
    try std.testing.expectEqualDeep(original, model.comments[index].anchor);
}

test "review prototype empty comments and capacity do not discard existing drafts" {
    const model = try fixture();
    defer std.testing.allocator.destroy(model);
    model.comment();
    model.save();
    try std.testing.expect(model.editing != null);
    for (&model.comments) |*entry| {
        entry.alive = true;
        entry.draft = false;
    }
    model.editing = null;
    model.comment();
    try std.testing.expect(model.editing == null);
    try std.testing.expect(std.mem.indexOf(u8, model.status, "limit") != null);
}

test "review prototype visual selection stops at boundaries and survives direction changes" {
    const model = try fixture();
    defer std.testing.allocator.destroy(model);
    model.select(.{ .row = 1, .extend = false });
    model.toggleVisual();
    model.move(.{ .delta = 1, .extend = true });
    try std.testing.expectEqual(@as(usize, 1), model.tail);
    try std.testing.expectEqual(@as(usize, 2), model.head);
    model.move(.{ .delta = 1, .extend = true });
    try std.testing.expectEqual(@as(usize, 2), model.head);
    model.move(.{ .delta = -1, .extend = true });
    try std.testing.expectEqual(model.tail, model.head);
    model.move(.{ .delta = -1, .extend = true });
    try std.testing.expectEqual(@as(usize, 1), model.head);
    model.toggleVisual();
    try std.testing.expect(!model.visual);

    model.select(.{ .row = 2, .extend = false });
    model.toggleVisual();
    model.move(.{ .delta = -1, .extend = true });
    const location = model.anchor();
    model.comment();
    try std.testing.expect(!model.visual);
    try std.testing.expectEqualDeep(location, model.comments[model.editing.?].anchor);
    try std.testing.expectEqual(@as(usize, 1), location.first);
    try std.testing.expectEqual(@as(usize, 2), location.last);

    model.selectFile(0);
    model.toggleVisual();
    model.move(.{ .delta = 1, .extend = true });
    try std.testing.expect(model.anchor().before);
    try std.testing.expectEqual(@as(usize, 0), model.head);
    model.selectFile(1);
    try std.testing.expect(!model.visual);
    model.toggleVisual();
    model.simulate();
    model.switchRevision();
    try std.testing.expect(!model.visual);
}

test "review prototype reordered editions preserve paths reviewed state and original comment anchors" {
    const model = try fixture();
    defer std.testing.allocator.destroy(model);
    try model.revisions[1].load("Updated other.go\n@@ -0,0 +1 @@\n+package main\nAdded new.rs\n@@ -0,0 +1 @@\n+fn main() {}\nUpdated file.zig\n@@ -1 +1 @@\n-old\n+changed\n");
    try model.revisions[1].ensureReviewable();
    model.current().files[0].reviewed = true;
    model.current().files[1].reviewed = true;
    model.selectFile(1);
    model.comment();
    const comment_index = model.editing.?;
    const original = model.comments[comment_index].anchor;
    _ = model.comments[comment_index].body.replace(.{ 0, 0 }, "Keep the package name");

    model.simulate();
    model.switchRevision();
    try std.testing.expectEqual(@as(usize, 0), model.file);
    try std.testing.expectEqualStrings("other.go", model.current().files[model.file].path);
    try std.testing.expect(model.current().files[0].reviewed);
    try std.testing.expect(!model.current().files[1].reviewed);
    try std.testing.expect(!model.current().files[2].reviewed);
    try std.testing.expectEqual(model.current().files[model.file].first, model.head);
    try std.testing.expectEqualDeep(original, model.comments[comment_index].anchor);
    model.comment();
    try std.testing.expect(model.editing.? != comment_index);

    model.switchRevision();
    try std.testing.expectEqual(@as(usize, 1), model.file);
    model.comment();
    try std.testing.expectEqual(comment_index, model.editing.?);
    try std.testing.expectEqualStrings("Keep the package name", model.comments[comment_index].body.text());
    try std.testing.expectEqualDeep(original, model.comments[comment_index].anchor);
}

test "review prototype missing files select a valid fallback without reattaching comments" {
    const model = try fixture();
    defer std.testing.allocator.destroy(model);
    try model.revisions[1].load("Updated other.go\n@@ -0,0 +1 @@\n+package main\n");
    try model.revisions[1].ensureReviewable();
    model.comment();
    const comment_index = model.editing.?;
    const original = model.comments[comment_index].anchor;
    _ = model.comments[comment_index].body.replace(.{ 0, 0 }, "Review the removed file separately");

    model.simulate();
    model.switchRevision();
    try std.testing.expectEqual(@as(usize, 0), model.file);
    try std.testing.expectEqualStrings("other.go", model.current().files[model.file].path);
    try std.testing.expectEqual(@as(usize, 0), model.head);
    try std.testing.expectEqualDeep(original, model.comments[comment_index].anchor);

    model.switchRevision();
    try std.testing.expectEqual(@as(usize, 1), model.file);
    try std.testing.expectEqualStrings("other.go", model.current().files[model.file].path);
    try std.testing.expectEqual(model.current().files[model.file].first, model.head);
    try std.testing.expectEqualDeep(original, model.comments[comment_index].anchor);
    model.selectFile(0);
    model.comment();
    try std.testing.expectEqual(comment_index, model.editing.?);
}

test "review line motions count selectable rows and clamp to the current file" {
    const model = try fixture();
    defer std.testing.allocator.destroy(model);
    model.move(.{ .delta = 2, .extend = false });
    try std.testing.expectEqual(@as(usize, 2), model.head);
    model.move(.{ .delta = std.math.maxInt(i32), .extend = false });
    try std.testing.expectEqual(@as(usize, 4), model.head);
    try std.testing.expectEqual(@as(usize, 0), model.file);
    model.first();
    try std.testing.expectEqual(@as(usize, 0), model.head);
    model.last();
    try std.testing.expectEqual(@as(usize, 4), model.head);
    model.move(.{ .delta = std.math.minInt(i32), .extend = false });
    try std.testing.expectEqual(@as(usize, 0), model.head);
    model.move(.{ .delta = 0, .extend = false, .hunk = true });
    try std.testing.expectEqual(@as(usize, 0), model.head);

    model.selectFile(1);
    model.first();
    model.last();
    try std.testing.expectEqual(@as(usize, 1), model.file);
    try std.testing.expectEqual(@as(usize, 5), model.head);
}

test "review first last and large visual motions retain their hunk and side" {
    const model = try fixture();
    defer std.testing.allocator.destroy(model);
    model.select(.{ .row = 1, .extend = false });
    model.toggleVisual();
    model.last();
    try std.testing.expect(model.visual);
    try std.testing.expectEqual(@as(usize, 1), model.tail);
    try std.testing.expectEqual(@as(usize, 2), model.head);
    model.first();
    try std.testing.expectEqual(@as(usize, 1), model.head);
    model.move(.{ .delta = 20, .extend = true });
    try std.testing.expectEqual(@as(usize, 2), model.head);

    model.select(.{ .row = 3, .extend = false });
    model.toggleVisual();
    model.first();
    model.last();
    try std.testing.expectEqual(@as(usize, 3), model.head);
    try std.testing.expectEqual(@as(usize, 3), model.tail);
    try std.testing.expect(model.anchor().before);
}

const search_source = "Updated café.rs\n@@ -1,3 +1,4 @@\n-café old café\n+café new café\n context 界\n+界 café\n@@ -30 +30 @@\n-old café\n+new café\nUpdated other.go\n@@ -0,0 +1 @@\n+café other\n";

test "review literal UTF8 search visits occurrences in both directions and wraps within one file" {
    const model = try fixture();
    defer std.testing.allocator.destroy(model);
    try model.current().load(search_source);
    model.selectFile(0);
    try std.testing.expect(model.startSearch("café"));
    try std.testing.expectEqual(@as(usize, 0), model.head);
    try std.testing.expectEqual(@as(usize, 0), model.search.match.?.start);
    try std.testing.expectEqual(@as(usize, 5), model.search.match.?.end);
    try std.testing.expect(model.repeatSearch(.forward));
    try std.testing.expectEqual(@as(usize, 0), model.head);
    try std.testing.expectEqual(@as(usize, 10), model.search.match.?.start);
    try std.testing.expect(model.repeatSearch(.forward));
    try std.testing.expectEqual(@as(usize, 1), model.head);
    try std.testing.expectEqual(@as(usize, 0), model.search.match.?.start);
    try std.testing.expect(model.repeatSearch(.backward));
    try std.testing.expectEqual(@as(usize, 0), model.head);
    try std.testing.expectEqual(@as(usize, 10), model.search.match.?.start);
    try std.testing.expect(model.repeatSearch(.backward));
    try std.testing.expectEqual(@as(usize, 0), model.search.match.?.start);
    try std.testing.expect(model.repeatSearch(.backward));
    try std.testing.expectEqual(@as(usize, 5), model.head);
    try std.testing.expectEqual(@as(usize, 0), model.file);
    try std.testing.expect(model.repeatSearch(.forward));
    try std.testing.expectEqual(@as(usize, 0), model.head);

    try std.testing.expect(model.startSearch("界"));
    try std.testing.expectEqual(@as(usize, 2), model.head);
    const match = model.search.match.?;
    try std.testing.expectEqualStrings("界", model.current().rows[match.row].value.text[match.start..match.end]);
    try std.testing.expect(!model.startSearch("CAFÉ"));
    try std.testing.expectEqual(@as(usize, 2), model.head);
    try std.testing.expectEqualStrings("CAFÉ", model.search.query.text());
    try std.testing.expect(model.search.match == null);
}

test "review search follows visual boundaries and resets occurrence position after navigation" {
    const model = try fixture();
    defer std.testing.allocator.destroy(model);
    try model.current().load(search_source);
    model.selectFile(0);
    model.select(.{ .row = 1, .extend = false });
    model.toggleVisual();
    try std.testing.expect(model.startSearch("café"));
    try std.testing.expect(model.repeatSearch(.forward));
    try std.testing.expectEqual(@as(usize, 1), model.head);
    try std.testing.expect(model.repeatSearch(.forward));
    try std.testing.expectEqual(@as(usize, 3), model.head);
    try std.testing.expectEqual(@as(usize, 1), model.tail);
    try std.testing.expectEqual(@as(usize, 4), model.search.match.?.start);
    try std.testing.expect(model.repeatSearch(.forward));
    try std.testing.expectEqual(@as(usize, 1), model.head);
    try std.testing.expectEqual(@as(usize, 0), model.search.match.?.start);
    try std.testing.expect(model.visual);

    model.selectFile(1);
    try std.testing.expect(model.search.match == null);
    try std.testing.expect(model.repeatSearch(.forward));
    try std.testing.expectEqual(@as(usize, 6), model.head);
    try std.testing.expectEqual(@as(usize, 0), model.search.match.?.start);
    try std.testing.expect(model.repeatSearch(.backward));
    try std.testing.expectEqual(@as(usize, 6), model.head);
}

test "review search rejects oversized or invalid queries atomically and handles empty revisions" {
    const model = try fixture();
    defer std.testing.allocator.destroy(model);
    try std.testing.expect(model.startSearch("new"));
    const previous = model.search.match;
    try std.testing.expect(!model.startSearch(&[_]u8{'a'} ** (limits.search_bytes + 1)));
    try std.testing.expect(!model.startSearch("\xff"));
    try std.testing.expect(!model.startSearch("two\nlines"));
    try std.testing.expectEqualStrings("new", model.search.query.text());
    try std.testing.expectEqualDeep(previous, model.search.match);
    model.clearSearch();
    try std.testing.expect(!model.repeatSearch(.forward));
    try std.testing.expectEqual(@as(usize, 0), model.search.query.text().len);
    try model.current().load("");
    model.first();
    model.last();
    try std.testing.expect(!model.startSearch("new"));
}

const Search = struct {
    pub const Direction = enum { forward, backward };

    query: data.GenericField(limits.search_bytes) = .{},
    match: ?SearchMatch = null,

    /// Retains a bounded literal query; invalid input leaves the previous search intact.
    /// Example: `_ = search.setQuery("café");`
    pub fn setQuery(self: *Search, query: []const u8) bool {
        if (query.len > limits.search_bytes or !std.unicode.utf8ValidateSlice(query) or std.mem.indexOfAny(u8, query, "\x00\r\n") != null) {
            return false;
        }

        _ = self.query.replace(.{ 0, @intCast(self.query.len) }, query);
        self.match = null;
        return true;
    }
};
