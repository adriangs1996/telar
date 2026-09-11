const Marker = @This();
const source_namespace = @import("path_marker.zig");
const Position = @import("Position.zig");
uuid: source_namespace.Uuid,
/// First cell of the path, which is the first `/` of the word holding
/// the file name so a word soft-wrapped before it is never included.
start: Position,
/// One past the last extension cell on its row.
end: Position,
/// Editor steps from `start` to `end`, or null when the path exceeds
/// `max_cells`. A marker is still recognisable without its extent.
cells: ?u8,
