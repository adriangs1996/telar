const types = @import("schema/types.zig");
const agent_manifest = @import("agent_manifest.zig");
/// One screen heuristic result. Heuristics change presentation only; they
/// never authorize input.
const Signal = @This();

provider: types.AgentProvider = .unknown,
status: agent_manifest.Status,
confidence: u8,
identity_confirmed: bool = false,
/// The sample contains an input prompt which proves the agent is waiting.
/// Provider branding alone confirms identity, not readiness.
ready_confirmed: bool = false,
