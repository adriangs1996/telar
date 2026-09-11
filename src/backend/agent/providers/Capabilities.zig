const Capabilities = @This();

/// Shell words that resume a session by its reference, ending in the space
/// that separates them from the reference. `null` means the agent cannot
/// be resumed by Telar; only this table can ever produce a resume command.
resume_prefix: ?[]const u8 = null,
/// The agent's `settling` report still needs a newer idle composer.
/// Active work cannot be settled by a prompt, and process or model
/// completion alone does not establish readiness.
ready_prompt_settles_report: bool = false,
/// Process presence and model response completion do not prove an idle agent.
completion_requires_agent_signal: bool = false,
