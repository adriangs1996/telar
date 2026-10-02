//! `telar hook --help`.

const FamilyHelp = @import("../FamilyHelp.zig");

pub const family: FamilyHelp = .{
    .summary = "The entry point an agent's installed hook runs: reads the event on stdin and reports it",
    .usage = "telar hook claude|codex|pi|cursor|opencode [--socket PATH]",
    .text =
    \\Not meant to be typed: `telar integration install AGENT` registers it with the agent,
    \\which runs it with the event's JSON on standard input. It maps the event to one
    \\official report (state, blocked reason, session, command) for the pane named by
    \\TELAR_PANE_ID and TELAR_PANE_GENERATION, and the runtime accepts it only from a
    \\process that descends from that pane. Outside a pane, or on any error, it exits 0 so
    \\the agent never stalls. Claude Code's WorktreeCreate and WorktreeRemove run in every
    \\session and answer with a checkout path. Needs a running runtime; never starts one.
    \\
    ,
    .commands = &.{},
};
