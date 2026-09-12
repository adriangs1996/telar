/// What a chrome adapter needs to resolve its sidebar renderer: host image
/// support and the cell pixel size.
const SupportType = @import("../environment/environment.zig").Support;
const SidebarRendererInput = @This();

support: SupportType,
cell_width: u16,
cell_height: u16,
