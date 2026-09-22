const core = @import("telar-core");
const data = @import("model");
const tab_rename = @import("tab_rename.zig");
const Input = @This();

area: core.Rect,
field: *tab_rename.Field,
kind: tab_rename.Kind,
/// The whole prompt, needed by the new-context form for its second field.
prompt: ?*const data.Prompt = null,
/// Landed directory completions of the new-context form.
path_completion: ?*const data.PathCompletionState = null,
