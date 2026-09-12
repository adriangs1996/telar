const ColorThemeType = @import("../appearance/Theme.zig");
const IconThemeType = @import("../layout/icons.zig").Theme;
const SidebarRendererInputType = @import("../layout/SidebarRendererInput.zig");
const MouseType = @import("../input/Mouse.zig");
const ViewInteractionCommandType = @import("../application/input/ViewInteractionCommand.zig");
const SidebarRenderingType = @import("../config/sidebar_rendering.zig").SidebarRendering;
const RegionType = @import("../workspace/Region.zig");
/// The adapter's chrome as the client application drives it: appearance,
/// sidebar renderer, size, committed chrome layout and pointer hit testing.
/// Reads of chrome geometry go through `Region`; this port only pushes.
const HostChrome = @This();

context: *anyopaque,
set_theme_fn: *const fn (*anyopaque, ColorThemeType) void,
set_icon_theme_fn: *const fn (*anyopaque, IconThemeType) void,
configure_sidebar_fn: *const fn (*anyopaque, SidebarRendererInputType) anyerror!void,
resize_fn: *const fn (*anyopaque, u16, u16) anyerror!void,
set_sidebar_layout_fn: *const fn (*anyopaque, bool, u16) void,
set_workspace_list_collapsed_fn: *const fn (*anyopaque, bool) void,
pointer_fn: *const fn (*anyopaque, MouseType) ViewInteractionCommandType,
sidebar_renderer_fn: *const fn (*anyopaque) SidebarRenderingType,
adopt_sidebar_renderer_fn: *const fn (*anyopaque, SidebarRenderingType) void,
region_fn: *const fn (*anyopaque) RegionType,
inspection_scroll_limit_fn: *const fn (*anyopaque) ?u32,

pub fn setTheme(port: HostChrome, theme: ColorThemeType) void {
    port.set_theme_fn(port.context, theme);
}

pub fn setIconTheme(port: HostChrome, theme: IconThemeType) void {
    port.set_icon_theme_fn(port.context, theme);
}

/// Example: `try client.chrome.configureSidebar(.{ .support = images, .cell_width = w, .cell_height = h });`.
pub fn configureSidebar(port: HostChrome, input: SidebarRendererInputType) !void {
    return port.configure_sidebar_fn(port.context, input);
}

/// Example: `try client.chrome.resize(size.cols, size.rows);`.
pub fn resize(port: HostChrome, cols: u16, rows: u16) !void {
    return port.resize_fn(port.context, cols, rows);
}

/// Applies committed sidebar state synchronously so geometry offers that
/// follow in the same event see the new workbench.
pub fn setSidebarLayout(port: HostChrome, visible: bool, width: u16) void {
    port.set_sidebar_layout_fn(port.context, visible, width);
}

pub fn setWorkspaceListCollapsed(port: HostChrome, collapsed: bool) void {
    port.set_workspace_list_collapsed_fn(port.context, collapsed);
}

/// Resolves one pointer event against the adapter's chrome hit map.
/// Example: `const interaction = client.chrome.pointer(event);`.
pub fn pointer(port: HostChrome, event: MouseType) ViewInteractionCommandType {
    return port.pointer_fn(port.context, event);
}

/// The renderer the adapter currently requests for its sidebar.
pub fn sidebarRenderer(port: HostChrome) SidebarRenderingType {
    return port.sidebar_renderer_fn(port.context);
}

/// Adopts the renderer a reloaded configuration selected.
pub fn adoptSidebarRenderer(port: HostChrome, value: SidebarRenderingType) void {
    port.adopt_sidebar_renderer_fn(port.context, value);
}

/// The workbench cell grid the adapter currently publishes.
pub fn region(port: HostChrome) RegionType {
    return port.region_fn(port.context);
}

/// The history inspector's scroll bound under the adapter's layout, when the
/// inspector is open and clamping is needed.
pub fn inspectionScrollLimit(port: HostChrome) ?u32 {
    return port.inspection_scroll_limit_fn(port.context);
}
