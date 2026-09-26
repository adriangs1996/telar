//! Values accepted and published by the agent capability.

pub const working_expiry_ms: i64 = 2 * 60 * 1000;
/// A hook reports work only at its boundaries, and a long model turn fires
/// none in between, so a report's `working` outlives the heuristics' before
/// a silent hook hands control back.
pub const report_working_expiry_ms: i64 = 10 * 60 * 1000;
pub const settled_expiry_ms: i64 = 30 * 60 * 1000;
