//! Independent limits keep terminal metadata out of the cell payload budget.
pub const max_links = 256;
pub const max_runs = 2048;
pub const max_uri_bytes = 4096;
pub const max_total_uri_bytes = 64 * 1024;
pub const header_size = 11;
pub const link_size = 6;
pub const run_size = 10;
pub const max_encoded_size = capacity(65535);

/// `partial` keeps the links that fit and leaves the rest of the cells
/// unlinked; `omitted` carries no link at all.
pub const Status = enum(u8) { complete, omitted, partial };

pub fn capacity(rows: u16) usize {
    return header_size + @as(usize, rows) + max_links * link_size + max_runs * run_size + max_total_uri_bytes;
}
