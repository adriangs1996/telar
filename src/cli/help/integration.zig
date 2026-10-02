//! `telar integration --help` and the help of its commands.

const FamilyHelp = @import("../FamilyHelp.zig");

const files_text =
    \\Files per agent, under the agent's own directory ($CLAUDE_CONFIG_DIR, $CODEX_HOME,
    \\$PI_CODING_AGENT_DIR, $XDG_CONFIG_HOME/opencode; Cursor always under ~):
    \\  claude    ~/.claude/settings.json hooks (SessionStart, UserPromptSubmit, PreToolUse,
    \\            PostToolUse, Stop, Notification, SessionEnd, CwdChanged, WorktreeCreate,
    \\            WorktreeRemove)
    \\  codex     ~/.codex/hooks.json hooks; Codex must run with --no-daemon to be in a pane
    \\  cursor    ~/.cursor/hooks.json hooks
    \\  pi        ~/.pi/agent/extensions/telar.ts, an extension
    \\  opencode  ~/.config/opencode/plugins/telar.ts, a plugin
    \\and beside them `skills/telar/SKILL.md` (how to discover and drive telar) and
    \\`skills/telar-coordinator/SKILL.md` (delegating tasks to worktree agents), each
    \\marked as telar's so only telar's copies are ever replaced or removed.
;

pub const family: FamilyHelp = .{
    .summary = "Register telar's lifecycle hooks and skills with an agent CLI, or remove and inspect them",
    .usage = "telar integration install|uninstall|status claude|codex|pi|cursor|opencode [--settings PATH] [--legacy]",
    .text = files_text ++
        \\
        \\
        \\The hooks run `telar hook AGENT` with the executable that installed them, guarded so
        \\that outside a telar pane nothing runs. Through them the runtime learns an agent's
        \\official state, its session for restore and the commands it runs. Nothing here
        \\contacts a runtime.
        \\
    ,
    .commands = &.{
        .{
            .name = "install",
            .summary = "Add telar's hooks (or extension/plugin) and skills for an agent",
            .usage = "telar integration install claude|codex|pi|cursor|opencode [--settings PATH]",
            .text =
            \\Arguments:
            \\  --settings PATH  An absolute path to write instead of the agent's default file.
            \\
            \\Effects: for claude, codex and cursor, adds telar's command hook to each event that
            \\lacks it and rewrites a stale one (another path, an older guard), keeping every
            \\other hook; writes the JSON atomically through symlinks with the file's mode. For
            \\pi and opencode, writes the TypeScript file, replacing only telar's own. Then
            \\writes both skills beside them, so a newer telar refreshes them on install.
            \\
            \\Results: one line per thing installed, already present or updated. Exit 0; 1 when
            \\the settings are not a JSON object or a file at the path is not telar's.
            \\
            ,
            .examples = &.{ &.{ "integration", "install", "claude" }, &.{ "integration", "install", "opencode", "--settings", "/home/dev/.config/opencode/plugins/telar.ts" } },
        },
        .{
            .name = "uninstall",
            .summary = "Remove telar's hooks (or extension/plugin) and skills for an agent",
            .usage = "telar integration uninstall claude|codex|pi|cursor|opencode [--settings PATH | --legacy]",
            .text =
            \\Arguments:
            \\  --settings PATH  The file to edit instead of the default.
            \\  --legacy         Edit the settings file under the home directory that the agent's
            \\                   directory variable now hides, where older installs left hooks.
            \\
            \\Effects: removes only telar's entries and telar's skill files; the user's hooks,
            \\even in the same group, and a skill telar did not write stay. A pi or opencode
            \\file telar did not write is left untouched with exit 1.
            \\
            \\Results: one line per thing removed or not present. Exit 0 or 1.
            \\
            ,
            .examples = &.{ &.{ "integration", "uninstall", "codex" }, &.{ "integration", "uninstall", "claude", "--legacy" } },
        },
        .{
            .name = "status",
            .summary = "Report which hooks, files and skills are installed for an agent",
            .usage = "telar integration status claude|codex|pi|cursor|opencode [--settings PATH]",
            .text =
            \\Effects: reads the files; changes nothing.
            \\
            \\Results: for hook agents one `EVENT: installed|absent` line per event, then one per
            \\skill; for pi and opencode `telar extension|plugin: absent|installed|foreign at
            \\PATH` and the skills. A note names hooks left in a legacy file. Exit 0.
            \\
            ,
            .examples = &.{&.{ "integration", "status", "pi" }},
        },
    },
};
