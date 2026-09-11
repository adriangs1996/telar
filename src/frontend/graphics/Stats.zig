const Stats = @This();

/// Images handed to the host as a shared-memory name.
shared_images: u64 = 0,
/// Images whose inline transmission closed, compressed or raw.
inline_images: u64 = 0,
/// The subset of `inline_images` that shipped as a zlib stream.
compressed_images: u64 = 0,
/// Chunk-emission calls; divided by `inline_images` this is the
/// passes-per-image pacing the budget policy produces.
transmission_passes: u64 = 0,
/// Passes that advanced a deflate by at least one slice.
compress_passes: u64 = 0,
