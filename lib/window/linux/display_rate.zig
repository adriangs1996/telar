const std = @import("std");
const native = @import("../native.zig");
const c = native.c;
const ns_per_millihertz_period: u64 = std.time.ns_per_s * 1000;

fn from(data: ?*anyopaque) *c.telar_display_rate {
    return @ptrCast(@alignCast(data.?));
}

fn changed(data: ?*anyopaque) callconv(.c) void {
    from(data).changed = true;
}

fn enter(data: ?*anyopaque, _: ?*c.wl_surface, output: ?*c.wl_output) callconv(.c) void {
    const self = from(data);
    if (c.telar_outputs_enter(self.outputs, &self.set, output)) {
        self.changed = true;
    }
}

fn leave(data: ?*anyopaque, _: ?*c.wl_surface, output: ?*c.wl_output) callconv(.c) void {
    const self = from(data);
    if (c.telar_outputs_leave(self.outputs, &self.set, output)) {
        self.changed = true;
    }
}

fn preferredScale(_: ?*anyopaque, _: ?*c.wl_surface, _: i32) callconv(.c) void {}
fn preferredTransform(_: ?*anyopaque, _: ?*c.wl_surface, _: u32) callconv(.c) void {}
const listener: c.wl_surface_listener = value: {
    var result = std.mem.zeroes(c.wl_surface_listener);
    result.enter = enter;
    result.leave = leave;
    if (@hasField(c.wl_surface_listener, "preferred_buffer_scale")) {
        result.preferred_buffer_scale = preferredScale;
        result.preferred_buffer_transform = preferredTransform;
    }
    break :value result;
};

/// Attach before the first surface commit. Output changes mark this follower;
/// the window reads the newest period directly after dispatching Wayland events.
pub fn attach(self: *c.telar_display_rate, outputs: *c.telar_outputs, surface: ?*c.wl_surface) callconv(.c) bool {
    if (surface == null) {
        return false;
    }
    self.outputs = outputs;
    self.set = .{ .entered = 0, .changed = changed, .data = self };
    if (!c.telar_outputs_watch(outputs, &self.set)) {
        self.outputs = null;
        return false;
    }
    if (c.wl_surface_add_listener(surface, &listener, self) != 0) {
        deinit(self);
        return false;
    }
    return true;
}

/// A spanning window follows the fastest entered output. Unknown refresh rates
/// leave the previous period intact; unchanged periods do not produce an event.
pub fn take(self: *c.telar_display_rate) ?u64 {
    if (!self.changed or self.outputs == null) {
        return null;
    }
    self.changed = false;
    var fastest: u32 = 0;
    for (self.outputs.*.slots, 0..) |output, index| {
        if (self.set.entered & (@as(u32, 1) << @intCast(index)) != 0) {
            fastest = @max(fastest, output.refresh_mhz);
        }
    }
    if (fastest == 0) {
        return null;
    }
    const interval = ns_per_millihertz_period / fastest;
    if (interval == self.reported_ns) {
        return null;
    }
    self.reported_ns = interval;
    return interval;
}

pub fn deinit(self: *c.telar_display_rate) callconv(.c) void {
    if (self.outputs != null) {
        c.telar_outputs_unwatch(self.outputs, &self.set);
        self.outputs = null;
    }
}
