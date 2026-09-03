# Proxy exchange capture

## Trigger

An intercepted HTTP/1.1 direction or HTTP/2 stream finishes, fails, or resets
while `runtime.proxy.capture.enabled` is true.

## Ownership path

1. `tunnel/http1.zig` copies original head bytes and de-framed body fragments
   into one request half and one response half. `tunnel/h2.zig` does the same
   per stream using separate 128-slot direction tables. Relay writes complete
   before body fragments are observed.
2. `capture.Producer.publish` checks the pane credential and attempts a
   zero-deadline pointer transfer into the 256-entry capture queue. Failure
   erases and frees the half; it never waits for capacity.
3. `event_sources.Sources.receiveProxyCapture` completes
   `RuntimeEvent.proxy_capture`. The dispatcher delegates to
   `entrypoints/events/proxy_capture.handle`, which rearms receive first.
4. The entrypoint rejects stale pane generations, then asks the proxy resource
   to decode a content-coded body on the observation path.
5. `capture.Joiner` owns the half until its peer arrives. Matching
   `(connection_id, stream_id)` halves form one exchange. The agent maintenance
   tick releases entries whose `join_timeout_ms` deadline elapsed as partial
   exchanges.
6. The phase-1 sink records no payload: it erases and releases complete and
   partial exchanges. A later runtime plugin service replaces this sink.

## Bounds and failure policy

Part, exchange, and global byte quotas are fixed by validated runtime config.
Allocation failure and quota exhaustion stop capture for the affected data but
do not stop forwarding. Decompression supports at most two reverse-ordered
codings and caps its output. Unknown or invalid encodings retain raw captured
bytes. The pane token exists only in the queue envelope and is erased after
publication or delivery; retained halves carry only pane ID and generation.

## Proof

Proxy tests cover split HTTP/1.1 chunked and content-length bodies, unchanged
wire output, interleaved HTTP/2 streams, capture under an unknown dialect,
mid-body truncation, queue saturation, credential revocation, gzip, Brotli and
zstd output caps, join completion, and timeout release. The disabled producer
test proves the default path reserves no capture memory.
