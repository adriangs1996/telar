const id = @import("schema/id.zig");
const ClientDescriptor = @import("ClientDescriptor.zig");

/// Client sessions the runtime holds at once: windows, headless clients,
/// CLI calls and agent hooks alike.
pub const capacity = 32;
request_id: id.RequestId,
// SAFETY: Runtime collection and wire decoding fill entries[0..count] before exposing the list; encoding reads only that prefix.
entries: [capacity]ClientDescriptor = undefined,
count: u8 = 0,
