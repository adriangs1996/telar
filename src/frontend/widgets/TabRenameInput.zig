const RectType = @import("telar-core").Rect;
const tab_rename = @import("tab_rename.zig");
const PromptType = @import("telar-client").Prompt;
const PathCompletionState = @import("telar-client").PathCompletionState;
const Input = @This();

area: RectType,
field: *tab_rename.Field,
kind: tab_rename.Kind,
/// The whole prompt, needed by the new-context form for its second field.
prompt: ?*const PromptType = null,
/// Landed directory completions of the new-context form.
path_completion: ?*const PathCompletionState = null,
