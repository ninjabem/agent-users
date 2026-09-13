# agent-users

Tooling and documentation for running CLI coding agents as dedicated unprivileged
macOS user accounts with scoped filesystem grants.

Vendor-agnostic by design. Claude Code is the first target, but Codex, Gemini CLI,
Aider, and opencode all run as the invoking user and have the same problem.

## The problem

The threat model is an *enthusiastic* agent, not a malicious one:

- `rm -rf` against a path it constructed slightly wrong
- Reading outside the task — credentials, unrelated projects, browser profiles

Application-level sandboxes are policy computed by the same process being
constrained. A separate uid is enforced by the kernel: no allowlist for the agent
to misparse, no parameter for it to flip. This layers with a vendor sandbox rather
than replacing it.

## Explicitly out of scope

State these in the README too, so the design doesn't drift toward them:

- **Network egress.** A separate uid gives zero network isolation. Handle with the
  vendor's own sandbox allowlist or a packet filter. Not this repo's job.
- **Hostile code and local privilege escalation.** This is Unix DAC, not a
  hypervisor. That threat model needs a VM.
- **Anything inside a granted directory.** Agents need delete to do their work —
  git checkout, npm install, and any build step unlink and recreate files
  constantly. Take delete away and the agent is useless; leave it and the tree is
  destructible. There is no useful middle setting. Recoverability covers this
  (git remote, snapshots), not access control.

The value delivered is **blast radius**: everything outside the grant.

## Design philosophy

These are constraints, not aspirations. Violating one needs a written argument.

1. **Do one thing well.** Per program, not per repo.
2. **Compose, don't wrap.** If `sudo`, `ls`, or `chmod` already does it, call it.
   Don't reimplement it behind a friendlier flag.
3. **Declarative state, idempotent reconcile.** Same shape as `fstab` and
   `mount -a`. A file describes intent; one program makes the filesystem match.
   Running it twice changes nothing the second time.
4. **Universal interfaces.** Newline-delimited plain text. Greppable, diffable,
   version-controlled in this repo.
5. **Minimize complexity aggressively.** Prefer changing a convention to writing
   code that copes with the old one. The best patch deletes a file.

## Do not build these

- **A launch wrapper.** `sudo -u <user> -i <agent>` already works; a shell alias is
  enough. A launcher that validates the cwd against the grant list creates a second
  source of truth for the grant list.
- **A list/audit verb that re-prints ACLs.** `ls -le` does this.
- **A remove verb**, if deleting a line from the declarative file and reconciling
  achieves it.
- **Anything needing a daemon, package manager, or language runtime.** bash plus
  base macOS tools.
- **A cross-platform abstraction.** Keep the ACL calls isolated enough that a Linux
  `setfacl` backend is possible later. Do not write the abstraction until there is
  a second platform.

## Target shape

Challenge this if you see something better, but argue for it before building.

```
agent-grant apply           # make the filesystem match the convention
agent-grant apply --check   # exit non-zero on drift; suitable for launchd
```

There is no grant file. Every directory directly under `/Users/Shared/agents/`
is a root. Its ACL names `group:agents-<name>` and the root's owner, who is the
human. `apply` also makes the root and the owner's `$HOME` `go-rwx`. Without that,
a group-readable root lets every `staff` account in, whatever its trust level.

Launching stays an alias. Auditing stays `ls -le`. Recovery after an
ACL-destroying restore is `agent-grant apply`.

## Facts that are easy to get wrong

Verify these rather than trusting your priors; several are macOS-specific.

- `sudo -u X cmd` keeps the invoker's `HOME` and `SSH_AUTH_SOCK`. `-i` resets
  `HOME` but still keeps `SSH_AUTH_SOCK` (verified on 26.4.1; probably sudoers
  `env_keep`, not checked). The agent can't use the socket today only because
  its launchd directory is `700`. Always `-i`, and drop `SSH_AUTH_SOCK` in the
  launch alias (not yet tested).
- `sudo -i` hands the command to the target's login shell, which expands `$`
  in it first. Other special characters arrive intact. Keep `$` out of anything
  passed through `sudo -i`, prompts included.
- Prefer ACLs over POSIX group bits. ACLs are additive, support inheritance, and
  can name a group. POSIX groups require changing group ownership of ancestors and
  a permissive umask for the agent user — both worse.
- Deletion is permitted if the parent grants `delete_child` **or** the object
  grants `delete`. Denying one is not enough.
- `chmod +a` inserts at the canonical position, denies before allows. `chmod +a#`
  positions explicitly.
- `file_inherit` / `directory_inherit` are only meaningful on directory entries.
  Entries that land on files via inheritance carry the spec without those flags.
  `chmod -a` ignores those flags and the `inherited` marker when matching, so
  removal takes one pass. It subtracts rights, though, so the spec must cover
  every right in the entry. (Verified on 26.4.1; this used to say two passes.)
- `chmod +a` follows a symlink operand and writes the grant onto its target.
  Reconcile runs as root. Always `chmod -h`, and walk with `find ! -type l`.
- `chmod +a` of an entry that already exists adds nothing but still bumps ctime,
  which git's stat check notices. Compare before writing.
- Ancestors need `search`, not `read`. Search permits traversal without listing,
  so the agent can reach a project without enumerating its siblings.
- Inherited entries never survive a copy. `cp -p` and `ditto` keep only explicit
  ones, and the destination re-inherits from its new parent. **`mv` inherits
  nothing.** `/tmp`, `$TMPDIR`, `/Users/Shared` and home directories share one
  volume, so moving a project into a root is a rename and leaves it ungranted.
  Stock `rsync` is openrsync and lists no ACL option. Reconcile must rebuild
  everything from the declared state alone.
- Grant the invoking human an ACL on the same tree. Files the agent creates are
  owned by the agent user, and without this you can't write them.
- Mixed ownership in a repo trips git's dubious-ownership check.
- Claude Code stores credentials in the macOS Keychain. Under `sudo -i` the login
  keychain is said to be locked, so it would fall back to
  `~/.claude/.credentials.json` at 0600; not tested. What was tested: after
  installing and logging in from a GUI session of the agent account, `claude -p`
  under `sudo -u claude -i` authenticated, and no `.credentials.json` existed.
  It still authenticated after that GUI session was logged out. How is not
  known, and a restart is not tested.
- `--dangerously-skip-permissions` works under `sudo -u claude -i`, verified
  with `-p` on Claude Code 2.1.270. It is said to be refused under root; that
  part is not tested.
- Base `/bin/bash` is 3.2.57: no `mapfile`, no associative arrays, and `read`
  consumes a pipe a byte at a time. Push bulk work into `find`, `xargs`, `awk`.

## Decisions

Settled 2026-09-12. Reopening one needs a written argument.

- **Layout: roots outside `$HOME`.** Projects live under
  `/Users/Shared/agents/<trust-level>/`. Every folder above that is already
  traversable by all users, so there are no ACLs above a root, no parent walking,
  and no sibling audit. The human's `$HOME` is `700` with no exceptions. Recursive
  `go-rwx` and the umask change are unnecessary. See `docs/home-exposure.md`.
- **User axis: one user per vendor** (`claude`, `codex`, …), each with its own
  home, install, and credentials. The existing `claude` account (uid 502) is the
  Claude Code user.
- **Agent accounts have a private primary group** (`claude:claude`), not
  `staff`. `staff` membership comes only from the primary group (confirmed in
  the directory service and by the kernel), so this takes agents out
  of every group-readable `staff` object, each other's homes included. Trust-level groups stay supplementary. Agent homes are `700` too.
- **Group indirection: one group per trust level** (`agents-work`,
  `agents-scratch`). ACLs name the group; vendor users join groups. Adding a
  vendor changes no ACLs.
- **Membership lives in the directory service.** Managed with `dseditgroup`,
  documented rather than wrapped. `agent-grant` reconciles ACLs only.
- **Hardening is documented, checked, and fixed.** `apply --check` fails if the
  human's `$HOME` is accessible to group or other, and `apply` runs a
  non-recursive `chmod go-rwx` on it. Agent accounts are in `staff`, so `750`
  is not enough.
- **No grant file.** Convention replaces it. Every directory directly under
  `/Users/Shared/agents/` is a root, its group is `agents-<name>`, and the human
  is the root's owner. Adding a trust level is `mkdir` plus `dseditgroup`;
  removing one is deleting the directory.

## Working agreement

- Test against fixtures under `/tmp` or a dedicated scratch root. Never reconcile
  against a real project path without asking.
- Show me anything invoking `sudo`, `chmod -R`, or `dseditgroup` before running it.
- shellcheck clean.
- Every hard-won finding goes in `docs/`. The documentation is half the point of
  this repo — the tools are small, the knowledge isn't.
- Prefer deleting code over adding a flag.
