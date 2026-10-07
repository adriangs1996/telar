/// The end of one connection's handshake: the admission slot it borrowed and
/// whether negotiation succeeded.
slot: usize,
result: anyerror!void,
