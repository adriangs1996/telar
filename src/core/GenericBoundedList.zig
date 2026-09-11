const agent_manifest = @import("agent_manifest.zig");

/// Fixed-capacity list of short byte strings.
pub fn Type(comptime capacity: usize, comptime entry_bytes: usize) type {
    return struct {
        const Self = @This();

        pub const max_entries = capacity;

        items: [capacity][entry_bytes]u8 = undefined,
        lens: [capacity]u8 = undefined,
        count: u8 = 0,

        pub fn append(list: *Self, text: []const u8) agent_manifest.ListError!void {
            if (text.len == 0) {
                return error.EmptyEntry;
            }
            if (text.len > entry_bytes) {
                return error.EntryTooLong;
            }
            if (list.count == capacity) {
                return error.TooManyEntries;
            }
            @memcpy(list.items[list.count][0..text.len], text);
            list.lens[list.count] = @intCast(text.len);
            list.count += 1;
        }

        pub fn get(list: *const Self, index: usize) []const u8 {
            return list.items[index][0..list.lens[index]];
        }

        /// Reports whether any entry occurs in `haystack`, ASCII
        /// case-insensitively.
        pub fn matches(list: *const Self, haystack: []const u8) bool {
            for (0..list.count) |index| {
                if (agent_manifest.containsAsciiInsensitive(haystack, list.get(index))) {
                    return true;
                }
            }
            return false;
        }
    };
}
