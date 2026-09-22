const path_marker = @import("path_marker.zig");
const Position = @import("Position.zig");
const Head = @This();

uuid: path_marker.Uuid,
start: Position,
end: Position,
