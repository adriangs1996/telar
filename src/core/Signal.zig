/// One screen heuristic result. Heuristics change presentation only; they
/// never authorize input.
const Signal = @This();
const source_namespace = @import("agent_manifest.zig");
provider: source_namespace.AgentProvider = .unknown,
status: source_namespace.Status,
confidence: u8,
identity_confirmed: bool = false,
/// The sample contains an input prompt which proves the agent is waiting.
/// Provider branding alone confirms identity, not readiness.
ready_confirmed: bool = false,
