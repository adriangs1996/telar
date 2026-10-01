const core = @import("telar-core");
const AccessibilityNode = @import("AccessibilityNode.zig");

/// Mirrors `TELAR_GUI_ACCESSIBILITY_CAPACITY`: nodes one published tree may
/// hold. Targets past it stay usable by pointer and keyboard but are not
/// published, and the window reports the limit.
pub const capacity = 256;
pub const limit = core.Limit.declare("gui.native.accessibility_capacity", "accessible nodes", capacity);

pub const AccessibilityTree = extern struct {
    revision: u64 = 0,
    nodes: ?[*]const AccessibilityNode.AccessibilityNode = null,
    count: u32 = 0,
};
