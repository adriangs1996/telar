const PanePasteSessionType = @import("../state/PanePasteSession.zig");
const Boundary = @import("PanePasteBoundary.zig").PanePasteBoundary;

pub const PanePasteDelivery = union(enum) {
    marker: struct {
        session: PanePasteSessionType,
        boundary: Boundary,
    },
    content: struct {
        session: PanePasteSessionType,
        /// Borrowed only for the synchronous delivery effect.
        text: []const u8,
    },
};
