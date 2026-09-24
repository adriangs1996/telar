/// Identifies who asked the engine, so the runtime routes a reply without
/// keeping per-request state.
pub const EnginePurpose = union(enum) {
    suggestion: Suggestion,

    /// A client's command-suggestion request, answered to that exact
    /// client session.
    pub const Suggestion = struct {
        client_id: u64,
        client_generation: u64,
        request_id: u64,
    };
};
