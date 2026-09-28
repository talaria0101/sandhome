# Skills

This directory follows the Agent Skills standard: each subdirectory holds a
`SKILL.md` with `name` and `description` frontmatter, and everything else beside
it is freeform. Pi discovers them from a package's `skills/` directory, and
from `~/.agents/skills/` or `~/.pi/agent/skills/` once copied or linked there.

| skill | use it when |
| --- | --- |
| [`sandhome`](sandhome/SKILL.md) | a sandbox needs tooling, `HOME` is on a noexec mount, or a tool installed but will not run |
| [`errandsh`](errandsh/SKILL.md) | a remote shell has no echo, line editing or signals because there is no pty, or a full-screen program must run without one |
| [`sealed-sandbox`](sealed-sandbox/SKILL.md) | a cage denies bind, chroot, `/etc/passwd` or a terminal |

To make them available to an agent without copying:

```sh
ln -s "$PWD/skills" "$HOME/.agents/skills/sandhome"
```

Each skill is the entry point, not the whole story. The commands, flags and
environment variables they name are specified in `docs/reference.md`, which is
generated from the code and checked by `sh tests/docs.sh`. The reasoning is in
`docs/architecture.md` and `docs/decisions/`. A skill that drifts from the
code is worse than no skill, so every command in them is one the code answers
to today.
