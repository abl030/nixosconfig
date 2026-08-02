# systemd-machined socket ordering for NixOS containers

## Incident

On 2026-08-03, doc2 switched from systemd 260.2 to 261.1 while seven declarative
NixOS containers were enabled. `switch-to-configuration` stopped machined and
its socket, then started many changed units. An nspawn container registered with
machined before the activation pass reached `systemd-machined.socket`, activating
`systemd-machined.service` first. systemd correctly refused the later socket
start with:

```
Socket service systemd-machined.service already active, refusing.
```

The switch exited 4 even though the new generation became current and machined
plus all seven containers were healthy. The socket remained inactive, so later
switches could repeat the failure.

## Invariant

`systemd-machined.service` requires and starts after
`systemd-machined.socket`. The dependency is emitted as a drop-in because the
full service unit comes from systemd. This puts an on-demand service activation
and its socket in one ordered transaction, ensuring the listener exists before
nspawn registration can start machined. On hosts with declarative containers,
placing the invariant on machined covers every activation path, including future
containers, without per-container configuration.

This follows systemd's established socket-activation pattern: the service must
require its socket when it needs the socket regardless of how the service is
started. The underlying multi-unit job race is tracked upstream in
[systemd issue #13271](https://github.com/systemd/systemd/issues/13271).

## Verification

For an affected host build, inspect `systemd-machined.service` and require both:

```
Requires=systemd-machined.socket
After=systemd-machined.socket
```

A subsequent reviewed deployment should confirm that the socket, machined, and
all declarative container units are active and that the NixOS switch succeeds.
Do not treat the currently healthy machined process alone as proof that the
ordering race is fixed.
