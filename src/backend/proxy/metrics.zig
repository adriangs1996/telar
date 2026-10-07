//! Lock-free counters owned by the proxy service.

pub const Counter = enum {
    rejected_connection,
    invalid_authorization_rejection,
    unknown_credential_rejection,
    h2_decode_failure,
    passthrough_connection,
    /// A tunnel admitted without credentials (`runtime.proxy.anonymous_tunnels`).
    anonymous_tunnel,
    upstream_connect_failure,
    tls_context_failure,
    tls_upstream_handshake_failure,
    tls_downstream_handshake_failure,
    tls_mint_failure,
    /// An HTTP/2 stream relayed without capture: every capture slot was taken.
    h2_capture_stream_skipped,
    /// An HTTP/1.1 head longer than `http1.max_head_bytes`.
    http1_head_too_large,
    /// A chunk-size line longer than `http1.max_chunk_line_bytes`.
    http1_chunk_line_too_long,
    /// A trailer line longer than `http1.max_trailer_line_bytes`.
    http1_trailer_line_too_long,
    /// A CONNECT head longer than `proxy.max_connect_head_bytes`.
    connect_head_too_large,
    /// A connection that sent no complete CONNECT head in time.
    connect_head_timeout,
    /// A connection that did not reach its origin and finish TLS in time.
    establish_timeout,
    /// A connection closed to make room for a new one.
    eviction,
    /// A connection refused because `max_unauthenticated` connections were
    /// still sending their CONNECT head.
    unauthenticated_refusal,
    /// A connection still sending its CONNECT head closed at
    /// `max_unauthenticated` to admit a new one.
    unauthenticated_eviction,
    /// An HTTP/2 header block past `max_header_block_bytes`, which ends
    /// decoding of its direction.
    h2_header_block_too_large,
    /// An HTTP/2 stream the relay could not follow past its tracked streams.
    h2_stream_untracked,
    /// A CONNECT refused because `max_resolutions` other host names were
    /// resolving.
    resolution_refusal,
    /// A connection whose host has more addresses than
    /// `max_resolved_addresses`; the rest are not tried.
    resolution_truncated,
};
