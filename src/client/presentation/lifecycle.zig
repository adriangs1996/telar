//! Single-flight presentation identity. Preparation never retires model damage.

pub const Token = enum(u64) { _ };
pub const Outcome = enum { delivered, failed, cancelled };
