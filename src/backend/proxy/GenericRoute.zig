pub fn Type(comptime Session: type) type {
    return union(enum) {
        passthrough,
        http11: Session,
        h2: Session,
    };
}
