//! Application use case for adopting one client configuration generation.

const data = @import("model");
const client_diagnostic = @import("client_diagnostic.zig");

pub const Event = enum {
    adopt_resources,
    synchronize_bars,
    project_appearance,
    configure_sidebar,
    apply_sidebar,
    invalidate_graphics_placements,
    offer_active_pane_geometry,
};

pub const Failure = enum {
    none,
    synchronize_bars,
    configure_sidebar,
    apply_sidebar,
    pane_geometry,
};

fn installDiagnostic(model: *data.Model) !void {
    _ = try model.replaceDiagnostic(client_diagnostic.formatted("previous configuration failed", .{}));
}
