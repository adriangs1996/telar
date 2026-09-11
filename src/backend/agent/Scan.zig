const Scan = @This();

/// Bytes fully handled: up to and including the last newline, so a
/// partial trailing line is read again once complete.
consumed: usize,
/// The last name written for the session, copied into the caller's
/// buffer and cut to the title bound. Empty means the name was cleared.
title: ?[]const u8,
