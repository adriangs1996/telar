//! A bounded paint plan contains only fragments intersecting its viewport.
const Plan = @This();

pub const capacity = 2048;

key: @import("MessageLayoutKey.zig") = undefined,
result: @import("MessageLayoutResult.zig") = undefined,
fragments: [capacity]@import("MessageLayoutFragment.zig") = undefined,
len: usize = 0,
valid: bool = false,
overflow: bool = false,

/// Overflow falls back to the normal painter; an incomplete plan is never reused.
/// Example: `plan.append(.{ .offset = start, .len = text.len, ... });`
pub fn append(self: *Plan, fragment: @import("MessageLayoutFragment.zig")) void {
    if (self.len == self.fragments.len) {
        self.overflow = true;
        return;
    }

    self.fragments[self.len] = fragment;
    self.len += 1;
}

/// Publishes only a successfully laid-out complete source span.
/// Example: `plan.complete(.{ .height = y - start_y, .x = x });`
pub fn complete(self: *Plan, result: @import("MessageLayoutResult.zig")) void {
    self.result = result;
    self.valid = !self.overflow;
}
