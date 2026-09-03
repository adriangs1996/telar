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

const std = @import("std");
const core = @import("telar-core");

pub const claude = @import("claude.zig");
pub const codex = @import("codex.zig");
pub const pi = @import("pi.zig");

const AgentProvider = core.schema.AgentProvider;

pub const Capabilities = struct {
    /// Shell words that resume a session by its reference, ending in the space
    /// that separates them from the reference. `null` means the agent cannot
    /// be resumed by Telar; only this table can ever produce a resume command.
    resume_prefix: ?[]const u8 = null,
    /// The agent reports `working` from its `Stop` hook before other hooks may
    /// continue the turn, so only its own newer input prompt proves that the
    /// report has ended.
    ready_prompt_settles_report: bool = false,
};

pub const default: Capabilities = .{};

/// Resolves the capabilities of one provider. Unknown and configured
/// providers share `default`.
///
/// ```zig
/// const prefix = providers.of(record.provider).resume_prefix orelse return null;
/// ```
pub fn of(provider: AgentProvider) *const Capabilities {
    return switch (provider) {
        .claude => &claude.capabilities,
        .codex => &codex.capabilities,
        .pi => &pi.capabilities,
        else => &default,
    };
}

test "built-in agents own their capabilities and configured agents get the default" {
    try std.testing.expectEqualStrings("claude --resume ", of(.claude).resume_prefix.?);
    try std.testing.expectEqualStrings("codex resume ", of(.codex).resume_prefix.?);
    try std.testing.expectEqualStrings("pi --session ", of(.pi).resume_prefix.?);
    try std.testing.expect(of(.unknown).resume_prefix == null);
    try std.testing.expect(of(@enumFromInt(core.schema.first_custom_agent_provider)).resume_prefix == null);

    try std.testing.expect(of(.codex).ready_prompt_settles_report);
    try std.testing.expect(!of(.claude).ready_prompt_settles_report);
    try std.testing.expect(!of(.pi).ready_prompt_settles_report);
}

test {
    std.testing.refAllDecls(claude);
    std.testing.refAllDecls(codex);
    std.testing.refAllDecls(pi);
}
