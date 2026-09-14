pub const AccessibilityTree = extern struct {
    revision: u64 = 0,
    nodes: ?[*]const @import("AccessibilityNode.zig").AccessibilityNode = null,
    count: u32 = 0,
};
