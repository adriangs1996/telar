# Headless client

`telar-headless` runs the shared client with no window, for tests and tools.
It attaches to a runtime like `telar gui`, takes semantic input on stdin,
presents and acknowledges every frame the moment it is ready, and writes what
it saw as JSON once, when it exits. It is built by `zig build headless` and is
not part of `zig build`, the bundle or the packages.

## End-to-end path

```text
telar-headless --size 120x40 --trace t.json --dump d.json --no-config -- cat
        |
HeadlessOptions.parse                 --size, --trace, --dump come first
RunOptions.parse + ClientLaunch       the same options and launch as telar gui
        |                             local: machine = .local, started through
        |                             the telar beside this binary
        |                             --remote: machine = .remote (one machine)
HeadlessClient.init                   Client, keymap router, trace ring
HeadlessClient.run
  start                               host facts from --size, bootstrap,
                                      runtime_link.start, configuration watch
  loop: inbox.wait, update
    .client message                   Client.update; a server message may end
                                      startup (client_startup.finish)
    .input line                       one stdin line (input_protocol.parse)
      key / text                      presses through the keymap router, then
                                      key_routing or a bound action
      resize                          host_resize.applyHostUpdate
      mark                            a labelled timestamp in the trace
      quit or end of stdin            exit 0
    present                           capture, begin, complete as delivered,
                                      presentation_delivery.apply (frame acks)
    deliverEffects                    host requests recorded, jobs started
    link failed (runtime-link.md)     exit 1: nobody here can retry it
  writeReports                        --trace and --dump, after the loop
```

## Protocol

One command per line on stdin:

| Line | Effect |
| --- | --- |
| `key NAME` | one key or chord, pressed: `a`, `enter`, `ctrl+c`, `alt+x`, `shift+tab`, `up` |
| `text UTF-8` | each character pressed in order |
| `resize COLSxROWS` | the host grid changes |
| `mark LABEL` | a labelled timestamp in the trace |
| `notification activate` | the newest notification is clicked, as its card in a window would be |
| `quit` | leave with status 0; the end of stdin does the same |

It is not a terminal escape parser. Keys are delivered as presses only, as
a terminal delivers them, so a prefix binding followed by its key works as
in a window. The client writes `ready` on stdout once it first admits input
(connected, first tab open, startup over); tools wait for that line before
they send what they measure.

## Reports

- `--trace PATH`: a ring of 65,536 entries, oldest first, with how many it
  dropped. An entry is a delivered pane frame (`pane`, `frame`), an input
  line (`label` key/text/resize and the focused `pane`), a mark, or a host
  request. Times are the client's monotonic clock in nanoseconds. Recording
  never allocates or formats; the JSON is written once at exit.
- `--dump PATH`: the link state and its failure text, the tabs, the active tab's panes with their
  visible rows as text, the workspace list and the notifications, from the
  client model when it exits.

`--client ID` commands (`layout get`, `sidebar get`, `pane copy`, plugins,
configuration) work as for a window: the shared client answers them.

Echo latency tools take the time from an input entry to the first frame of
the same pane after it. That ends where the client has the frame, not where a
host terminal shows it.

## Rules

- **No window, no host.** Clipboard, notifications, links and machine
  requests are recorded in the trace and not performed; a clipboard capture
  fails as unavailable. Opening a link, playing a sound and posting a desktop
  notice are background jobs the client queues like a window's; the headless
  client records each as an `effect` entry named `link`, `sound` or
  `system_notification` and completes it without running anything
  (`HeadlessClient.recordedInstead`), so no `open`, `xdg-open` or sound
  player ever starts. Graphics commands are accepted and dropped.
- **Nothing on the measured path.** The trace and dump are written after the
  loop ends. The echo trace marks (`host_read`, `client_input`,
  `compose_start`, `host_flush_*`) follow a window's, so
  `tools/echo_trace.py` reads a headless run.
- **Input waits for the runtime.** A line is read only after startup and
  while the runtime outbox keeps room for what it may send.
- **The runtime and plugin workers come from `telar`.** This binary has
  neither; it names the `telar` beside it (`Options.telar_executable`,
  `RuntimeConfigSelection.executable`).

## Validation

- `src/headless` tests the protocol, the options and the trace ring
  (`zig build test-headless`).
- `tools/client_smoke.py`, `tools/test_cli_live.py`,
  `tools/test_review_runtime.py` and `tools/remote_smoke.py` run the client
  against real runtimes, the last over SSH to the Linux box.
- `tools/latency_bench.sh`, `tools/load_bench.sh`, `tools/echo_path.py` and
  `tools/perf_e2e.py` measure through it; `tools/echo_trace.py` summarises a
  traced run.
