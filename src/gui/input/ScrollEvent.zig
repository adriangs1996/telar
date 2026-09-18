//! Content coordinates and precise deltas are physical pixels. Nonprecise
//! deltas are lines. Positive deltas move right/down, independently of momentum.
x: f64 = 0,
y: f64 = 0,
delta_x: f64 = 0,
delta_y: f64 = 0,
mods: u4 = 0,
precise: bool = false,
phase: Phase = .none,
momentum: Phase = .none,
// Native finger input without system momentum requests client inertia on end.
kinetic: bool = false,
// Native gesture timestamp in milliseconds, wrapping at u32. Used for kinetic input.
time_ms: u32 = 0,

pub const Phase = enum(u3) { none, begin, update, end, cancel };
