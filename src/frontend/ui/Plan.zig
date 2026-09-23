const icons = @import("icons.zig");
const Mark = @import("Mark.zig");
const Plan = @This();

marks: [icons.max_marks]Mark = undefined,
len: u8 = 0,

pub fn reset(self: *Plan) void {
    self.len = 0;
}

pub fn add(self: *Plan, mark: Mark) void {
    if (self.len == self.marks.len) {
        return;
    }
    self.marks[self.len] = mark;
    self.len += 1;
}

pub fn slice(self: *const Plan) []const Mark {
    return self.marks[0..self.len];
}
