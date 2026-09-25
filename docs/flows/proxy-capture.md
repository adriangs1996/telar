# Proxy exchange capture

## Trigger

An intercepted HTTP/1.1 direction or HTTP/2 stream finishes, fails, or resets
while `runtime.proxy.capture.enabled` is true.

## Ownership path

1. `src/backend/proxy/tunnel/Http1Connection.zig` copies the original head
   bytes the relay hands its observer, and de-framed body fragments, into one
   request half and one response half.
   `tunnel/RelayContext.zig` does the same
   per stream using separate 128-slot direction tables. Relay writes complete
   before body fragments are observed.
2. `capture.Producer.publish` checks the pane credential and attempts a
   zero-deadline pointer transfer into the 256-entry capture queue. Failure
   erases and frees the half; it never waits for capacity.
3. `Sources.receiveProxyCapture` completes the runtime `Event.proxy_capture`.
   The dispatcher delegates to `proxy_capture.receive`, which rearms receive
   first.
4. The procedure rejects stale pane generations through `model.panes.resolve`,
   then asks `ProxyRuntime.decodeCapture` to decode a content-coded body on the
   observation path.
5. `ProxyRuntime.acceptCapture` pushes the half into `capture.Joiner`, which
   owns it until its peer arrives. Matching `(connection_id, stream_id)`
   halves form one exchange. `ProxyRuntime.expireCaptures`, run on each accept
   and on the agent maintenance tick, removes entries whose `join_timeout_ms`
   deadline elapsed as partial exchanges.
6. Complete and timed-out exchanges go to the runtime plugin service through
   `tap.submit` (see [Proxy tap](proxy-tap.md)). A half the joiner cannot
   hold, because the table is full or its side is a duplicate, returns as a
   partial exchange that is erased and released.

## Bounds and failure policy

Part, exchange, and global byte quotas are fixed by validated runtime config.
Allocation failure and quota exhaustion stop capture for the affected data but
do not stop forwarding. Decompression supports at most two reverse-ordered
codings and caps its output. Unknown or invalid encodings retain raw captured
bytes. Queue envelopes name the pane credential by its non-secret `CredentialId`,
checked against the registry at publication and delivery; the token never
enters the queue, and retained halves carry only pane ID and generation.

## Validation

Proxy tests cover split HTTP/1.1 chunked and content-length bodies, unchanged
wire output, interleaved HTTP/2 streams, capture under an unknown dialect,
mid-body truncation, queue saturation, credential revocation, gzip, Brotli and
zstd output caps, join completion, and timeout release. The disabled producer
test proves the default path reserves no capture memory.
