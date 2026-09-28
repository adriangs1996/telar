//! One allowlisted path under an agent's configuration directory, and how
//! `telar machine setup` transforms it before it leaves.
const ConfigEntry = @This();

/// How a synced file is transformed before it leaves.
pub const Format = enum {
    /// Copied as is, with this home's paths turned into the machine's.
    text,
    /// JSON or JSONC: secret keys dropped, paths rewritten, comments lost.
    json,
    /// Codex's TOML: secret tables and keys dropped, paths rewritten.
    toml,
};

pub const Kind = enum { file, directory };

path: []const u8,
kind: Kind,
format: Format = .text,
/// The agent's hook settings: telar's hooks are placed for the machine.
hooks: bool = false,
