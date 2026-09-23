/// What a chrome adapter needs to resolve its sidebar renderer: host image
/// support and the cell pixel size.
const data = @import("model");
const SidebarRendererInput = @This();

support: data.EnvironmentSupport,
cell_width: u16,
cell_height: u16,
