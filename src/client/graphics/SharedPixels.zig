const SharedPixels = @This();

name: [64]u8 = undefined,
len: u8,

pub fn slice(self: *const SharedPixels) []const u8 {
    return self.name[0..self.len];
}

pub fn sliceZ(self: *const SharedPixels) [:0]const u8 {
    return self.name[0..self.len :0];
}
