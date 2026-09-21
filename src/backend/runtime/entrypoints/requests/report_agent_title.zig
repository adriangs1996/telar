//! Protocol controller for agent title reports. Every request receives one
//! `request_completed` or `request_failed`.

pub const Outcome = enum { recorded, unchanged, rejected };
