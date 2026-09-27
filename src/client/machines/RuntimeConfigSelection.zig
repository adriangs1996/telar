const RuntimeConfigSelection = @This();

path: ?[*:0]const u8 = null,
disabled: bool = false,
profile: ?[*:0]const u8 = null,
/// Start the runtime with `--fresh`, and refuse to adopt a running one:
/// a fresh start that silently attaches to the old session is worse than
/// none.
fresh: bool = false,
