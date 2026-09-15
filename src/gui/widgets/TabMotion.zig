const Rect = @import("../render/Rect.zig");
const TabMotion = @This();

id: @import("telar-core").TabId,
from: Rect,
to: Rect,
transition: @import("../animation/Transition.zig"),
seen: bool = true,

/// Cubic ease-out keeps a quick response and a soft landing.
/// Example: `const bounds = motion.value(clock.now_ns);`
pub fn value(motion: TabMotion, now_ns: u64) Rect {
    const t = motion.transition.value(now_ns);
    const eased = 1 - (1 - t) * (1 - t) * (1 - t);
    return .{
        .x = motion.from.x + (motion.to.x - motion.from.x) * eased,
        .y = motion.from.y + (motion.to.y - motion.from.y) * eased,
        .width = motion.from.width + (motion.to.width - motion.from.width) * eased,
        .height = motion.from.height + (motion.to.height - motion.from.height) * eased,
    };
}
