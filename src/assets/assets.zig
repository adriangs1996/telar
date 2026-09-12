//! Binary assets embedded once and shared by every presentation adapter.
//! Example: `const face = @import("assets").jetbrains_mono;`

pub const jetbrains_mono: []const u8 = @embedFile("JetBrainsMono-Regular.ttf");
pub const nerd_icons: []const u8 = @embedFile("TelarNerdIcons-Regular.ttf");
pub const telar_mark_64_rgba: []const u8 = @embedFile("telar-mark-64.rgba");
pub const provider_marks_rgba: []const u8 = @embedFile("provider-marks-768x256.rgba");
