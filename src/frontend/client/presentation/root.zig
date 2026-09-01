//! Presentation state and commit lifecycle owned by one client.

pub const lifecycle = @import("presentation_lifecycle.zig");
pub const projection = @import("presentation_projection.zig");
pub const presenter = @import("presenter.zig");
pub const view = @import("view.zig");

test {
    _ = lifecycle;
    _ = projection;
    _ = presenter;
    _ = view;
}
