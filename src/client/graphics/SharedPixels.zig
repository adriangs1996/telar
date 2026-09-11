const SharedPixels = @This();

name: [64]u8 = undefined,
len: u8,

pub fn slice(shared: *const SharedPixels) []const u8 {
    return shared.name[0..shared.len];
}

pub fn sliceZ(shared: *const SharedPixels) [:0]const u8 {
    return shared.name[0..shared.len :0];
}
