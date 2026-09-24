const Physical = @import("Physical.zig");

/// Stores at most `capacity` simultaneously pressed physical keys.
///
/// A second press for the same identity replaces the stale owner. This recovers
/// from a terminal or client transition that lost the previous release.
pub fn Type(comptime Owner: type, comptime capacity: usize) type {
    if (capacity == 0) {
        @compileError("physical key lease capacity must be non-zero");
    }

    return struct {
        entries: [capacity]Entry = undefined,
        len: usize = 0,
        overflows: u64 = 0,

        const Self = @This();

        const Entry = struct {
            identity: Physical,
            owner: Owner,
        };

        /// Acquires or replaces one identity. False means the bounded table was
        /// full and no ownership was recorded.
        ///
        /// ```zig
        /// if (!leases.acquire(identity, owner)) dropInput();
        /// ```
        pub fn acquire(self: *Self, identity: Physical, assigned_owner: Owner) bool {
            if (self.indexOf(identity)) |index| {
                self.entries[index].owner = assigned_owner;

                return true;
            }

            if (self.len == self.entries.len) {
                self.overflows +%= 1;

                return false;
            }

            self.entries[self.len] = .{
                .identity = identity,
                .owner = assigned_owner,
            };
            self.len += 1;

            return true;
        }

        /// Returns the current owner without ending the physical lifecycle.
        ///
        /// ```zig
        /// const owner = leases.owner(identity) orelse return;
        /// ```
        pub fn owner(self: *const Self, identity: Physical) ?Owner {
            const index = self.indexOf(identity) orelse return null;

            return self.entries[index].owner;
        }

        /// Ends one physical lifecycle and returns its final owner.
        ///
        /// ```zig
        /// const owner = leases.release(identity) orelse return;
        /// ```
        pub fn release(self: *Self, identity: Physical) ?Owner {
            const index = self.indexOf(identity) orelse return null;
            const owner_value = self.entries[index].owner;
            self.len -= 1;
            if (index != self.len) {
                self.entries[index] = self.entries[self.len];
            }

            return owner_value;
        }

        /// Removes every active lease while retaining the saturation counter.
        ///
        /// ```zig
        /// leases.clear();
        /// ```
        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        /// Returns the number of active physical lifecycles.
        ///
        /// ```zig
        /// const pressed = leases.count();
        /// ```
        pub fn count(self: *const Self) usize {
            return self.len;
        }

        /// Returns how many new presses were rejected because the table was
        /// full.
        ///
        /// ```zig
        /// const dropped = leases.overflowCount();
        /// ```
        pub fn overflowCount(self: *const Self) u64 {
            return self.overflows;
        }

        fn indexOf(self: *const Self, identity: Physical) ?usize {
            for (self.entries[0..self.len], 0..) |entry, index| {
                if (entry.identity.eql(identity)) {
                    return index;
                }
            }

            return null;
        }
    };
}
