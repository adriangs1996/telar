//! Artwork Telar ships for well-known tools. Adapters draw the embedded
//! sprite where they can and the matching icon glyph elsewhere.
const core = @import("telar-core");
const ui_icons = @import("../layout/icons.zig");

pub const Mark = enum(u3) {
    claude,
    codex,
    pi,
    telar,

    /// The icon drawn when the adapter has no sprite for the mark.
    /// Example: `const icon = mark.icon();`
    pub fn icon(self: Mark) ui_icons.Icon {
        return switch (self) {
            .claude => .provider_claude,
            .codex => .provider_codex,
            .pi => .provider_pi,
            .telar => .telar_mark,
        };
    }

    /// The agent provider whose sprite the mark reuses, when it has one.
    /// Example: `if (mark.provider()) |provider| canvas.providerMark(provider);`
    pub fn provider(self: Mark) ?core.AgentProvider {
        return switch (self) {
            .claude => .claude,
            .codex => .codex,
            .pi => .pi,
            .telar => null,
        };
    }
};
