//! What one probe of an agent session file found.
const TitleProbe = @This();

/// Where the next probe starts; null leaves the caller's offset unchanged.
offset: ?u64 = null,
/// The session's current name, borrowed from the caller's buffer. Empty
/// means the name was cleared.
title: ?[]const u8 = null,
