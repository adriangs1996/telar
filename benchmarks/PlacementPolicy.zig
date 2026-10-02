//! Which allocations the placement experiment controls and how it spreads
//! them. Every value is an input: the window defaults to the host's page
//! size because the caller reads it from the host, not because a page is the
//! right span on every processor.
const std = @import("std");
const PlacementMode = @import("PlacementMode.zig").PlacementMode;
const PlacementPolicy = @This();

pub const default_threshold = 32 * 1024;
pub const default_stride = 512;
/// `shift` moves every controlled allocation by this fraction of the window.
const shift_divisor = 4;

mode: PlacementMode = .baseline,
/// Smallest allocation controlled, in bytes.
threshold: usize = default_threshold,
/// Step between staggered offsets and largest alignment controlled.
stride: usize = default_stride,
/// Span the offsets are spread over, and the slack `shift` and `stagger` add
/// to each controlled allocation.
window: usize,

/// Rejects a policy whose offsets would break a record's alignment or leave
/// `shift` and `stagger` nowhere to move it.
///
/// ```zig
/// try policy.validate();
/// ```
pub fn validate(self: PlacementPolicy) !void {
    if (self.threshold == 0) {
        return error.InvalidPlacementThreshold;
    }

    if (self.stride == 0 or !std.math.isPowerOfTwo(self.stride)) {
        return error.InvalidPlacementStride;
    }

    if (self.window == 0 or !std.math.isPowerOfTwo(self.window) or self.window / shift_divisor < self.stride) {
        return error.InvalidPlacementWindow;
    }
}

/// Reports whether an allocation of this shape is controlled. The shape is
/// all the policy sees; it never learns the Zig type.
///
/// ```zig
/// const placed = policy.selects(@sizeOf(Pane), .of(Pane));
/// ```
pub fn selects(self: PlacementPolicy, len: usize, alignment: std.mem.Alignment) bool {
    return self.mode != .baseline and len >= self.threshold and alignment.toByteUnits() <= self.stride;
}

/// The offset `shift` gives every controlled allocation.
///
/// ```zig
/// const offset = policy.shiftBytes();
/// ```
pub fn shiftBytes(self: PlacementPolicy) usize {
    return self.window / shift_divisor;
}

/// How many offsets `stagger` walks before it repeats one.
///
/// ```zig
/// const offset = (position % policy.staggerPositions()) * policy.stride;
/// ```
pub fn staggerPositions(self: PlacementPolicy) usize {
    return self.window / self.stride;
}
