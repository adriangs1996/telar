const std = @import("std");
const shared = @import("telar-core").ui;

pub const Theme = enum {
    unicode,
    nerd_font,

    pub fn parse(name: []const u8) !Theme {
        if (std.ascii.eqlIgnoreCase(name, "unicode")) {
            return .unicode;
        }
        if (std.ascii.eqlIgnoreCase(name, "nerd-font") or
            std.ascii.eqlIgnoreCase(name, "nerdfont") or
            std.ascii.eqlIgnoreCase(name, "nerd"))
        {
            return .nerd_font;
        }
        return error.UnknownIconTheme;
    }

    pub fn canonicalName(theme: Theme) []const u8 {
        return switch (theme) {
            .unicode => "unicode",
            .nerd_font => "nerd-font",
        };
    }
};

pub const Icon = enum {
    sidebar_collapse,
    sidebar_expand,
    workspace_menu,
    proxy_active,
    cpu,
    memory,
    battery_empty,
    battery_quarter,
    battery_half,
    battery_three_quarters,
    battery_full,
    provider_unknown,
    provider_claude,
    provider_codex,
    provider_pi,
    agent_unknown,
    agent_working_0,
    agent_working_1,
    agent_working_2,
    agent_working_3,
    agent_blocked,
    agent_ready,
    agent_done,
    agent_failed,
    close,
    pane_fullscreen,
    /// The telar mark. Embedded artwork under every icon theme wherever
    /// graphics are available; a plain square glyph elsewhere.
    telar_mark,

    /// The shipped artwork for a built-in agent. Configured agents have no
    /// artwork here; their manifest glyph or the generic mark is drawn instead.
    ///
    /// ```zig
    /// const icon = Icon.forProvider(agent.provider) orelse .provider_unknown;
    /// ```
    pub fn forProvider(provider: @import("telar-core").schema.AgentProvider) ?Icon {
        return switch (provider) {
            .claude => .provider_claude,
            .codex => .provider_codex,
            .pi => .provider_pi,
            else => null,
        };
    }

    pub fn unicodeGlyph(icon: Icon) []const u8 {
        return switch (icon) {
            .sidebar_collapse => "\u{25c0}",
            .sidebar_expand => "\u{25b6}",
            .workspace_menu => "\u{2756}",
            .proxy_active => "\u{26e8}",
            .cpu => "\u{2699}",
            .memory => "\u{25a4}",
            .battery_empty,
            .battery_quarter,
            .battery_half,
            .battery_three_quarters,
            .battery_full,
            => "\u{26a1}",
            .provider_unknown, .agent_unknown => "?",
            .provider_claude => "\u{2733}",
            .provider_codex => "\u{25c6}",
            .provider_pi => "\u{03c0}",
            .agent_working_0 => "\u{25d0}",
            .agent_working_1 => "\u{25d3}",
            .agent_working_2 => "\u{25d1}",
            .agent_working_3 => "\u{25d2}",
            .agent_blocked => "!",
            .agent_ready => "\u{2713}",
            .agent_done => "\u{2714}",
            .agent_failed => "\u{00d7}",
            .close => "\u{00d7}",
            .pane_fullscreen => "\u{26f6}",
            .telar_mark => "\u{25a3}",
        };
    }

    pub fn nerdGlyph(icon: Icon) []const u8 {
        return switch (icon) {
            .sidebar_collapse => "\u{eab5}", // cod-chevron-left
            .sidebar_expand => "\u{eab6}", // cod-chevron-right
            .workspace_menu => "\u{eacd}", // cod-dashboard
            .proxy_active => "\u{eb53}", // cod-shield
            .cpu => "\u{f4bc}", // oct-cpu
            .memory => "\u{efc5}", // fa-memory
            .battery_empty => "\u{f244}", // fa-battery-empty
            .battery_quarter => "\u{f243}", // fa-battery-quarter
            .battery_half => "\u{f242}", // fa-battery-half
            .battery_three_quarters => "\u{f241}", // fa-battery-three-quarters
            .battery_full => "\u{f240}", // fa-battery-full
            .provider_unknown, .agent_unknown => "\u{eb32}", // cod-question
            .provider_claude => "\u{ec20}", // cod-robot
            .provider_codex => "\u{ea85}", // cod-terminal
            .provider_pi => "\u{f03ff}", // md-pi
            .agent_working_0 => "\u{ee06}", // extra-progress-spinner-1
            .agent_working_1 => "\u{ee07}", // extra-progress-spinner-2
            .agent_working_2 => "\u{ee08}", // extra-progress-spinner-3
            .agent_working_3 => "\u{ee09}", // extra-progress-spinner-4
            .agent_blocked => "\u{ea6c}", // cod-warning
            .agent_ready => "\u{ebb3}", // cod-pass-filled
            .agent_done => "\u{eba4}", // cod-pass
            .agent_failed => "\u{ea87}", // cod-error
            .close => "\u{ea76}", // cod-close
            .pane_fullscreen => "\u{eb4c}", // cod-screen-full
            .telar_mark => "\u{25a3}", // artwork in the atlas, never rasterized from the font
        };
    }

    /// A one-cell placeholder used only while the opaque KGP replacement is
    /// being transferred. Terminals without KGP keep `unicodeGlyph` instead.
    pub fn cellFallbackGlyph(icon: Icon) []const u8 {
        return switch (icon) {
            .sidebar_collapse => "<",
            .sidebar_expand => ">",
            .workspace_menu => "W",
            .proxy_active => "S",
            .cpu => "C",
            .memory => "M",
            .battery_empty,
            .battery_quarter,
            .battery_half,
            .battery_three_quarters,
            .battery_full,
            => "B",
            .provider_unknown, .agent_unknown => "?",
            .provider_claude => "A",
            .provider_codex => "X",
            .provider_pi => "P",
            .agent_working_0,
            .agent_working_1,
            .agent_working_2,
            .agent_working_3,
            => "*",
            .agent_blocked => "!",
            .agent_ready => "+",
            .agent_done => "*",
            .agent_failed => "x",
            .close => "x",
            .pane_fullscreen => "F",
            .telar_mark => " ", // the artwork carries alpha, so nothing may show through
        };
    }
};
