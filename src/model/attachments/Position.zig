const Position = @This();

x: u16,
y: u16,

pub fn eql(self: Position, b: Position) bool {
    return self.x == b.x and self.y == b.y;
}
