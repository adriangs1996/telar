/// What the person asked of the window's machines: the next or previous
/// one, or one the machine picker chose. The window resolves it against
/// its machines; a host that holds one machine ignores it.
pub const MachineRequest = union(enum) {
    offset: i8,
    slot: u8,
};
