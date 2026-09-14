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

pub const Phase = enum(u3) { none, begin, update, end, cancel };
