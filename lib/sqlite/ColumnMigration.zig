//! A column added to an existing table when an older database lacks it.

table: []const u8,
column: []const u8,
alter_sql: [:0]const u8,
