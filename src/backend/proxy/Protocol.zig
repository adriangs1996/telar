//! The wire protocol one intercepted CONNECT exchange travelled over, as
//! capture records it.
pub const Protocol = enum { http11, h2, upgraded };
