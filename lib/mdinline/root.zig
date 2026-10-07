//! Inline Markdown over borrowed text: strong, emphasis, code and links as
//! styled spans that keep their link destination and source offset, bare
//! URLs recognized like a terminal recognizes them, and bounded decoding of
//! a link destination for display. Unsupported syntax stays literal, and
//! lookahead is budgeted linearly in the text.
