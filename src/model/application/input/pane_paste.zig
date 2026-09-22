//! Application policy for one streamed host paste owned by a pane.

pub const Boundary = @import("../../types/PanePasteBoundary.zig").PanePasteBoundary;

pub const Delivery = @import("../../types/PanePasteDelivery.zig").PanePasteDelivery;

pub const Outcome = @import("../../types/PanePasteOutcome.zig").PanePasteOutcome;
