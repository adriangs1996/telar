const StoredEdition = @import("StoredEdition.zig");
const ArchiveRecord = @import("ArchiveRecord.zig");
version: u8,
records: []const ArchiveRecord,
editions: []const StoredEdition,
