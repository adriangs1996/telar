//! Bounded JSON-lines streams from a child process: whole records up to a
//! line bound, oversized output fields truncated in place without breaking
//! the JSON, and total accessors over parsed values.
