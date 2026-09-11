const PromptType = @import("telar-client").Prompt;
const SnapshotType = @import("telar-client").AgentSnapshot;
const WorkspaceListSnapshot = @import("telar-client").WorkspaceListSnapshot;
const TabsModel = @import("telar-client").TabsModel;
const HistoryPaletteState = @import("telar-client").HistoryPaletteState;
const SuggestionState = @import("telar-client").SuggestionState;
const PickerSources = @This();

prompt: *PromptType,
agents: *const SnapshotType,
workspaces: *const WorkspaceListSnapshot,
tabs: ?*const TabsModel,
history: *const HistoryPaletteState,
suggestion: *const SuggestionState,
graphical_frame: bool,
