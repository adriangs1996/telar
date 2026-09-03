# Proxy trust

The user alone starts a system-trust change. The command never contacts the
runtime socket. The next server start validates the local installation record,
rotates an authority near expiry, and publishes the installed state to every
client.

## End-to-end path

```text
telar proxy trust install|uninstall|status
                 |
          CLI parser + proxy.run
                 |
       owner-only proxy directory
                 |
  ca-system-key.pem + ca-system-cert.pem
                 |
       printed direct argv execution
                 |
 macOS login keychain or selected Linux backend
                 |
         trust-install.json
                 |
          telar server startup
                 |
 validate fingerprint + lifetime; rotate near expiry
                 |
 runtime ProxyStatus.system_trusted
                 |
 client model -> presenter -> top-bar shield
```

## Authority and failure rules

`install` creates a separate 30-day CA. It installs the certificate before it
writes `trust-install.json`; a later failure removes the new certificate on a
best-effort rollback. Rotation installs the replacement, removes the recorded
prior authority, activates the new files, and then replaces the record. The
private CA files used without system trust are never installed.

The record binds the selected backend, uppercase SHA-1 fingerprint, and store
path. `uninstall` uses those recorded values rather than searching by subject.
A missing record is an idempotent no-op. A malformed record is not: install and
uninstall stop because neither can identify old authority safely.

macOS targets the current user's login keychain and does not use `sudo`. Linux
requires the user to select `update-ca-certificates` or p11-kit `trust`; the
commands that modify their stores use `sudo`. All process launches pass a fixed
argv directly and print it first. Telar does not automate Firefox's separate
certificate store.

## Runtime and presentation

Server startup checks the proxy directory even when interception is disabled.
A valid record must match the certificate fingerprint, owner-only files, the
30-day lifetime bound, and the one-day rotation window. When interception is
enabled, the runtime mints leaves from the system authority only while that
record remains valid. Otherwise it uses the separate private authority.

The runtime publishes the trust bit beside active interception and scope.
Clients commit one status revision and render yellow for trust-only, peach for
active exact scope, or red for active wildcard scope. The trust-only badge
therefore survives an inactive proxy and a client reconnect.

## Proof

- `src/backend/proxy/ca.zig` proves the 30-day lifetime, key/certificate match,
  owner-only persistence, fingerprint, and bounded expiry check.
- `src/cli/proxy.zig` proves record parsing, permissions, fingerprint matching,
  default paths, and direct platform command construction.
- `src/cli/server.zig` proves separate private and system authority paths.
- `src/core/schema_contract_test.zig` fixes the wire representation.
- `src/frontend/client/application/agents/proxy_status*.zig` prove exact
  transitions and notification ordering.
- `src/frontend/widgets/top_bar.zig` proves the trust-only badge stays visible
  with the proxy off.
