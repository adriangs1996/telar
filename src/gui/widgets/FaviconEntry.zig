//! One workspace's favicon in the GUI registry: what the lookup found and,
//! once placed, which sprite page slot holds it at every size.
const core = @import("telar-core");

pub const State = enum {
    /// Needs a lookup; the controller has not accepted one yet.
    wanted,
    /// A lookup is in flight.
    pending,
    /// The sprite page holds the image.
    resolved,
    /// No usable file: the generic glyph stays.
    missing,
    /// Every favicon cell of the sheet belonged to a listed workspace: the
    /// generic glyph stays until a departed workspace releases a cell.
    full,
};

workspace: core.WorkspaceId,
state: State = .wanted,
slot: u16 = 0,
