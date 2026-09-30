/// The end of one connection's handshake: the admission slot it borrowed and
/// whether negotiation succeeded.
const HandshakeCompletion = @This();

slot: usize,
result: anyerror!void,
