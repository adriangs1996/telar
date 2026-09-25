//! The non-secret identity of one registered credential: the pane generation
//! it serves and the registration serial that tells it apart from every
//! other credential, past or present. Tunnels and queues carry this once a
//! token is authenticated, so no connection or ring slot holds the secret.
const core = @import("telar-core");
const CredentialId = @This();

pane_id: core.PaneId,
pane_generation: u64,
serial: u64,
