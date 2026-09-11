const Head = @This();
const source_namespace = @import("path_marker.zig");
const Position = @import("Position.zig");
uuid: source_namespace.Uuid,
start: Position,
end: Position,
