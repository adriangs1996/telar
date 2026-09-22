const AccessibilityNode = @import("AccessibilityNode.zig");
pub const AccessibilityTree = extern struct {
    revision: u64 = 0,
    nodes: ?[*]const AccessibilityNode.AccessibilityNode = null,
    count: u32 = 0,
};
