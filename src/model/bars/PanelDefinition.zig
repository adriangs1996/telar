//! One entry of `client.panels`: what the panel looks like and where its
//! components come from. Only `dynamic` and `command` sources are accepted.
const PanelHeading = @import("PanelHeading.zig");
const model = @import("model.zig");
const PanelDefinition = @This();

heading: PanelHeading = .{},
source: model.Source = .empty,
