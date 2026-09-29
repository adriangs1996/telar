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
    /// The sheet had no free favicon cell: the generic glyph stays.
    full,
};

workspace: core.WorkspaceId,
state: State = .wanted,
slot: u16 = 0,
