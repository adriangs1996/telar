//! Bounds for encoded and synthetic pane input.

pub const max_encoded_bytes: usize = 8 * 1024;
/// One synthetic key can encode at most this many bytes.
pub const max_bytes_per_key: usize = 32;
pub const max_synthetic_keys: usize = max_encoded_bytes / max_bytes_per_key;
