const SessionFormat = @import("SessionFormat.zig").SessionFormat;
const core = @import("telar-core");
const Capabilities = @This();

/// Shell words that resume a session by its reference, ending in the space
/// that separates them from the reference. `null` means the agent cannot
/// be resumed by Telar; only this table can ever produce a resume command.
resume_prefix: ?[]const u8 = null,
/// The argument that keeps the agent's interactive session, and the hooks
/// it runs, in the pane's own process. An interactive session started
/// without it may run them in a shared server that left the pane, whose
/// hooks cannot report there. A resume adds it only when the session ran
/// with it, since a version without the argument refuses it.
pane_session_argument: ?[]const u8 = null,
/// Arguments naming a subcommand or an option that runs no interactive
/// session, to which `pane_session_argument` does not apply.
batch_arguments: []const []const u8 = &.{},
/// Where telar's hooks for the agent are installed; the card suggests
/// `pane_session_argument` only to someone who installed them.
hook_settings: ?core.HookSettings = null,
/// The shape a session reference must have to be resumed.
session_format: SessionFormat = .uuid,
/// The agent's `settling` report still needs a newer idle composer.
/// Active work cannot be settled by a prompt, and process or model
/// completion alone does not establish readiness.
ready_prompt_settles_report: bool = false,
/// A screen scan confirms the agent's idle composer (`ready_confirmed`), so
/// an interrupted turn waits for it rather than for a fixed time.
screen_shows_idle: bool = false,
/// Process presence alone does not prove an idle agent.
completion_requires_agent_signal: bool = false,
/// The agent has no hook for its approval prompts, so a blocked screen
/// observed after its latest report decides the projection until a newer
/// report or screen replaces it.
screen_reports_blocked: bool = false,
