const core = @import("telar-core");
const std = @import("std");

/// A fixed capacity field.
///
/// Fixed because the alternative is allocating on the keystroke path, and a
/// search box that runs out of room at 512 bytes has never been anybody's
/// problem. Input past the limit is dropped rather than truncated mid
/// character - a half written cluster is worse than a missing one.
pub fn Type(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        /// Where the cursor is, in bytes.
        head: usize = 0,
        /// Where the selection started. Equal to `head` when there is none.
        ///
        /// Kept as a separate offset rather than a start/end pair because the
        /// *direction* matters: shift-left from the middle of a selection has
        /// to shrink it from the side the user is dragging, and a normalised
        /// pair has already thrown that away.
        anchor: usize = 0,

        /// Leftmost visible byte, so the view does not jump while typing.
        scroll: usize = 0,

        pub fn init(initial: []const u8) Self {
            var f: Self = .{};
            f.setText(initial);
            return f;
        }

        pub fn setText(self: *Self, initial: []const u8) void {
            const take = @min(initial.len, capacity);
            @memcpy(self.bytes[0..take], initial[0..take]);
            self.len = take;
            self.head = take;
            self.anchor = take;
            self.scroll = 0;
        }

        pub fn text(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }

        pub fn hasSelection(self: *const Self) bool {
            return self.head != self.anchor;
        }

        pub fn selected(self: *const Self) []const u8 {
            return self.bytes[@min(self.head, self.anchor)..@max(self.head, self.anchor)];
        }

        pub fn clearSelection(self: *Self) void {
            self.anchor = self.head;
        }

        /// Rejects ranges inside UTF-8 scalars before changing selection.
        /// Example: `_ = field.selectRange(.{ 0, 4 });`
        pub fn selectRange(self: *Self, range: [2]u32) bool {
            if (!self.boundary(range[0]) or !self.boundary(range[1])) {
                return false;
            }

            const changed = self.anchor != range[0] or self.head != range[1];
            self.anchor = range[0];
            self.head = range[1];
            return changed;
        }

        /// Replaces one range atomically. Invalid UTF-8, offsets and capacity
        /// failure leave both text and selection untouched.
        /// Example: `_ = field.replace(.{ 0, 4 }, "name");`
        pub fn replace(self: *Self, range: [2]u32, bytes: []const u8) bool {
            const start: usize = range[0];
            const finish: usize = range[1];
            if (start > finish or !self.boundary(start) or !self.boundary(finish) or !std.unicode.utf8ValidateSlice(bytes)) {
                return false;
            }

            const remaining = self.len - (finish - start);
            if (bytes.len > capacity - remaining) {
                return false;
            }

            const changed = !std.mem.eql(
                u8,
                self.bytes[start..finish],
                bytes,
            ) or self.head != start + bytes.len or self.anchor != start + bytes.len;
            var copy: [capacity]u8 = undefined;
            @memcpy(copy[0..bytes.len], bytes);
            if (bytes.len > finish - start) {
                std.mem.copyBackwards(
                    u8,
                    self.bytes[start + bytes.len ..][0 .. self.len - finish],
                    self.bytes[finish..self.len],
                );
            } else {
                std.mem.copyForwards(
                    u8,
                    self.bytes[start + bytes.len ..][0 .. self.len - finish],
                    self.bytes[finish..self.len],
                );
            }

            @memcpy(self.bytes[start..][0..bytes.len], copy[0..bytes.len]);
            self.len = remaining + bytes.len;
            self.head = start + bytes.len;
            self.anchor = self.head;
            self.scroll = @min(self.scroll, self.head);
            return changed;
        }

        fn boundary(self: *const Self, at: usize) bool {
            return at <= self.len and (at == self.len or self.bytes[at] & 0xc0 != 0x80);
        }

        pub fn selectAll(self: *Self) void {
            self.anchor = 0;
            self.head = self.len;
        }

        // -------------------------------------------------------------------
        // Editing
        // -------------------------------------------------------------------

        /// Inserts `input` at the cursor, replacing any selection.
        ///
        /// One path for a keystroke and for a paste, because they are the same
        /// operation and splitting them is how the two drift apart.
        pub fn insert(self: *Self, input: []const u8) void {
            _ = self.replace(
                .{
                    @intCast(@min(self.head, self.anchor)),
                    @intCast(@max(self.head, self.anchor)),
                },
                input,
            );
        }

        /// Deletes the selection, or the cluster before the cursor.
        pub fn backspace(self: *Self) void {
            if (self.deleteSelection()) {
                return;
            }
            const from = self.clusterBefore(self.head) orelse return;
            self.remove(from, self.head);
            self.head = from;
            self.anchor = from;
        }

        /// Deletes the selection, or the cluster at the cursor.
        pub fn delete(self: *Self) void {
            if (self.deleteSelection()) {
                return;
            }
            const to = self.clusterAfter(self.head) orelse return;
            self.remove(self.head, to);
        }

        fn deleteSelection(self: *Self) bool {
            if (!self.hasSelection()) {
                return false;
            }
            const from = @min(self.head, self.anchor);
            const to = @max(self.head, self.anchor);
            self.remove(from, to);
            self.head = from;
            self.anchor = from;
            return true;
        }

        fn remove(self: *Self, from: usize, to: usize) void {
            const tail = self.len - to;
            std.mem.copyForwards(
                u8,
                self.bytes[from..][0..tail],
                self.bytes[to..][0..tail],
            );
            self.len -= to - from;
            if (self.scroll > self.len) {
                self.scroll = 0;
            }
        }

        // -------------------------------------------------------------------
        // Movement
        // -------------------------------------------------------------------

        /// `extend` is whether shift was held: the anchor stays put and the
        /// selection grows, rather than collapsing to the new position.
        pub fn moveLeft(self: *Self, extend: bool) void {
            // Without shift, a left arrow on a selection collapses to its left
            // edge rather than moving from the cursor. Every editor does this
            // and it is the one movement case people notice when it is wrong.
            if (!extend and self.hasSelection()) {
                self.head = @min(self.head, self.anchor);
                self.anchor = self.head;
                return;
            }
            if (self.clusterBefore(self.head)) |from| {
                self.head = from;
            }
            if (!extend) {
                self.anchor = self.head;
            }
        }

        pub fn moveRight(self: *Self, extend: bool) void {
            if (!extend and self.hasSelection()) {
                self.head = @max(self.head, self.anchor);
                self.anchor = self.head;
                return;
            }
            if (self.clusterAfter(self.head)) |to| {
                self.head = to;
            }
            if (!extend) {
                self.anchor = self.head;
            }
        }

        pub fn home(self: *Self, extend: bool) void {
            self.head = 0;
            if (!extend) {
                self.anchor = 0;
            }
        }

        pub fn end(self: *Self, extend: bool) void {
            self.head = self.len;
            if (!extend) {
                self.anchor = self.len;
            }
        }

        /// Word movement, where a word is a run of non-space.
        ///
        /// Not Unicode word segmentation: this is what Ctrl+arrow does in a
        /// shell prompt, and matching the surrounding tools beats matching the
        /// standard when the two disagree.
        pub fn moveWordLeft(self: *Self, extend: bool) void {
            var at = self.head;
            while (at > 0 and isSpace(self.bytes[at - 1])) at -= 1;
            while (at > 0 and !isSpace(self.bytes[at - 1])) at -= 1;
            self.head = at;
            if (!extend) {
                self.anchor = at;
            }
        }

        pub fn moveWordRight(self: *Self, extend: bool) void {
            var at = self.head;
            while (at < self.len and isSpace(self.bytes[at])) at += 1;
            while (at < self.len and !isSpace(self.bytes[at])) at += 1;
            self.head = at;
            if (!extend) {
                self.anchor = at;
            }
        }

        fn isSpace(byte: u8) bool {
            return byte == ' ' or byte == '\t';
        }

        /// The byte offset of the cluster boundary before `at`.
        ///
        /// Segmentation only runs forwards, so finding the previous boundary
        /// means walking from the start. That is O(n) per left arrow, which for
        /// a field measured in tens of characters is free - and the alternative,
        /// guessing backwards from the byte pattern, is how a backspace ends up
        /// splitting a cluster it cannot see the start of.
        fn clusterBefore(self: *const Self, at: usize) ?usize {
            if (at == 0) {
                return null;
            }
            var it: core.GraphemeIterator = .{
                .bytes = self.text(),
            };
            var previous: usize = 0;
            while (it.next()) |_| {
                if (it.index >= at) {
                    return previous;
                }
                previous = it.index;
            }
            return previous;
        }

        fn clusterAfter(self: *const Self, at: usize) ?usize {
            if (at >= self.len) {
                return null;
            }
            var it: core.GraphemeIterator = .{
                .bytes = self.bytes[at..self.len],
            };
            const cluster = it.next() orelse return null;
            return at + cluster.bytes.len;
        }

        // -------------------------------------------------------------------
        // Drawing
        // -------------------------------------------------------------------

        /// What to draw, and where the cursor and selection land in it.
        pub const View = struct {
            /// The visible slice of the text.
            text: []const u8,
            /// Column within `text` where the cursor sits.
            cursor: u16,
            /// Columns the selection covers, if any, within `text`.
            selection: ?[2]u16 = null,
            /// There is text scrolled off to the left or the right.
            clipped_left: bool = false,
            clipped_right: bool = false,
        };

        /// Fits the field into `width` columns, scrolling to keep the cursor
        /// visible.
        ///
        /// The scroll offset is remembered rather than recomputed, so typing in
        /// the middle of a long value does not make the text jump around under
        /// the user. It only moves when the cursor would otherwise leave.
        pub fn view(self: *Self, width: u16) View {
            if (width == 0) {
                return .{
                    .text = "",
                    .cursor = 0,
                };
            }

            // The cursor left the window on the left.
            if (self.head < self.scroll) {
                self.scroll = self.startOfLine(self.head, width);
            }
            // Or on the right: scroll until it fits, by clusters so the left
            // edge never lands inside one.
            while (core.measure(self.bytes[self.scroll..self.head]) >= width) {
                const next = self.clusterAfter(self.scroll) orelse break;
                self.scroll = next;
            }

            var end_at = self.scroll;
            var used: u16 = 0;
            while (end_at < self.len) {
                const next = self.clusterAfter(end_at) orelse break;
                const cluster_width = core.measure(self.bytes[end_at..next]);
                if (used + cluster_width > width) {
                    break;
                }
                used += cluster_width;
                end_at = next;
            }

            const visible = self.bytes[self.scroll..end_at];
            const from = @min(self.head, self.anchor);
            const to = @max(self.head, self.anchor);
            return .{
                .text = visible,
                .cursor = core.measure(self.bytes[self.scroll..self.head]),
                .selection = if (self.hasSelection()) .{
                    core.measure(self.bytes[self.scroll..@max(from, self.scroll)]),
                    core.measure(self.bytes[self.scroll..@min(@max(to, self.scroll), end_at)]),
                } else null,
                .clipped_left = self.scroll > 0,
                .clipped_right = end_at < self.len,
            };
        }

        /// Walks back from `at` until roughly `width` columns fit before it,
        /// landing on a cluster boundary.
        fn startOfLine(self: *const Self, at: usize, width: u16) usize {
            var start = at;
            while (start > 0) {
                const previous = self.clusterBefore(start) orelse break;
                if (core.measure(self.bytes[previous..at]) > width -| 1) {
                    break;
                }
                start = previous;
            }
            return start;
        }
    };
}
