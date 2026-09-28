//! Values accepted and published by the agent capability.

pub const working_expiry_ms: i64 = 2 * 60 * 1000;
/// A hook reports work only at its boundaries, and a long model turn fires
/// none in between, so a report's `working` outlives the heuristics' before
/// a silent hook hands control back.
pub const report_working_expiry_ms: i64 = 10 * 60 * 1000;
/// A helper renews a working report only once less than this is left, so a
/// burst of subagent tool calls republishes the projection once, not per call.
pub const report_renewal_margin_ms: i64 = report_working_expiry_ms / 2;
pub const settled_expiry_ms: i64 = 30 * 60 * 1000;
/// How long an interrupted agent's idle composer must hold before its turn
/// counts as ended. Claude Code 2.1.283 redraws the prompt it restores 1 ms
/// after it titles itself idle.
pub const interrupt_idle_ms: i64 = 500;
