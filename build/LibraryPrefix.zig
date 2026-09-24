//! Where a system library a library links is installed, when it is not on
//! the default search path.

/// The name passed to `linkSystemLibrary`.
library: []const u8,
/// The prefix holding `include/` and `lib/`.
path: []const u8,
