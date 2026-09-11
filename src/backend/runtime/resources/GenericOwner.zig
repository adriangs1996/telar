pub fn Type(comptime Capability: type, comptime destroyCapability: *const fn (*Capability) void) type {
    return struct {
        const Self = @This();

        capability: ?*Capability,

        pub fn init(capability: ?*Capability) Self {
            return .{ .capability = capability };
        }

        pub fn schedule(owner: *Self, scheduler: anytype) !void {
            const capability = owner.capability orelse return;
            return scheduler.schedule(capability);
        }

        pub fn deinit(owner: *Self) void {
            const capability = owner.capability orelse return;
            owner.capability = null;
            destroyCapability(capability);
        }
    };
}
