/// Explicit per-session graphics capability. `shared` declares that this
/// client shares the runtime's machine and can map POSIX shared memory the
/// runtime names; the runtime never assumes it. Sent before the first pane
/// attaches, and the setting applies to attachments created afterwards.
const ConfigureGraphics = @This();

shared: bool,

pub fn validateWire(message: ConfigureGraphics) !void {
    _ = message;
}
