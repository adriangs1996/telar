const PhysicalType = @import("Physical.zig");

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
            identity: PhysicalType,
            owner: Owner,
        };

        /// Acquires or replaces one identity. False means the bounded table was
        /// full and no ownership was recorded.
        ///
        /// ```zig
        /// if (!leases.acquire(identity, owner)) dropInput();
        /// ```
        pub fn acquire(leases: *Self, identity: PhysicalType, assigned_owner: Owner) bool {
            if (leases.indexOf(identity)) |index| {
                leases.entries[index].owner = assigned_owner;

                return true;
            }

            if (leases.len == leases.entries.len) {
                leases.overflows +%= 1;

                return false;
            }

            leases.entries[leases.len] = .{ .identity = identity, .owner = assigned_owner };
            leases.len += 1;

            return true;
        }

        /// Returns the current owner without ending the physical lifecycle.
        ///
        /// ```zig
        /// const owner = leases.owner(identity) orelse return;
        /// ```
        pub fn owner(leases: *const Self, identity: PhysicalType) ?Owner {
            const index = leases.indexOf(identity) orelse return null;

            return leases.entries[index].owner;
        }

        /// Ends one physical lifecycle and returns its final owner.
        ///
        /// ```zig
        /// const owner = leases.release(identity) orelse return;
        /// ```
        pub fn release(leases: *Self, identity: PhysicalType) ?Owner {
            const index = leases.indexOf(identity) orelse return null;
            const owner_value = leases.entries[index].owner;
            leases.len -= 1;
            if (index != leases.len) {
                leases.entries[index] = leases.entries[leases.len];
            }

            return owner_value;
        }

        /// Removes every active lease while retaining the saturation counter.
        ///
        /// ```zig
        /// leases.clear();
        /// ```
        pub fn clear(leases: *Self) void {
            leases.len = 0;
        }

        /// Returns the number of active physical lifecycles.
        ///
        /// ```zig
        /// const pressed = leases.count();
        /// ```
        pub fn count(leases: *const Self) usize {
            return leases.len;
        }

        /// Returns how many new presses were rejected because the table was
        /// full.
        ///
        /// ```zig
        /// const dropped = leases.overflowCount();
        /// ```
        pub fn overflowCount(leases: *const Self) u64 {
            return leases.overflows;
        }

        fn indexOf(leases: *const Self, identity: PhysicalType) ?usize {
            for (leases.entries[0..leases.len], 0..) |entry, index| {
                if (entry.identity.eql(identity)) {
                    return index;
                }
            }

            return null;
        }
    };
}
