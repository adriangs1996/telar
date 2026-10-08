---
status: accepted
---

# Run the proxy as an independent Go component of Telar

Telar's proxy will run as a local Go service, shipped with Telar and controlled
through its GUI and CLI over IPC. Its lifetime and machine-level network
integration must be independent of the terminal runtime, so proxy activation
can change without terminating panes and connections can originate outside
Telar. Go's networking and concurrency facilities motivate the language choice;
the migration must verify the existing relay and capture behavior and measure
latency and memory rather than assume equivalent performance.

The terminal runtime remains in Zig. Native network adapters supply traffic to
the service; the runtime receives state and authorized captures. This replaces
runtime ownership of the proxy and requires a separate local protocol and
release component. See the [migration plan](../proxy-service.md).
