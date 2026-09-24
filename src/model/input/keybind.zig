//! telar's key binding defaults: the prefix, how long a lone Escape and a
//! partial sequence wait, and how many physical keys may be held at once.
const keyinput = @import("keyinput");
const std = @import("std");

pub const default_escape_timeout_ns: u64 = 25 * std.time.ns_per_ms;

pub const default_sequence_timeout_ns: u64 = 1000 * std.time.ns_per_ms;

pub const default_prefix = keyinput.chord.parseKey("ctrl+b") catch unreachable;

pub const max_physical_leases = 64;
