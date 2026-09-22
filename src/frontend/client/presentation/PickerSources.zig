const data = @import("model");
const client = @import("telar-client");
const PickerSources = @This();

prompt: *data.Prompt,
agents: *const data.AgentSnapshot,
workspaces: *const data.WorkspaceListSnapshot,
tabs: ?*const data.TabsModel,
history: *const data.HistoryPaletteState,
suggestion: *const data.SuggestionState,
graphical_frame: bool,
