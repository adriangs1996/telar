//! The meaning a bar or panel component communicates. Adapters map it to a
//! palette role, so a theme change never leaves a configured bar unreadable.
const bar_values = @import("model.zig");

const warning_bonus: u8 = 20;
const danger_bonus: u8 = 40;

pub const Tone = enum(u3) {
    neutral,
    muted,
    accent,
    success,
    warning,
    danger,

    /// Extra fitting priority, so a component asking for attention is the
    /// last one a narrow bar drops.
    /// Example: `const effective = node.priority +| node.tone.priorityBonus();`
    pub fn priorityBonus(self: Tone) u8 {
        return switch (self) {
            .warning => warning_bonus,
            .danger => danger_bonus,
            else => 0,
        };
    }

    /// The palette role of text in this tone. Neutral text is plain text;
    /// colour is kept for attention.
    /// Example: `const role = node.tone.inkRole();`
    pub fn inkRole(self: Tone) bar_values.PaletteColor {
        return switch (self) {
            .neutral => .text,
            .muted => .subtext0,
            else => self.markRole(),
        };
    }

    /// The palette role of a meter, a sparkline or an icon in this tone.
    /// Example: `const role = node.tone.markRole();`
    pub fn markRole(self: Tone) bar_values.PaletteColor {
        return switch (self) {
            .neutral, .muted => .subtext0,
            .accent => .accent,
            .success => .green,
            .warning => .yellow,
            .danger => .red,
        };
    }
};
