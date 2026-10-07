const std = @import("std");
const native = @import("../native.zig");
const c = native.c;
const HostState = @import("../HostState.zig");
const Pointer = @This();
const button_count = 3;
const wheel_step = 10;
const wheel_units = 120;
const Kind = enum(u32) { press = 1, release = 2, drag = 3, motion = 6, leave = 7 };
const ScrollPhase = enum(u32) { none, began, changed, ended, cancelled };

host: *HostState,
handle: ?*c.wl_pointer = null,
cursor: *c.telar_cursor,
entered: bool = false,
x: f64 = 0,
y: f64 = 0,
axes: [2]f64 = @splat(0),
discrete: [2]f64 = @splat(0),
value120: [2]f64 = @splat(0),
source: u32 = c.WL_POINTER_AXIS_SOURCE_WHEEL,
seen: u32 = 0,
stopped: u32 = 0,
active: u32 = 0,
time: u32 = 0,
mods: u32 = 0,
buttons: u32 = 0,

pub fn init(host: *HostState, outputs: *c.telar_outputs) !Pointer {
    return .{ .host = host, .cursor = c.telar_cursor_create(outputs) orelse return error.CursorInitializationFailed };
}

pub fn deinit(self: *Pointer) void {
    self.attach(null, false);
    c.telar_cursor_destroy(self.cursor);
}

/// Seat capability events attach or release the protocol object. Losing the
/// pointer ends accepted gestures before its listener storage can disappear.
pub fn attach(self: *Pointer, seat: ?*c.wl_seat, available: bool) void {
    if (available and self.handle == null) {
        self.handle = c.wl_seat_get_pointer(seat);
        if (self.handle) |handle| {
            c.telar_cursor_attach(self.cursor, handle);
            _ = c.wl_pointer_add_listener(handle, &listener, self);
        }
    } else if (!available) {
        if (self.handle) |handle| {
            leave(self, handle, 0, null);
            c.telar_cursor_attach(self.cursor, null);
            if (c.wl_pointer_get_version(handle) >= c.WL_POINTER_RELEASE_SINCE_VERSION) {
                c.wl_pointer_release(handle);
            } else {
                c.wl_pointer_destroy(handle);
            }
            self.handle = null;
        }
    }
}

pub fn modifiers(self: *Pointer, mods: u32) void {
    if (self.mods != mods) {
        self.mods = mods;
        if (self.entered) {
            _ = self.emit(.motion, 0);
        }
    }
}

fn emit(self: *Pointer, kind: Kind, button_id: u32) bool {
    return self.host.receive(std.mem.zeroInit(c.telar_gui_input, .{
        .kind = 6,
        .code = @intFromEnum(kind),
        .phase = 1,
        .button = button_id,
        .mods = self.mods,
        .x = self.x,
        .y = self.y,
    }));
}

fn scroll(self: *Pointer, delta: [2]f64, precise: bool, phase: ScrollPhase) void {
    _ = self.host.receive(std.mem.zeroInit(c.telar_gui_input, .{
        .kind = 8,
        .x = self.x,
        .y = self.y,
        .mods = self.mods,
        .delta_x = delta[c.WL_POINTER_AXIS_HORIZONTAL_SCROLL],
        .delta_y = delta[c.WL_POINTER_AXIS_VERTICAL_SCROLL],
        .precise = @intFromBool(precise),
        .scroll_phase = @intFromEnum(phase),
        .scroll_kinetic = @intFromBool(self.source == c.WL_POINTER_AXIS_SOURCE_FINGER),
        .scroll_time_ms = self.time,
    }));
}

fn from(data: ?*anyopaque) *Pointer {
    return @ptrCast(@alignCast(data.?));
}

/// libwayland invokes this listener when pointer focus enters the surface. The
/// serial authorizes cursor changes and is independent of keyboard/button serials.
// Wayland fixes this listener signature; its protocol arguments cannot be grouped.
// codestyle: allow(maximum-parameter-count)
fn enter(data: ?*anyopaque, _: ?*c.wl_pointer, serial: u32, _: ?*c.wl_surface, x: c.wl_fixed_t, y: c.wl_fixed_t) callconv(.c) void {
    const self = from(data);
    self.entered = true;
    c.telar_cursor_enter(self.cursor, serial);
    self.x = c.wl_fixed_to_double(x);
    self.y = c.wl_fixed_to_double(y);
    _ = self.emit(.motion, 0);
}

/// Focus/capability loss cancels scrolling and releases held buttons; the owning
/// window queues these before the leave event, including when no redraw is due.
fn leave(data: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: ?*c.wl_surface) callconv(.c) void {
    const self = from(data);
    for (0..button_count) |index| {
        if (self.buttons & (@as(u32, 1) << @intCast(index)) != 0) {
            _ = self.emit(.release, @intCast(index));
        }
    }
    self.buttons = 0;
    if (self.active != 0) {
        self.scroll(@splat(0), true, .cancelled);
    }
    self.axes = @splat(0);
    self.discrete = @splat(0);
    self.value120 = @splat(0);
    self.seen = 0;
    self.stopped = 0;
    self.active = 0;
    self.source = c.WL_POINTER_AXIS_SOURCE_WHEEL;
    if (self.entered) {
        _ = self.emit(.leave, 0);
    }
    self.entered = false;
    c.telar_cursor_leave(self.cursor);
}

fn motion(data: ?*anyopaque, _: ?*c.wl_pointer, _: u32, x: c.wl_fixed_t, y: c.wl_fixed_t) callconv(.c) void {
    const self = from(data);
    self.x = c.wl_fixed_to_double(x);
    self.y = c.wl_fixed_to_double(y);
    if (self.buttons == 0) {
        _ = self.emit(.motion, 0);
        return;
    }
    for (0..button_count) |index| {
        if (self.buttons & (@as(u32, 1) << @intCast(index)) != 0) {
            _ = self.emit(.drag, @intCast(index));
        }
    }
}

// Wayland fixes this listener signature; its protocol arguments cannot be grouped.
// codestyle: allow(maximum-parameter-count)
fn button(data: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: u32, code: u32, state: u32) callconv(.c) void {
    const self = from(data);
    const id: u5 = switch (code) {
        c.BTN_LEFT => 0,
        c.BTN_MIDDLE => 1,
        c.BTN_RIGHT => 2,
        else => return,
    };
    const pressed = state == c.WL_POINTER_BUTTON_STATE_PRESSED;
    if (self.emit(if (pressed) .press else .release, id)) {
        if (pressed) {
            self.buttons |= @as(u32, 1) << id;
        } else {
            self.buttons &= ~(@as(u32, 1) << id);
        }
    }
}

/// Axis callbacks accumulate one protocol frame; this listener converts the
/// complete batch to one semantic scroll event with its source and gesture phase.
fn frame(data: ?*anyopaque, _: ?*c.wl_pointer) callconv(.c) void {
    const self = from(data);
    if (self.seen == 0 and self.stopped == 0) {
        return;
    }
    const precise = self.source == c.WL_POINTER_AXIS_SOURCE_FINGER or self.source == c.WL_POINTER_AXIS_SOURCE_CONTINUOUS;
    const was_active = self.active != 0;
    var delta: [2]f64 = undefined;
    for (&delta, 0..) |*value, index| {
        value.* = if (precise) self.axes[index] else if (self.value120[index] != 0) self.value120[index] / wheel_units else if (self.discrete[index] != 0) self.discrete[index] else self.axes[index] / wheel_step;
    }
    self.axes = @splat(0);
    self.discrete = @splat(0);
    self.value120 = @splat(0);
    self.active = if (precise) (self.active | self.seen) & ~self.stopped else 0;
    self.scroll(delta, precise, if (!precise) .none else if (self.active == 0) .ended else if (was_active) .changed else .began);
    self.seen = 0;
    self.stopped = 0;
    if (self.active == 0) {
        self.source = c.WL_POINTER_AXIS_SOURCE_WHEEL;
    }
}

fn axis(data: ?*anyopaque, handle: ?*c.wl_pointer, time: u32, direction: u32, value: c.wl_fixed_t) callconv(.c) void {
    if (direction > c.WL_POINTER_AXIS_HORIZONTAL_SCROLL) {
        return;
    }
    const self = from(data);
    self.axes[direction] += c.wl_fixed_to_double(value);
    self.seen |= @as(u32, 1) << @intCast(direction);
    self.time = time;
    if (c.wl_pointer_get_version(handle) < c.WL_POINTER_FRAME_SINCE_VERSION) {
        frame(data, handle);
    }
}

fn axisSource(data: ?*anyopaque, _: ?*c.wl_pointer, source: u32) callconv(.c) void {
    const self = from(data);
    if (source != self.source) {
        self.active = 0;
    }
    self.source = source;
}

fn axisStop(data: ?*anyopaque, _: ?*c.wl_pointer, time: u32, direction: u32) callconv(.c) void {
    if (direction <= c.WL_POINTER_AXIS_HORIZONTAL_SCROLL) {
        const self = from(data);
        self.stopped |= @as(u32, 1) << @intCast(direction);
        self.time = time;
    }
}

fn axisDiscrete(data: ?*anyopaque, _: ?*c.wl_pointer, direction: u32, value: i32) callconv(.c) void {
    if (direction <= c.WL_POINTER_AXIS_HORIZONTAL_SCROLL) {
        from(data).discrete[direction] += @floatFromInt(value);
    }
}

fn axisValue120(data: ?*anyopaque, _: ?*c.wl_pointer, direction: u32, value: i32) callconv(.c) void {
    if (direction <= c.WL_POINTER_AXIS_HORIZONTAL_SCROLL) {
        from(data).value120[direction] += @floatFromInt(value);
    }
}

const listener = std.mem.zeroInit(c.wl_pointer_listener, .{
    .enter = enter,
    .leave = leave,
    .motion = motion,
    .button = button,
    .axis = axis,
    .frame = frame,
    .axis_source = axisSource,
    .axis_stop = axisStop,
    .axis_discrete = axisDiscrete,
    .axis_value120 = axisValue120,
});
