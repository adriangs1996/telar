const std = @import("std");
const ui = @import("telar-core").ui;
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

        pub fn setText(f: *Self, initial: []const u8) void {
            const take = @min(initial.len, capacity);
            @memcpy(f.bytes[0..take], initial[0..take]);
            f.len = take;
            f.head = take;
            f.anchor = take;
            f.scroll = 0;
        }

        pub fn text(f: *const Self) []const u8 {
            return f.bytes[0..f.len];
        }

        pub fn hasSelection(f: *const Self) bool {
            return f.head != f.anchor;
        }

        pub fn selected(f: *const Self) []const u8 {
            return f.bytes[@min(f.head, f.anchor)..@max(f.head, f.anchor)];
        }

        pub fn clearSelection(f: *Self) void {
            f.anchor = f.head;
        }

        pub fn selectAll(f: *Self) void {
            f.anchor = 0;
            f.head = f.len;
        }

        // -------------------------------------------------------------------
        // Editing
        // -------------------------------------------------------------------

        /// Inserts `input` at the cursor, replacing any selection.
        ///
        /// One path for a keystroke and for a paste, because they are the same
        /// operation and splitting them is how the two drift apart.
        pub fn insert(f: *Self, input: []const u8) void {
            _ = f.deleteSelection();
            if (f.len + input.len > capacity) {
                return;
            }

            const tail = f.len - f.head;
            std.mem.copyBackwards(u8, f.bytes[f.head + input.len ..][0..tail], f.bytes[f.head..][0..tail]);
            @memcpy(f.bytes[f.head..][0..input.len], input);
            f.len += input.len;
            f.head += input.len;
            f.anchor = f.head;
        }

        /// Deletes the selection, or the cluster before the cursor.
        pub fn backspace(f: *Self) void {
            if (f.deleteSelection()) {
                return;
            }
            const from = f.clusterBefore(f.head) orelse return;
            f.remove(from, f.head);
            f.head = from;
            f.anchor = from;
        }

        /// Deletes the selection, or the cluster at the cursor.
        pub fn delete(f: *Self) void {
            if (f.deleteSelection()) {
                return;
            }
            const to = f.clusterAfter(f.head) orelse return;
            f.remove(f.head, to);
        }

        fn deleteSelection(f: *Self) bool {
            if (!f.hasSelection()) {
                return false;
            }
            const from = @min(f.head, f.anchor);
            const to = @max(f.head, f.anchor);
            f.remove(from, to);
            f.head = from;
            f.anchor = from;
            return true;
        }

        fn remove(f: *Self, from: usize, to: usize) void {
            const tail = f.len - to;
            std.mem.copyForwards(u8, f.bytes[from..][0..tail], f.bytes[to..][0..tail]);
            f.len -= to - from;
            if (f.scroll > f.len) {
                f.scroll = 0;
            }
        }

        // -------------------------------------------------------------------
        // Movement
        // -------------------------------------------------------------------

        /// `extend` is whether shift was held: the anchor stays put and the
        /// selection grows, rather than collapsing to the new position.
        pub fn moveLeft(f: *Self, extend: bool) void {
            // Without shift, a left arrow on a selection collapses to its left
            // edge rather than moving from the cursor. Every editor does this
            // and it is the one movement case people notice when it is wrong.
            if (!extend and f.hasSelection()) {
                f.head = @min(f.head, f.anchor);
                f.anchor = f.head;
                return;
            }
            if (f.clusterBefore(f.head)) |from| {
                f.head = from;
            }
            if (!extend) {
                f.anchor = f.head;
            }
        }

        pub fn moveRight(f: *Self, extend: bool) void {
            if (!extend and f.hasSelection()) {
                f.head = @max(f.head, f.anchor);
                f.anchor = f.head;
                return;
            }
            if (f.clusterAfter(f.head)) |to| {
                f.head = to;
            }
            if (!extend) {
                f.anchor = f.head;
            }
        }

        pub fn home(f: *Self, extend: bool) void {
            f.head = 0;
            if (!extend) {
                f.anchor = 0;
            }
        }

        pub fn end(f: *Self, extend: bool) void {
            f.head = f.len;
            if (!extend) {
                f.anchor = f.len;
            }
        }

        /// Word movement, where a word is a run of non-space.
        ///
        /// Not Unicode word segmentation: this is what Ctrl+arrow does in a
        /// shell prompt, and matching the surrounding tools beats matching the
        /// standard when the two disagree.
        pub fn moveWordLeft(f: *Self, extend: bool) void {
            var at = f.head;
            while (at > 0 and isSpace(f.bytes[at - 1])) at -= 1;
            while (at > 0 and !isSpace(f.bytes[at - 1])) at -= 1;
            f.head = at;
            if (!extend) {
                f.anchor = at;
            }
        }

        pub fn moveWordRight(f: *Self, extend: bool) void {
            var at = f.head;
            while (at < f.len and isSpace(f.bytes[at])) at += 1;
            while (at < f.len and !isSpace(f.bytes[at])) at += 1;
            f.head = at;
            if (!extend) {
                f.anchor = at;
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
        fn clusterBefore(f: *const Self, at: usize) ?usize {
            if (at == 0) {
                return null;
            }
            var it: ui.GraphemeIterator = .{ .bytes = f.text() };
            var previous: usize = 0;
            while (it.next()) |_| {
                if (it.index >= at) {
                    return previous;
                }
                previous = it.index;
            }
            return previous;
        }

        fn clusterAfter(f: *const Self, at: usize) ?usize {
            if (at >= f.len) {
                return null;
            }
            var it: ui.GraphemeIterator = .{ .bytes = f.bytes[at..f.len] };
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
        pub fn view(f: *Self, width: u16) View {
            if (width == 0) {
                return .{ .text = "", .cursor = 0 };
            }

            // The cursor left the window on the left.
            if (f.head < f.scroll) {
                f.scroll = f.startOfLine(f.head, width);
            }
            // Or on the right: scroll until it fits, by clusters so the left
            // edge never lands inside one.
            while (ui.measure(f.bytes[f.scroll..f.head]) >= width) {
                const next = f.clusterAfter(f.scroll) orelse break;
                f.scroll = next;
            }

            var end_at = f.scroll;
            var used: u16 = 0;
            while (end_at < f.len) {
                const next = f.clusterAfter(end_at) orelse break;
                const cluster_width = ui.measure(f.bytes[end_at..next]);
                if (used + cluster_width > width) {
                    break;
                }
                used += cluster_width;
                end_at = next;
            }

            const visible = f.bytes[f.scroll..end_at];
            const from = @min(f.head, f.anchor);
            const to = @max(f.head, f.anchor);
            return .{
                .text = visible,
                .cursor = ui.measure(f.bytes[f.scroll..f.head]),
                .selection = if (f.hasSelection()) .{
                    ui.measure(f.bytes[f.scroll..@max(from, f.scroll)]),
                    ui.measure(f.bytes[f.scroll..@min(@max(to, f.scroll), end_at)]),
                } else null,
                .clipped_left = f.scroll > 0,
                .clipped_right = end_at < f.len,
            };
        }

        /// Walks back from `at` until roughly `width` columns fit before it,
        /// landing on a cluster boundary.
        fn startOfLine(f: *const Self, at: usize, width: u16) usize {
            var start = at;
            while (start > 0) {
                const previous = f.clusterBefore(start) orelse break;
                if (ui.measure(f.bytes[previous..at]) > width -| 1) {
                    break;
                }
                start = previous;
            }
            return start;
        }
    };
}
