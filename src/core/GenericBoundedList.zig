const agent_manifest = @import("agent_manifest.zig");

/// Fixed-capacity list of short byte strings.
pub fn Type(comptime capacity: usize, comptime entry_bytes: usize) type {
    return struct {
        const Self = @This();

        pub const max_entries = capacity;

        items: [capacity][entry_bytes]u8 = undefined,
        lens: [capacity]u8 = undefined,
        count: u8 = 0,

        pub fn append(self: *Self, text: []const u8) agent_manifest.ListError!void {
            if (text.len == 0) {
                return error.EmptyEntry;
            }
            if (text.len > entry_bytes) {
                return error.EntryTooLong;
            }
            if (self.count == capacity) {
                return error.TooManyEntries;
            }
            @memcpy(self.items[self.count][0..text.len], text);
            self.lens[self.count] = @intCast(text.len);
            self.count += 1;
        }

        pub fn get(self: *const Self, index: usize) []const u8 {
            return self.items[index][0..self.lens[index]];
        }

        /// Reports whether any entry occurs in `haystack`, ASCII
        /// case-insensitively.
        pub fn matches(self: *const Self, haystack: []const u8) bool {
            for (0..self.count) |index| {
                if (agent_manifest.containsAsciiInsensitive(haystack, self.get(index))) {
                    return true;
                }
            }
            return false;
        }
    };
}
