pub const RequestFailureOutcome = enum {
    ignored,
    recovered,
    notified,
    fatal,
};
