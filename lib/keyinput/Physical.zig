const Physical = @This();

value: u32,

pub fn eql(self: Physical, b: Physical) bool {
    return self.value == b.value;
}
