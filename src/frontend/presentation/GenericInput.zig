const Event = @import("screen_support.zig").Event;
const source_namespace = @import("screen_support.zig");
const std = @import("std");
/// Bytes in, events out, losing none.
///
/// A terminal hands over arbitrary fragments: half an escape sequence, three
/// events in one read, a multi byte character split across two. The obvious
/// buffer for that has a bug which only shows up under load, and it is the one
/// this type exists to make impossible:
///
///     const take = @min(pending.len - len, n);   // <- silently drops the rest
///
/// When the buffer still holds unparsed bytes and a read arrives that does not
/// fit in what is left, the excess vanishes. Nothing reports it. The symptom is
/// a keystroke that does nothing, and only while something else is producing
/// input - a mouse being moved, an autorepeating key - so it reads as the
/// terminal being flaky rather than as a program losing bytes.
///
/// Here `push` says how much it took and the caller feeds the rest after
/// draining, so no byte is ever passed over.
pub fn Type(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        pending: [capacity]u8 = undefined,
        len: usize = 0,
        /// Bytes discarded to recover from an unparseable buffer. Not expected
        /// to move; worth a counter because "input is being dropped" is a fact
        /// nobody should have to infer from behaviour.
        dropped: usize = 0,

        /// Absorbs what fits, returning how many bytes it took.
        ///
        /// Zero means the buffer is full and the caller has to drain it with
        /// `next` before offering more. It never means the bytes are gone.
        pub fn push(in: *Self, chunk: []const u8) usize {
            const take = @min(capacity - in.len, chunk.len);
            @memcpy(in.pending[in.len..][0..take], chunk[0..take]);
            in.len += take;
            return take;
        }

        /// The next complete event, or null if more bytes are needed.
        pub fn next(in: *Self) ?Event {
            while (in.len > 0) {
                const parsed = source_namespace.parse(in.pending[0..in.len]) orelse return null;
                if (parsed.len == 0) {
                    // Needs more bytes - unless there is no more room for them,
                    // in which case the buffer holds something that will never
                    // parse and waiting is a deadlock. Dropping the oldest byte
                    // is the only move that guarantees progress.
                    if (in.len < capacity) {
                        return null;
                    }
                    in.discard(1);
                    in.dropped += 1;
                    continue;
                }
                in.discard(parsed.len);
                if (parsed.event == .incomplete) {
                    continue;
                }
                return parsed.event;
            }
            return null;
        }

        fn discard(in: *Self, count: usize) void {
            std.mem.copyForwards(u8, in.pending[0 .. in.len - count], in.pending[count..in.len]);
            in.len -= count;
        }
    };
}
