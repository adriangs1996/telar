const OfferPaneGeometryHandler = @This();
const OfferEffects = @import("OfferEffects.zig");
const source_namespace = @import("pane_geometry_delivery.zig");
effects: OfferEffects,

/// Offers every attached pane that has visible content in the supplied
/// layout rectangle.
///
/// ```zig
/// const count = try handler.execute(model, area);
/// ```
pub fn execute(handler: *OfferPaneGeometryHandler, model: *source_namespace.multiplexer.Model, area: source_namespace.ui.Rect) !usize {
    var count: usize = 0;
    var layout = model.layoutSnapshot(area).*;
    _ = layout.reserveBelowPane(handler.effects.bottom_reservation(handler.effects.context));
    var panes = model.paneIterator();
    while (panes.next()) |pane| {
        if (!pane.attached) {
            continue;
        }

        const view = layout.find(pane.id) orelse continue;
        var size = source_namespace.multiplexer.rectSize(view.content) orelse continue;
        size.cell_width_px = model.cell_width_px;
        size.cell_height_px = model.cell_height_px;
        try handler.effects.deliver_resize(handler.effects.context, .{
            .pane_id = pane.id,
            .size = size,
        });
        count += 1;
    }

    return count;
}
