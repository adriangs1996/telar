# telar-remote

What `telar-gateway` is made of: the connection between telar on two machines,
the files that keep who may connect, and the two processes at its ends. It is
C++23 with compiled standard module interfaces and depends on `telar::tls` for
OpenSSL, `telar::platform` and `telar::base`. Only
[`src/gateway`](../../src/gateway/README.md) links it; the runtime, the CLI and
the GUI start that program and never speak TLS themselves.

```cmake
target_link_libraries(your_target PRIVATE telar::remote)
```

| Module | What it hides |
| --- | --- |
| `telar.remote.identity` | The address `telar://HOST:PORT#KEY[.CODE]`, an account's key, the clients a gateway admits and the pairing codes, all under one private state directory. |
| `telar.remote.channel` | TLS 1.3 with a key at each end, the service named in the handshake, the relay between a channel and a socket, and the notices of the ports service. |
| `telar.remote.streams` | A command's stdin, stdout, stderr and exit status over one channel. |
| `telar.remote.serve` | The gateway that answers: the listener, the admission of each client and the five services. |
| `telar.remote.link` | The gateway that calls: the link that offers a machine's runtime on a local socket and its ports on local ports, and the one-shot commands. |

## The connection

TCP, then TLS 1.3 and nothing older. Each end presents a self-signed
certificate over a P-256 key it made itself, and neither follows a chain: an
end is named by the SHA-256 of its public key. The client refuses a gateway
whose key is not the one in the address it dialed; the gateway refuses, before
reading any request, a client whose key is not in `authorized_clients`, unless
the client asks to pair. Session tickets are off, so every connection is a
full handshake and a revoked client is refused at once.

The client names the service it wants as the ALPN protocol of the handshake.
After the handshake each service starts the same way, with what the client
sends, if anything, and one byte back: `0` accepted, `1` refused, `2`
unavailable.

| ALPN | Client sends | Then |
| --- | --- | --- |
| `telar-attach/1` | nothing | The bytes of the account's runtime socket, both ways. The gateway starts the runtime with `telar server endpoint` when none listens. |
| `telar-run/1` | `flags u8` (bit 0: a terminal), `rows u16`, `columns u16`, `length u32`, the command line | Frames `kind u8, stream u8, length u16, payload`: kind 0 carries bytes of stream 0 (stdin), 1 (stdout) or 2 (stderr), kind 1 ends a stream, kind 2 carries the exit status as `u32`. The gateway runs the line with the account's shell, `SHELL -c LINE`. |
| `telar-forward/1` | `port u16` | The bytes of a TCP connection to that port of the gateway's own loopback, both ways. Refused when nothing listens there. |
| `telar-ports/1` | nothing | Notices `kind u8, port u16, length u8, origin`: the client asks to `watch` (1) or `unwatch` (2) a port; the gateway says a port is `shared` (3) by a program there, and that a watched or shared port `closed` (4). |
| `telar-pair/1` | the 16 bytes of a pairing code, `length u8`, the client's name | The reply alone. An accepted code is spent and the client's key joins `authorized_clients`. |

Integers are big-endian. A relay passes on the end of each direction: a side
that stops sending leaves the other free to finish.

A client of `telar-attach/1` and `telar-forward/1` does not wait for the reply
byte before it sends: its first bytes travel with the last flight of the
handshake, and the reply comes back ahead of the service's own bytes. A gateway
waits thirty seconds for the request of `telar-run/1` to start, so that a
client can connect ahead of the command it will run.

## The state directory

`TELAR_GATEWAY_STATE`, else `telar/gateway` under `XDG_STATE_HOME` or
`~/.local/state`, mode 0700, every file 0600:

| File | Holds |
| --- | --- |
| `identity-key.pem`, `identity-cert.pem` | The account's key, made the first time it is needed. It is what the account presents as a client and what its gateway presents. |
| `authorized_clients` | `KEY NAME` per line: the clients the gateway admits. Read for every connection. |
| `pairing` | `SHA256(CODE) EXPIRY` per line: at most eight pending codes, ten minutes each. |
| `port` | The port the gateway last listened on, for `pair` to print. |
| `lock` | Serializes the processes that rewrite the others. |

## On the client's machine

`telar-gateway link` is one process per account, started when first needed,
with its sockets beside the runtime's. Programs ask it on `gateway.sock`, a
line each: `socket ADDRESS`, `forward ADDRESS PORT ORIGIN`, `hold ADDRESS`,
`run ADDRESS`, `ports ADDRESS`, `ping`, `stop`. A forward lasts while the
connection that asked for it stays open, and a held machine has the ports it
shares forwarded for as long as it is held.

`run` answers `ok` and then carries the run service on the asking socket. While
a command runs, the link connects again to its machine and keeps that
connection for twenty seconds, so the next command there starts without a
handshake. A command that finds no link connects by itself.

The link ends by itself after ten minutes in which nothing connected to it, no
forward was open and no machine was held, or when its control socket is gone.

## On the gateway's machine

A program shares a port with every connected client by asking the gateway on
`gateway-ports.sock`, beside the runtime's socket: `share PORT ORIGIN` or
`unshare PORT`, answered `ok` or `refused`. What it shared ends with its
connection. `telar share-ports`, which `telar exec --autoshare` runs its
command under, is that program.

## Tests

```sh
tools/cpp build dev -- --target telar-remote-tests
tools/cpp test dev -- -L '^lib\.remote$'
```

The cases pair two state directories over the loopback and exercise each
service through a real gateway and a real link in the test's own process.
