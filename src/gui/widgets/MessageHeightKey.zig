//! Every input of a thread message's measured height. The text is a
//! fingerprint, as in `MessageLayoutKey`; everything else compares exactly.
const core = @import("telar-core");
const ChromeMetrics = @import("ChromeMetrics.zig");
const Metrics = @import("../TerminalMetrics.zig");

text_hash: u64,
text_len: u32,
width: f32,
font_identity: u64,
font_revision: u64,
chrome: ChromeMetrics,
metrics: Metrics,
role: core.agent_thread.Role,
complete: bool,
identified: bool,
fragment_start: bool,
fragment_end: bool,
