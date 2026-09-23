const std = @import("std");
/// Cross-thread lock shared by the runtime thread and pane actors. A parking
/// pthread mutex rather than a spin loop: a descheduled holder must not make
/// the other side burn a core, and the media-allocator call sites have no
/// `Io` for an `Io.Mutex`.
const ParkingMutex = @This();

inner: std.c.pthread_mutex_t = .{},

pub fn lock(self: *ParkingMutex) void {
    const rc = std.c.pthread_mutex_lock(&self.inner);
    std.debug.assert(rc == .SUCCESS);
}

pub fn unlock(self: *ParkingMutex) void {
    const rc = std.c.pthread_mutex_unlock(&self.inner);
    std.debug.assert(rc == .SUCCESS);
}
