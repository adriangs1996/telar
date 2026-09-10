# Shared application, input and connection resources

The TUI now calls the application handlers exported by `telar-client`. Their
existing effect ports and delivery ordering are unchanged. Model commits,
request policy, configuration callback values, selection/link gestures,
attachment markers, outbox admission, request tracking and runtime transport
state have one implementation outside the TUI.

The binding engine receives a decoder type at assembly. Terminal byte decoding
stays in `telar-frontend`; `routeEvent` accepts owned semantic keys without a
decoder. Child-mode encoding is shared. Parser/encoding integration tests stay
with the TUI, while independent encoding tests moved with the implementation.
The decoded runtime-message dispatcher is shared and receives slice adapters;
concrete effects, workers and the existing event driver remain in the TUI.

Validation:

- 751 shared-client and 711 frontend tests pass in ReleaseSafe.
- The shared suite also passes in Debug.
- Tests exercise direct routing with no decoder and compare it with fragmented
  terminal input, including binding mismatch replay and physical ownership.
- Runtime dispatch can run without initializing host resources. Dispatch-capture
  tests check the boundary; existing handler tests check actual model changes
  and effect ordering. These are not yet the phase-5 headless presentation test.
- Semantic analysis, the diagnostics-enabled ReleaseFast build and shared-client
  codestyle pass. Logs are retained here.

No event scheduler, worker pool, IPC message or CLI change is included. This
phase does not claim performance acceptance; paired measurements remain pending.
