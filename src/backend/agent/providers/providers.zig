//! Code-level capabilities of the built-in agents.
//!
//! The manifest table in `core.agent_manifest` carries everything that
//! configuration can express: identity, screen phrases, presentation and the
//! attachment scheme. What remains is runtime behaviour that needs code: how a
//! session is resumed and which lifecycle quirks the aggregate must tolerate.
//! Each built-in agent owns one file here. A configured agent resolves to
//! `default`, which claims none of it, so adding an agent by configuration
//! never crosses into this table.
//!
//! Resolution is a switch on the provider index; nothing here allocates or
//! runs on the interactive path. Screen scans that need the emulator live in
//! `history.prompt_scan`, because the history package is built on its own.

const core = @import("telar-core");
const Capabilities = @import("Capabilities.zig");
const SessionFormat = @import("SessionFormat.zig").SessionFormat;
const claude = @import("claude.zig");
const codex = @import("codex.zig");
const cursor = @import("cursor.zig");
const opencode = @import("opencode.zig");
const pi = @import("pi.zig");
const std = @import("std");

pub const default: Capabilities = .{};

/// Resolves the capabilities of one provider. Unknown and configured
/// providers share `default`.
///
/// ```zig
/// const prefix = providers.of(record.provider).resume_prefix orelse return null;
/// ```
pub fn of(provider: core.AgentProvider) *const Capabilities {
    return switch (provider) {
        .claude => &claude.capabilities,
        .codex => &codex.capabilities,
        .pi => &pi.capabilities,
        .cursor => &cursor.capabilities,
        .opencode => &opencode.capabilities,
        else => &default,
    };
}

test "built-in agents own their capabilities and configured agents get the default" {
    try std.testing.expectEqualStrings("claude --resume ", of(.claude).resume_prefix.?);
    try std.testing.expectEqualStrings("codex resume ", of(.codex).resume_prefix.?);
    try std.testing.expectEqualStrings("pi --session ", of(.pi).resume_prefix.?);
    try std.testing.expectEqualStrings("cursor-agent --resume ", of(.cursor).resume_prefix.?);
    try std.testing.expectEqualStrings("opencode --session ", of(.opencode).resume_prefix.?);
    try std.testing.expectEqual(SessionFormat.opencode, of(.opencode).session_format);
    try std.testing.expectEqual(SessionFormat.uuid, of(.claude).session_format);
    try std.testing.expect(of(.unknown).resume_prefix == null);
    try std.testing.expect(of(@enumFromInt(core.first_custom_agent_provider)).resume_prefix == null);

    try std.testing.expect(of(.codex).ready_prompt_settles_report);
    try std.testing.expect(!of(.claude).ready_prompt_settles_report);
    try std.testing.expect(!of(.pi).ready_prompt_settles_report);
    try std.testing.expect(of(.cursor).screen_reports_blocked);
    try std.testing.expect(!of(.claude).screen_reports_blocked);
}

test {
    std.testing.refAllDecls(claude);
    std.testing.refAllDecls(codex);
    std.testing.refAllDecls(cursor);
    std.testing.refAllDecls(opencode);
    std.testing.refAllDecls(pi);
}
