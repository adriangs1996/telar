const core = @import("telar-core");
const Rect = @import("../render/Rect.zig");
const TabMotion = @This();

id: core.TabId,
from: Rect,
to: Rect,
transition: @import("../animation/Transition.zig"),
seen: bool = true,

/// Cubic ease-out keeps a quick response and a soft landing.
/// Example: `const bounds = motion.value(clock.now_ns);`
pub fn value(self: TabMotion, now_ns: u64) Rect {
    const t = self.transition.value(now_ns);
    const eased = 1 - (1 - t) * (1 - t) * (1 - t);
    return .{
        .x = self.from.x + (self.to.x - self.from.x) * eased,
        .y = self.from.y + (self.to.y - self.from.y) * eased,
        .width = self.from.width + (self.to.width - self.from.width) * eased,
        .height = self.from.height + (self.to.height - self.from.height) * eased,
    };
}
