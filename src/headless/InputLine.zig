//! One line of the headless client's stdin protocol, parsed and owned.
const keyinput = @import("keyinput");
const InputText = @import("InputText.zig");
const InputLabel = @import("InputLabel.zig");
const InputSize = @import("InputSize.zig");

pub const InputLine = union(enum) {
    /// A key or chord, pressed.
    key: keyinput.Key,
    /// Characters typed one after another.
    text: InputText,
    /// The host grid changes size.
    resize: InputSize,
    /// A point in time the trace records under a label.
    mark: InputLabel,
    /// The newest notification is clicked, as a window's card would be.
    notification_activate,
    /// The client leaves with status 0.
    quit,
};
