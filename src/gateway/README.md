# Telar gateway

`telar-gateway` is the one program that speaks to telar on another machine. It
replaces what SSH carried: an account that wants to be reached runs
`telar-gateway serve`, and the clients that reach it run the link and the
one-shot commands of the same program. `telar` and the windows start it; they
never link what it links. The connection, its services and the files that keep
who may connect are in [`lib/remote`](../../lib/remote/README.md).

## Commands

`telar-gateway --help` lists them. People use them through `telar`:

| `telar` | `telar-gateway` | Where |
| --- | --- | --- |
| `telar server listen` | `serve` | the machine clients reach |
| `telar server pair` | `pair` | the machine clients reach |
| `telar server access list`, `revoke` | `clients`, `revoke` | the machine clients reach |
| `telar machine add LABEL ADDRESS` | `enroll` | the client's machine |
| `telar --machine LABEL COMMAND` | `run` | the client's machine |
| a window on a machine | `socket` | the client's machine |
| a click on a link to a port there | `forward` | the client's machine |
| `telar --machine LABEL ports` | `ports` | the client's machine |

`link` is the process behind `socket`, `forward` and `ports`: one per account,
started when the first of them is asked for, beside the runtime's socket.

## Development

From the repository root:

```sh
just gateway-build
tools/cpp test dev -- -L '^lib\.remote$'
```

The program builds beside `telar` and `telar-runtime`, in
`out/<preset>/src/runtime`, because each starts the others from its own
directory. `-DTELAR_BUILD_GATEWAY=OFF` leaves it out of a tree.

Two accounts on one machine are two state directories:

```sh
TELAR_GATEWAY_STATE=/tmp/there telar-gateway serve --listen 127.0.0.1:18352 &
address=$(TELAR_GATEWAY_STATE=/tmp/there telar-gateway pair --host 127.0.0.1)
saved=$(TELAR_GATEWAY_STATE=/tmp/here telar-gateway enroll "$address")
TELAR_GATEWAY_STATE=/tmp/here telar-gateway run "$saved" 'uname -a'
```
