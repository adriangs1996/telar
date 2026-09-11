const PickerSources = @This();
const name_prompt = @import("telar-client").model.name_prompt;
const agents_module = @import("telar-client").agents;
const source_namespace = @import("view.zig");
const history_palette_state = @import("telar-client").model.history_palette;
const suggestion_state = @import("telar-client").model.suggestion;
prompt: *name_prompt.Prompt,
agents: *const agents_module.Snapshot,
workspaces: *const source_namespace.workspace_list.Snapshot,
tabs: ?*const source_namespace.tabs_mod.Model,
history: *const history_palette_state.State,
suggestion: *const suggestion_state.State,
graphical_frame: bool,
