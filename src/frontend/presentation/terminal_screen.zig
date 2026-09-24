//! The TUI's screen: console's diffing screen over the protocol's pointer
//! shapes.
const console = @import("console");
const core = @import("telar-core");

pub const Screen = console.GenericScreen(core.PointerShape);
