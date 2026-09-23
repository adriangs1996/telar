const PanePasteSession = @import("../state/PanePasteSession.zig");
const Boundary = @import("PanePasteBoundary.zig").PanePasteBoundary;

pub const PanePasteDelivery = union(enum) {
    marker: struct {
        session: PanePasteSession,
        boundary: Boundary,
    },
    content: struct {
        session: PanePasteSession,
        /// Borrowed only for the synchronous delivery effect.
        text: []const u8,
    },
};
