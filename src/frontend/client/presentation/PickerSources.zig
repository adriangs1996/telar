const data = @import("model");
const client = @import("telar-client");
const PickerSources = @This();

prompt: *data.Prompt,
agents: *const data.AgentSnapshot,
workspaces: *const data.WorkspaceListSnapshot,
/// The client model whose tabs the picker lists.
model: ?*const data.Model,
history: *const data.HistoryPaletteState,
suggestion: *const data.SuggestionState,
graphical_frame: bool,
