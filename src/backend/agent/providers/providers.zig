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
const claude = @import("claude.zig");
const codex = @import("codex.zig");
const cursor = @import("cursor.zig");
const opencode = @import("opencode.zig");
const pi = @import("pi.zig");

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
