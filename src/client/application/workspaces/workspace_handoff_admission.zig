//! Application admission policy for starting one workspace handoff.

pub const Authority = enum {
    requested_departure,
    canonical_follow,
};
