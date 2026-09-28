/// What the person asked of the window's machines: the next or previous
/// one, one the machine picker chose, that `--remote` or `--machine` stop
/// keeping one open because the picker disabled it, or that telar be set
/// up on one the window cannot reach for want of it. The window
/// resolves it against its machines; a host that holds one machine ignores
/// it.
pub const MachineRequest = union(enum) {
    offset: i8,
    slot: u8,
    unpin: u8,
    setup: u8,
};
