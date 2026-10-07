const Origin = @import("Origin.zig").Origin;
const Size = @import("Size.zig").Size;

pub const Region = extern struct {
    origin: Origin = .{},
    size: Size,
};
