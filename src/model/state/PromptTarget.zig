const core = @import("telar-core");
const AgentKey = @import("../agents/AgentKey.zig");
const copy_mode = @import("../input/copy_mode.zig");
const MachinePrompt = @import("MachinePrompt.zig").MachinePrompt;

pub const PromptTarget = union(enum) {
    rename_tab: core.TabId,
    create_workspace,
    rename_workspace: core.WorkspaceLocation,
    /// Copy-mode search input; the direction was chosen by `/` or `?`.
    copy_search: copy_mode.Direction,
    /// Fuzzy goto picker over workspaces, tabs and agents.
    goto,
    /// History palette; results live in the history-palette model state.
    history,
    /// Command-suggestion palette; the reply lives in the suggestion model
    /// state and Enter asks or pastes depending on it.
    suggest,
    /// One field whose first byte selects actions (`>`), the goto picker
    /// (`@`) or the suggestion engine (`?`); see `command_palette`.
    palette,
    /// A peek at one agent: its task, plan, screen and a message field.
    peek: AgentKey,
    /// Path picker; the root and results live in the path-picker model state.
    paths,
    /// Renames or adds one of the window's machines.
    machine: MachinePrompt,
    /// The options of a configured pick; they live in the pick-list model
    /// state and Enter runs the pick's `on_select`.
    pick,
};
