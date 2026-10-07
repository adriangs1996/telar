title: [*:0]const u8,
/// Borrowed wake-pipe read end. The window consumes its notification bytes; the
/// caller keeps both ends open and supplies no other reader until teardown.
wake_fd: c_int,
