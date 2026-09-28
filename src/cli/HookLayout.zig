/// How an agent's settings file lists the commands of one hook event.
pub const HookLayout = enum {
    /// Claude Code and Codex: `hooks.<event>[] = { hooks: [{ type, command, timeout }] }`.
    nested,
    /// Cursor Agent: `hooks.<event>[] = { command, timeout }` beside `version: 1`.
    flat,
};
