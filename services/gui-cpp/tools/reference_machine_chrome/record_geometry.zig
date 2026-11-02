const gfx = @import("gfx");
const event = @import("Event.zig");
const Event = event.Event;
extern "c" fn getchar() c_int;
extern "c" fn putchar(c_int) c_int;

pub fn read(comptime T: type) !T {
    var bytes: [@sizeOf(T)]u8 = undefined;
    for (&bytes) |*byte| {
        const value = getchar();
        if (value < 0) {
            return error.TruncatedInput;
        }

        byte.* = @intCast(value);
    }

    return @bitCast(bytes);
}

pub fn write(value: anytype) !void {
    for (@as([@sizeOf(@TypeOf(value))]u8, @bitCast(value))) |byte| {
        if (putchar(byte) < 0) {
            return error.WriteFailed;
        }
    }
}

pub fn rectangle(kind: Event, area: gfx.Rect) !void {
    try write(@intFromEnum(kind));
    try write(area.x);
    try write(area.y);
    try write(area.width);
    try write(area.height);
}
