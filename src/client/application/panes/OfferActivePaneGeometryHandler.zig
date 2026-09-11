const OfferActivePaneGeometryHandler = @This();
const client_model = @import("../../root.zig").model;
const OfferEffects = @import("OfferEffects.zig");
const source_namespace = @import("pane_geometry_delivery.zig");
const OfferPaneGeometryHandler = @import("OfferPaneGeometryHandler.zig");
model: *client_model.Model,
effects: OfferEffects,

/// Selects the active tab once and offers its attached visible panes.
/// An empty client has no geometry to deliver.
///
/// ```zig
/// const count = try handler.execute(area);
/// ```
pub fn execute(handler: *OfferActivePaneGeometryHandler, area: source_namespace.ui.Rect) !usize {
    const active = handler.model.workspace.active() orelse return 0;
    var offer: OfferPaneGeometryHandler = .{ .effects = handler.effects };

    return offer.execute(&active.model, area);
}
