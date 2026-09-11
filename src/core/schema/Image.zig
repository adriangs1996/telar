const id = @import("id.zig");
const ImageType = @import("../Image.zig");
const Image = @This();

pane_id: id.PaneId,
revision: u64,
image: ImageType,
