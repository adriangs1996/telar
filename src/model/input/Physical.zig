const Physical = @This();

value: u32,

pub fn eql(a: Physical, b: Physical) bool {
    return a.value == b.value;
}
