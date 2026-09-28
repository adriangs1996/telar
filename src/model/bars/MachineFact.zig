//! One machine as the `machines` component shows it: its label, whether the
//! window shows it, how its link is, whether it asks for the person, and its
//! latest CPU sample. The adapter borrows the labels for one frame.
const RuntimeLink = @import("../connection/RuntimeLink.zig");
const MachineFact = @This();

label: []const u8,
active: bool = false,
phase: RuntimeLink.Phase = .connected,
attention: bool = false,
cpu_percent: ?u8 = null,
