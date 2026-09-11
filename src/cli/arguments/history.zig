//! History command grammar and validated options.

pub const HistoryAction = enum {
    import,
    delete,
    prune,
    show,
    stats,
    list,
    search,
};

pub const HistoryImportKind = enum { auto, zsh, bash, fish };
