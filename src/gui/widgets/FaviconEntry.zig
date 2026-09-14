//! One workspace's favicon in the GUI registry: what the lookup found and,
//! once placed, where it sits in the sprite page.
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const Sprite = @import("../image/Sprite.zig");

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

workspace: WorkspaceIdType,
state: State = .wanted,
sprite: Sprite = .{ .index = 0 },
