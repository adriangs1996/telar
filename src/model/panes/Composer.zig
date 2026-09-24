//! What the user writes for the agent in a pane: the draft text and its
//! image attachments. A pane allocates it on first use, so terminal panes
//! carry only a null pointer.
const textfield = @import("textfield");
const core = @import("telar-core");
const GenericField = textfield.GenericField;
const Composer = @This();

pub const max_bytes = 4096;
pub const Field = GenericField(max_bytes);

field: Field = .{},
images: core.AgentImages = .{},
