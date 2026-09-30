/// Where an agent's interactive session, and so the hooks it fires, runs,
/// as its process arguments tell. Only an agent with a
/// `pane_session_argument` capability can say.
pub const SessionHost = enum {
    /// The arguments do not say: an agent without the capability, a
    /// subcommand that runs no interactive session, or arguments not read.
    unknown,
    /// The session runs in the agent's own process, inside the pane.
    pane,
    /// An interactive session started without the argument: it may run in a
    /// shared server outside the pane, whose hooks cannot report here.
    shared_server,
};
