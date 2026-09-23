//! A bounded paint plan contains only fragments intersecting its viewport.
const MessageLayoutKey = @import("MessageLayoutKey.zig");
const MessageLayoutResult = @import("MessageLayoutResult.zig");
const MessageLayoutFragment = @import("MessageLayoutFragment.zig");

const Plan = @This();

pub const capacity = 2048;

key: MessageLayoutKey = undefined,
result: MessageLayoutResult = undefined,
fragments: [capacity]MessageLayoutFragment = undefined,
len: usize = 0,
valid: bool = false,
overflow: bool = false,

/// Overflow falls back to the normal painter; an incomplete plan is never reused.
/// Example: `plan.append(.{ .offset = start, .len = text.len, ... });`
pub fn append(self: *Plan, fragment: MessageLayoutFragment) void {
    if (self.len == self.fragments.len) {
        self.overflow = true;
        return;
    }

    self.fragments[self.len] = fragment;
    self.len += 1;
}

/// Publishes only a successfully laid-out complete source span.
/// Example: `plan.complete(.{ .height = y - start_y, .x = x });`
pub fn complete(self: *Plan, result: MessageLayoutResult) void {
    self.result = result;
    self.valid = !self.overflow;
}
