//! The frame that stopped at a limit: what it would show and the viewport
//! it was measured for. The window does not prepare it again until one of
//! them changes.
const client = @import("telar-client");
const native = @import("native/native.zig");

observation: client.Observation,
viewport: native.Viewport,
