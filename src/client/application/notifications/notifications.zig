//! Application use cases for the client notification lifecycle.

const std = @import("std");

pub const DeliveryOutcome = enum {
    delivered,
    undelivered,
};
