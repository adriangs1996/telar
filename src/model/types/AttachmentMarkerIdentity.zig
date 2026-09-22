const path_marker = @import("../attachments/path_marker.zig");

pub const AttachmentMarkerIdentity = union(enum) {
    number: u16,
    path: path_marker.Uuid,
};
