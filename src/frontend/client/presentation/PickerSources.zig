const data = @import("model");
const client = @import("telar-client");
const PickerSources = @This();

prompt: *data.Prompt,
agents: *const client.AgentSnapshot,
workspaces: *const client.WorkspaceListSnapshot,
tabs: ?*const client.TabsModel,
history: *const client.HistoryPaletteState,
suggestion: *const client.SuggestionState,
graphical_frame: bool,
