# agent-users

Run CLI coding agents (Claude Code, Codex, Gemini CLI, Aider, opencode) as
dedicated unprivileged macOS accounts that can reach only a few directories.

## Why

The threat is an *enthusiastic* agent, not a malicious one: `rm -rf` on a path
it built slightly wrong, or reading credentials and unrelated projects on the
way to its task.

An application sandbox is policy computed by the process it constrains. A
separate uid is enforced by the kernel. There's no allowlist for the agent to
misparse and no flag for it to flip. Use it alongside the vendor's sandbox, not
instead of it.

What you get is **blast radius**: everything outside the grant is out of reach.

## Out of scope

- **Network egress.** A separate uid gives no network isolation. Use the
  vendor's sandbox allowlist or a packet filter.
- **Hostile code and local privilege escalation.** This is Unix DAC, not a
  hypervisor. That threat model needs a VM.
- **Anything inside a granted directory.** Agents need delete to work: git
  checkout, npm install and every build unlink and recreate files. Recoverability
  (a git remote, snapshots) protects that tree, not access control.

## Layout

```
/Users/Shared/agents/        owned by you, go-w
├── work/                    your projects; you + group:agents-work
└── scratch/                 throwaway experiments; you + group:agents-scratch
```

- One account per vendor (`claude`, `codex`, …), each with its own primary group
  instead of `staff`, and a `700` home.
- One group per trust level. Accounts join groups with `dseditgroup`.
- Your home is `700`.

There is no config file. Every directory under `/Users/Shared/agents/` is a
root, and its group is `agents-<name>`.

## Usage

```
sudo agent-grant apply           # make the filesystem match the convention
agent-grant apply --check        # print drift; exit 1 if there is any
```

**Getting projects in:** `git clone` into a root. If you `mv` something in
instead, run `sudo agent-grant apply` afterwards, because a moved tree keeps
its old permissions and the agent can't use it until then. For a local
repository, use `git clone --no-hardlinks`; hard-linked files are refused
because another link may sit outside the root.

Auditing is `ls -le`. Tests: `./test.sh`.

## Launching

A shell function is the whole launcher. For the `claude` account, in
`~/.zshrc`:

```
claude-agent() { sudo -u claude -i sh -c "cd '$PWD' && exec env -u SSH_AUTH_SOCK /Users/claude/.local/bin/claude"; }
```

Run it from a project folder inside a root. `-i` gives the agent its own
`HOME`, and `env -u` removes your ssh-agent socket, which `sudo -i` would
otherwise pass through. Your shell expands `$PWD` before sudo sees it, so a
folder name containing `'` or `$` breaks it; see
[docs/accounts.md](docs/accounts.md).

## Docs

- [docs/home-exposure.md](docs/home-exposure.md): what an agent account can
  already read before you grant anything.
- [docs/acl-semantics.md](docs/acl-semantics.md): macOS ACL behavior, verified,
  including the surprises.
- [docs/accounts.md](docs/accounts.md): setting up an agent account, launching
  it with sudo, and git inside roots.
