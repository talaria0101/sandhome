---
name: sealed-sandbox
description: Operate and diagnose a sealed agent sandbox - no bind, no pty, no /etc/passwd, egress only through a proxy, and mounts that refuse exec. Use when a cage denies bind or chroot, when an ssh server will not start, when a login is refused with publickey, when a program needs a terminal that does not exist, or when a binary is present but will not execute.
---

# Working inside a sealed sandbox

A sealed cage typically has: no `bind(2)`, no `/dev/ptmx`, no `/etc/passwd`, no
`/var`, no UDP, possibly no resolver, and an egress that reaches only a proxy
or a whitelisted rendezvous. Each has a named workaround here.

`docs/reference.md` carries every command and every variable, generated from
the code. After a network-only setup the docs also live under
`$SANDHOME_HOME/repo/docs/`; without any docs on disk use `sandhome help` and
`sandhome <cmd> --help`, which print the same contract. `docs/architecture.md`
section 6 and `skills/sealed-sandbox/SKILL.md` carry the measurements.
This page is the map.

## First, measure

```sh
sandhome space --probe   # which roots run a binary
sandhome report          # os, kernel, arch, libc, privilege, provider, pty, passwd
sandhome doctor          # one line per invariant, ending in doctor_failures=N
```

`report` and `doctor` read the machine. Do not infer a capability from a
package list, from a mount option, or from what a previous run reported: a
mount can be `rw` with no `noexec` in its options and still refuse `execve`.

## No exec on the data root

The most common shape, and the reason this repository exists. `sandhome`
detects it by running a file, splits the roots, mirrors executables onto the
exec root and symlinks shared objects back. See `docs/architecture.md` section 1.

If a tool "installed" and is not found, or a binary is `Permission denied`:
`sandhome install <name>`. It rebuilds the exec view and probes the tool
afterwards.

## No bind

Both ends must dial out: nothing here listens, and nothing needs to. A sandbox
that cannot `bind(2)` can still `connect(2)`, so any transport where both peers
initiate is available and any where one side listens is not. A rendezvous relay
that both peers dial is the shape that works; a public one is perishable, so
re-measure latency and failure modes rather than trusting a recorded table.

This repository does not carry a transport. What it does carry is the tooling
that makes a transport work in a cage: `sandhome shell` for the session,
`SANDHOME_PASSWD_USERS` for the account, and the shims for a program that
refuses to start without a terminal or a passwd entry.

## No pty

Use `errandsh` (`skills/errandsh/SKILL.md`): `sandhome shell`. For a program
that needs `isatty(2)` to be true, build and load the interposer:

```sh
sandhome shims
SANDHOME_SHIMS=1 . "$SANDHOME_HOME/env.sh"
```

**Opt-in, but changes are scoped**: `env.sh` exports the session descriptors'
readlink identity, so `fakepty` fakes THOSE and leaves a pipe opened later a
pipe; a pipeline is no longer colourised. Turn it on for the shell that needs a
terminal, `sandhome pty CMD` for a single command, or `sandhome shell` for an
interactive line discipline.

Full-screen programs DO work: `shims/fakepty.c` is a userspace pty, because the
kernel offers none, and `sandhome pty nano file` runs it. The only thing it
cannot reach is a STATICALLY LINKED program, which carries its own libc.

## No listen

A local dev server, `npm run dev`, `python3 -m http.server`, or any process
that calls `bind(2)` cannot start here: nothing listens. Do not retry bind
variants. Either dial out to a relay both ends connect to (per the no-bind row
above) or emit static output instead of serving it.

## No /etc/passwd

`fakepwd.so` answers `getpwnam`/`getpwuid` from `$SANDHOME_PASSWD`, which
`env.sh` exports when the shims are loaded. Add login names with
`SANDHOME_PASSWD_USERS=agent,deploy` and rebuild:

```sh
SANDHOME_PASSWD_USERS=agent,deploy sandhome shims
```

An ssh server refuses an unknown account with `Permission denied (publickey)`,
which reads as a key problem and is not one. The synthetic database is written
by `sandhome shims` and is readable at `doctor_failures` time: `shim_report`
prints its path.

**Build the server dynamically.** A statically linked binary carries its own
libc, so `LD_PRELOAD` cannot reach it. A static `dropbear` also cannot see a
synthetic passwd entry and logs `Login attempt for nonexistent user` for a user
that is there. `shims/fakepwd.c` is the reference implementation.

## No chroot, and sshd will not start

`sshd -i -t` exiting 0 is not evidence that `sshd -i` runs. A modern OpenSSH
needs a privilege-separation user and a chroot directory that a cage denies:

1. `sshd -i -t -f <config>` exits 0
2. `sshd -i` gives `Privilege separation user nobody does not exist`
3. with a `nobody` entry, `Missing privilege separation directory: /var/chroot/ssh`
4. moving `ChrootDirectory` has no effect; a different path is hardcoded
5. `UsePrivilegeSeparation no` is deprecated and ignored since OpenSSH 8.4

No configuration fixes it. The working shape is a dynamically built `dropbear`
that tolerates a denied `setgroups(2)` and a denied `ENOTSOCK` on
`socket(AF_INET, SOCK_STREAM)` from a pipe-carried session. Both changes are
small and both belong to whichever build produces that server; nothing in this
repository needs them.

## The map

| the cage denies | the answer |
| --- | --- |
| `execve` on a writable mount | `sandhome space --probe`, then `sandhome install <name>` |
| `bind(2)` | any transport where both ends dial out; nothing here listens |
| `/dev/ptmx` | `sandhome shell`, and `SANDHOME_SHIMS=1` for non-shells |
| `/etc/passwd` | `sandhome shims` with `SANDHOME_PASSWD_USERS` |
| `chroot` and a privilege-separation user | a dynamic `dropbear` that tolerates a denied `setgroups(2)` |
| `/var` | the exec root is `$HOME`, `/tmp` or `/dev/shm`; `--exec DIR` names one |
