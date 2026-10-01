//! A long text or paste held whole in the input queue's large pool and
//! delivered a scalar or a chunk per step, so its length never depends on
//! how many ring entries are free.
const HeldText = @This();

/// The large pool slot holding the bytes.
slot: u8,
/// Bytes already delivered.
offset: u32 = 0,
/// A held paste has sent its start marker.
started: bool = false,
