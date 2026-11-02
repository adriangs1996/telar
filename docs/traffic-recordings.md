# Runtime traffic recordings

`telar.traffic.recordings` retains bounded packet, datagram, flow and completed HTTP events
inside the C++ runtime. Closing Desktop does not stop a recording. A new client
can list its sessions and resume reading by cursor. Recordings are held in memory;
stopping or crashing the runtime loses them. Export files are written explicitly
by the client application.

## Lua API

```lua
local traffic = require("telar.traffic")
local fs = require("telar.fs")

traffic.recordings.start({
  max_bytes = 8 * 1024 * 1024,
  max_events = 4096,
  max_age_ms = 60000,
  events = {packet = true, flow = true, exchange = true},
  filter = "tcp port 443", -- BPF applies to packet events.
}, function(err, reply)
  assert(not err, err)
  assert(reply.result == "ok", reply.message)
  local id = reply.recording.id

  traffic.recordings.query({id = id, cursor = "0", limit = 64}, function(err, reply)
    assert(not err, err)
    assert(reply.result == "ok", reply.message)
    local page = reply.recording
    for _, event in ipairs(page.events) do
      -- Same binary event DTO as traffic.subscribe, plus recording_cursor.
    end
    -- Resume from page.next_cursor; a gap means earlier rows expired/evicted.
  end)

  traffic.recordings.stop({id = id}, function(err, reply)
    assert(not err, err)
    assert(reply.result == "ok", reply.message)
    traffic.recordings.export({id = id}, function(err, reply)
      assert(not err, err)
      assert(reply.result == "ok", reply.message)
      fs.write_file("capture.pcapng", reply.recording.pcapng, function(err)
        assert(not err, err)
      end)
    end)
  end)
end)

traffic.recordings.list(function(err, reply)
  assert(not err, err)
  assert(reply.result == "ok", reply.message)
  for _, recording in ipairs(reply.recordings) do
    -- recording.id, active, retained_bytes and retention/loss counters.
  end
end)

-- Explicitly release a stopped recording's reserved capacity and identity:
-- traffic.recordings.remove({id = id}, callback)
```

All operations return cancellation functions. Transport failures arrive as `err`;
native failures use the existing control reply's `result` and `message`. An
accepted start survives cancellation of its reply; `list` can recover its ID.
An unknown, removed or previous-runtime ID fails rather than naming a new session.

Recording requires `network_capture`; it does not require `network_control` or
sudo. It records events already available to the account. It does not activate
packet capture or redirection. Completed HTTP bodies still require configured
proxy capture, and TLS plaintext requires successful active inspection. The
Desktop API uses the existing authenticated control channel. [Persistent package
workers](traffic-workers.md) use the same API with `traffic.record`; their native
identity restricts every operation to their own ID/digest's recordings. The trusted
account-level Desktop client can list and manage all recordings in that runtime.

## Retention, queries and loss

| Setting | Default | Bound |
| --- | --- | --- |
| `max_bytes` | 8 MiB | 64 MiB per session; 128 MiB reserved per runtime |
| `max_events` | 4096 | 4096 per session |
| `max_age_ms` | 60000 | 1 through 3600000 |
| Sessions | — | Four active or stopped sessions |
| Query/export `limit` | 64 | 128 rows and a 512 KiB page |

The byte budget includes the reserved event index and encoded event bytes.
Choose an event limit whose index fits the byte budget. A full recording evicts
its oldest rows; age is measured with the runtime's monotonic clock, independently
of timestamps supplied by capture sources. An individually oversized event is
dropped and counted. Stopped sessions retain their remaining rows until expiry
or removal, and keep their reserved runtime capacity until removal.

`events` selects packet, datagram, flow and/or exchange events. `filter` is a creation-time
BPF packet filter. `host` at creation or query time applies the existing exact or
wildcard host policy to flow and HTTP events. Packets and datagrams do not acquire an inferred
domain and do not match a semantic host scope. Queries can additionally narrow
`events`; they never alter the recording's creation-time selection.

IDs and cursors are decimal strings, preserving all 64 bits through LuaJIT.
Cursor `"0"` begins at the oldest retained event. `oldest_cursor` identifies that
row, `next_cursor` resumes the scan and `end_cursor` is its current upper bound.
`gap` reports a nonzero requested cursor that has fallen behind retention.
Filtering advances the cursor across excluded rows. Each page is consistent;
an active recording may gain rows between pages.

`evicted` counts age/count/byte retention removals. `dropped` counts recording
allocation, filter and oversized-event failures. `contention_drops` is a
runtime-wide count of recording attempts skipped while a query owns the store;
it is not an exact per-filter loss count. Capture and runtime delivery can lose
events before retention. Existing per-event counters are preserved; live capture
statistics remain available through subscriptions and are not archived as rows.
Packet rows do preserve the helper's latest kernel-loss snapshot, including
counts retained from interfaces that closed earlier in that capture session.
Recording counters therefore do not measure all upstream packet loss.
Queries never make forwarding wait for a Lua callback. Recording insertion uses
a nonblocking lock and reports contention rather than stalling the packet worker.
Recordings and live subscribers share immutable encoded frames.

Only public packet/datagram/flow/completed-exchange observations are retained. Pending
interception tickets remain private to their controller. Events preserve source
session, interface, wire/plaintext visibility and flow/exchange identities. Proxy
flow IDs match the corresponding HTTP connection IDs; passive capture flows
remain separate observations.

## Export

`export` takes `id`, `cursor` and `limit`, and returns the same cursor/loss
metadata plus binary `recording.pcapng`. It exports packets, preserving link type,
interface name, microsecond timestamp, captured length and original wire length.
Each page starts a complete PCAPNG section; concatenate page bytes in cursor
order for a larger file. Datagram, flow/plaintext and HTTP events remain available through
`query` and are not synthesized into packets.

Stop a recording before exporting a fixed set. Continue while `next_cursor`
differs from `end_cursor`, check `gap` and loss counters, and allow enough retention
age for the export. Applications choose the destination and any structured HTTP
export format through their ordinary filesystem API.

## Verification

```sh
cmake --build services/runtime-cpp/out --target traffic-recording-tests
ctest --test-dir services/runtime-cpp/out -R '^traffic-recording-tests$' --output-on-failure
python3 services/runtime-cpp/tools/check_traffic_recordings.py \
  --runtime services/runtime-cpp/out/telar-runtime \
  --lua-probe services/desktop-mode/out/debug/traffic_dbg
```

Unit checks cover count/byte/age retention, gaps, pagination, binary payloads,
host scopes, stop/delete and reading exported PCAPNG through libpcap. The actual
runtime/Desktop check verifies recording without a connected client, reconnect
and listing, BPF selection, eviction, binary pages, stale IDs, a PCAPNG
export/import round trip and correlated HTTP/flow retention through real TCP.
It also starts a datagram-only recording, closes Desktop, imports UDP/ICMP/ICMPv6
traffic with fragmented IPv6 messages, then reconnects and verifies the retained
structured messages. No live datagram subscriber is present during that import.
