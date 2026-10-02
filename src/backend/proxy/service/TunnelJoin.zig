//! Whether every tunnel returned before a stopping service gave up waiting
//! for them.
pub const TunnelJoin = enum {
    /// Every tunnel returned; the service may be destroyed.
    joined,
    /// A tunnel was still running at the deadline and still uses the
    /// service, which must outlive it.
    abandoned,
};
