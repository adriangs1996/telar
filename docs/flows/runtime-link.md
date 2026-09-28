# Runtime link

A window reaches its machine's runtime by itself and keeps running when it
loses it. The link is connecting, connected, lost, failed or stopped; the chrome
shows it and pane input waits for it. Reconnecting starts a new session as a fresh
client would, so nothing from the lost session is replayed.

## End-to-end path

```text
GuiAdapter.start                        window on screen, host facts written
  client.bootstrap = { graphics, identity, colors }
  runtime_link.start                    link.phase = connecting
    to_background: runtime_connect
      runtime_link.runConnect           worker
        machine_connection.connect
          local:  RuntimeConnector.connectOrStart (starts the runtime)
          remote: remote.connect (discovery, ssh … telar server bridge)
        writes client.connect_result, or client.connect_report
  .runtime_connected
    runtime_link.finishConnect
      ok:   adopt: forget the previous session if any, bind the socket,
            launch defaults from discovery, push bootstrap, start IO
      fail: failure from the report, then
            machine_connection.permanent: link.phase = failed, no retry
            otherwise:                    link.phase = lost, schedule retry

runtime read or write fails
  runtime_io.receiveRuntime / completeRuntimeSend
    runtime_link.lose                   link.phase = lost
      failure: SSH's error output so far, or the error's name
      discard queued messages, shut the socket down, stop the SSH session,
      close the socket once no read or write uses it, schedule retry

.runtime_retry_tick
  runtime_link.retry                    link.phase = connecting, attempt + 1
    to_background: runtime_connect      (again)

the person picks a lost or failed machine in the machine list
  runtime_link.retryNow                 link.phase = connecting, attempt = 0
    to_background: runtime_connect

machine disabled or moved (machine-presentation.md)
  runtime_link.stop                     link.phase = stopped: no retry
  runtime_link.start                    after a move; an attempt still running
                                        is marked outdated, its result closed
                                        and a new attempt queued when it lands
```

## Rules

- **The window never waits.** Connecting runs on a worker; the window draws
  from the first frame. `LinkStatus` dims the workbench and says
  `Connecting to …`, `Reconnecting to … (attempt n)`, `… is unreachable` or
  `Cannot connect to …`, with SSH's error output or the runtime's refusal
  underneath.
- **Some failures wait for the person.** A host key or login SSH refuses,
  a `telar` the remote shell cannot find or run, discovery output this
  telar cannot read, another wire schema, a remote runtime of another
  build, `--fresh` beside a running runtime and an unsafe runtime directory
  (`machine_connection.permanent`) leave the link failed: no retry is
  scheduled, and the chrome shows why until the person picks the machine
  in the machine list, which calls `retryNow`. When the failure is one
  `telar machine setup` repairs (no telar there, or a telar or runtime of
  another build, `machine_connection.setupRepairs`), the link says so and
  picking the machine sets telar up there instead
  ([machine setup](machine-setup.md)). A lost connection is never
  permanent: once connected, every failure is retried.
- **Backoff.** The first retry waits half a second, then the wait doubles up
  to thirty seconds. A link that stayed up for a minute earns fast retries
  again. Retries never prompt: every SSH call runs in batch mode.
- **Nothing is replayed.** Queued messages are dropped when the link is lost,
  pane input is dropped while it is not connected, and the next session
  starts from the bootstrap. `runtime_session.forget` drops every replica and
  pending request of the lost session and keeps what the client owns:
  configuration, theme, host facts, bars, notifications and timers.
  Revisions advance rather than restart.
- **The socket closes when idle.** `lose` shuts the socket down, which makes a
  read or write still waiting on it return, and closes it only once neither
  is in flight, so a descriptor number is never reused under a job.
- **One attempt at a time.** `connect_pending` marks a running attempt. A
  start while it runs marks it outdated instead of queueing a second one;
  its connection is closed when it lands and the next attempt reads the
  current target. The attempt reads its destination from a copy the client
  wrote before queueing it, never from the machines table.
- **A new socket waits for the old one.** A connection that lands while the
  previous socket still has a read or write in flight is parked in
  `connect_result` and adopted when that socket closes, so the pending job
  never sees its socket replaced. `stop` and the client's teardown close a
  parked connection.
- **Stopped is not lost.** `stop` closes the socket once idle and stops the
  SSH session like a loss, but schedules nothing; only `start` connects again.
- **Pane resources go through the canonical release.** Before forgetting a
  session, each pane passes through `pane_closure.releasePaneResources`, so
  graphics, copy mode, paste and reported focus stop naming it.
- **Same identity, same layout.** Every session presents the same client
  identity, so the runtime restores the layout it kept for this window.
- **`--fresh` applies once.** The first session sets the previous one aside;
  a reconnect adopts the runtime that session started.
- **A client handed its socket cannot reconnect.** Tests hand one in; it
  ends when that socket is lost.
- **An explicit stop ends the window.** `telar server stop` tells clients the
  runtime is stopping, and they exit as before; only a lost socket
  reconnects.

## Validation

- `src/client/connection/runtime_link.zig` tests a full cycle over real
  socketpairs: connect, bootstrap, a failed read and write, idle close, the
  retry timer, a second session that forgets the first, and a failed attempt
  that shows its report and waits.
- `src/gui/tests/machines.zig` tests that a moved machine drops the result
  of the attempt that was running and reaches the new destination next.
- `src/model/connection/runtime_session.zig` tests what a forgotten session
  drops and keeps, and that revisions advance.
- `src/model/connection/RuntimeLink.zig` tests bounded, one-line failures.
- `src/model/connection/outbox_support.zig` tests discarding everything but
  the message being written.
- `src/gui/widgets/LinkStatus.zig` tests the headlines; the widget
  composition tests include it as an optional layer.
- `src/client/connection/runtime_link.zig` tests that a permanent failure
  leaves the link failed with its report and no retry timer, and that
  retrying now connects it again; `src/client/machines/remote.zig` tests
  which SSH failures are permanent.
- Against two Debian boxes built from this tree and one with an older
  telar (September 2026, macOS OpenSSH 10.3p1 client): an unknown host key,
  a changed host key, a refused key, `telar` missing from the remote PATH,
  another wire schema, an older `telar` and a remote runtime of another
  build each left the link failed with its cause in the headless dump, and
  a window holding that machine made exactly one ssh call to it in 45
  seconds. A stopped box was retried 0.5, 1, 2, 4, 8, 16 and 30 seconds
  apart. Cutting a box's network under a connected client lost the link 22
  seconds later (keepalives), retried 1, 2, 4, 8, 16, 30, 30 and 30 seconds
  apart, and reattached on the first attempt after the network returned.
- Not verified against a real window: choosing a failed machine in the
  machine list, because this session cannot drive the window's input.
- Earlier, against the Linux SSH box (`tools/local-docker`), with a GUI
  window on `--remote telar-docker` and the old `ssh -L` forward:
  - killing the local `ssh` forward: the window stays, opens a new forward
    and reattaches with the same identity within two seconds;
  - SIGKILL of the remote runtime: the retry's discovery starts it again and
    the window reattaches within two seconds;
  - stopping the container for 12 seconds: the window stays and reattaches
    three seconds after the machine returns;
  - SIGKILL of the window: its forward exits within a second.
- Not verified here: the drawn `LinkStatus` overlay, because this session
  cannot capture the window (macOS screen recording permission).
