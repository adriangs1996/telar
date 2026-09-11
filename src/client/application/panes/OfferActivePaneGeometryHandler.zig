const ModelType = @import("../../model/Model.zig");
const OfferEffects = @import("OfferEffects.zig");
const RectType = @import("telar-core").Rect;
const OfferPaneGeometryHandler = @import("OfferPaneGeometryHandler.zig");
const OfferActivePaneGeometryHandler = @This();

model: *ModelType,
effects: OfferEffects,

/// Selects the active tab once and offers its attached visible panes.
/// An empty client has no geometry to deliver.
///
/// ```zig
/// const count = try handler.execute(area);
/// ```
pub fn execute(handler: *OfferActivePaneGeometryHandler, area: RectType) !usize {
    const active = handler.model.workspace.active() orelse return 0;
    var offer: OfferPaneGeometryHandler = .{ .effects = handler.effects };

    return offer.execute(&active.model, area);
}
