//! One entry of `client.panels`: what the panel looks like and where its
//! components come from. Only `dynamic` and `command` sources are accepted.
const PanelHeading = @import("PanelHeading.zig");
const PanelSource = @import("PanelSource.zig").PanelSource;

heading: PanelHeading = .{},
source: PanelSource = .empty,
