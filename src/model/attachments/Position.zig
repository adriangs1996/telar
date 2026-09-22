const Position = @This();

x: u16,
y: u16,

pub fn eql(a: Position, b: Position) bool {
    return a.x == b.x and a.y == b.y;
}
