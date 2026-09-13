# Next steps

Written 2026-09-13. Where things stand: the `claude` account runs Claude Code in
five repos under `/Users/Shared/agents/work`, `agent-grant apply --check` is
clean, and everything below is optional. Anything marked *unverified* has not
been tested on this machine.

## 1. Small checks, whenever convenient

**Staying logged in after a restart.** After your next restart, before
switching to the `claude` account in the GUI, run:

```
sudo -u claude -i sh -c 'cd /Users/Shared/agents/work/core && /Users/claude/.local/bin/claude -p "Reply with the single word ok"'
```

- Prints `ok`: nothing to do. Record it in `docs/accounts.md`.
- Asks for login or fails: the Keychain is locked without a GUI session. The
  fallback (*unverified*) is a long-lived token. Run `claude setup-token`, then
  save the token as `export CLAUDE_CODE_OAUTH_TOKEN=…` in
  `/Users/claude/.zshenv`, mode `600` and owned by `claude`. zsh reads
  `.zshenv` for every shell, including `sudo -i sh -c`.

**The launcher really drops `SSH_AUTH_SOCK`.** The function works, but nobody
has looked at the environment it produces. This should print nothing:

```
sudo -u claude -i sh -c "exec env -u SSH_AUTH_SOCK env" | grep SSH_AUTH_SOCK
```

**Why `-i` keeps `SSH_AUTH_SOCK`.** Probably `env_keep` in `/etc/sudoers`
(*unverified*): `sudo grep -n env_keep /etc/sudoers`.

**Clean up.** Delete `/Users/Shared/agents/work/hello`, the throwaway test repo.

**Commit and add a remote.** The repo has no remote, so nothing is backed up
off this machine.

## 2. Scheduled drift check

The target shape in CLAUDE.md has `apply --check` running under launchd. Not
built yet.

- **Runs as you, not root.** `--check` needs no sudo; it already runs clean as
  you against the real base.
- **Where:** a LaunchAgent in `~/Library/LaunchAgents/`, with its log in
  `~/Library/Logs/`. Both are under your `700` home, so agents can't edit the
  job or the log.
- **Measure first.** Nobody has timed `--check` over the 63,000 objects now in
  `work`. Pick an interval once you know the runtime: `time agent-grant apply --check`.
- **Open question:** how drift gets your attention. A log file you look at, or
  a notification. A notification needs a small wrapper around `--check`, so
  start with the log.
- `apply` itself stays manual. It needs sudo, and an unattended root job is a
  bigger decision.

## 3. Linux port (Xubuntu)

Assessed in review, not started. **None of the Linux behavior below has been
verified.** It comes from knowledge of Ubuntu, coreutils and the `acl` package,
and every point needs testing before it goes into docs.

### Is it tightly coupled?

No. Every macOS permission call already sits in one block of `agent-grant`, plus
four small lookups in main. The port rewrites that block and makes one design
decision (the mask, below). The main loop, the convention and the fixture logic
in `test.sh` stay as they are.

### Shape

One script. A `case "$(uname)"` selects a Darwin or Linux block that defines
the same functions: `acl_want`, `acl_of`, `acl_set_root`, `acl_set_inherited`,
`acl_scan`, plus `owner`, `mode_bits`, `home_of` and `group_exists`. A second
script would duplicate main and drift. Estimate: the Linux block is 50–70
lines, because `getfacl` removes the name-pairing trick; the file ends up about
250 lines. `test.sh` gets the same treatment, about six lines.

### What maps to what

| Piece              | macOS (verified)                          | Linux (*unverified*)                                         |
|--------------------|-------------------------------------------|--------------------------------------------------------------|
| Write ACL          | `chmod -h -N`, `+a`, `+ai`                | `setfacl -P -b -m u:H:rwx,g:G:rwx`, plus `d:` entries on dirs |
| Scan               | `ls -ldefiq`, paired with find's list     | `getfacl -p -P` (prints names) and `find -printf '%i %n %y %p\0'` |
| Owner / mode       | `stat -f %Su` / `stat -f %Lp`             | `stat -c %U` / `stat -c %a`                                  |
| Home directory     | `id -P user \| cut -d: -f9`               | `getent passwd user \| cut -d: -f6`                          |
| Group exists       | `dscl . -read /Groups/G`                  | `getent group G`                                             |
| `xargs` on empty   | runs nothing                              | runs once; the existing `[ -s ]` guards already cover it     |
| Default base       | `/Users/Shared/agents`                    | `/srv/agents` (proposed)                                     |
| Accounts           | private group by hand, `chmod 700` home   | `adduser` already gives a private group and a `750` home    |
| Group membership   | `dseditgroup`, then flush the cache       | `usermod -aG`; no cache unless sssd/nscd                     |
| Scheduler          | launchd                                   | systemd user timer                                           |
| Claude credentials | Keychain                                  | `~/.claude/.credentials.json`                                |

### Linux differences that affect the design

- **The mask (decide first).** A POSIX ACL with named entries also has a mask,
  and ordinary actions rewrite it: files created `0444`, `cp -p`, `tar`, and
  `chmod 644`. So a correct ACL is no longer one fixed string. Recommended:
  compare only the named and default entries and ignore the mask, letting
  `apply`'s `setfacl -m` widen it as a side effect. The alternative, forcing the
  mask to `rwx`, makes `--check` dirty after everyday work.
- **Inheritance** comes from default ACLs on directories. It still happens
  only at creation: `mv` keeps the old ACL, and adding a default ACL doesn't
  reach existing files. Reconcile keeps the same shape. There is no `inherited`
  marker, so what `apply` writes looks the same as inheritance.
- **Rights are just `rwx`.** There's no separate delete right; deleting needs
  `w` and `x` on the parent directory, which the grant includes.
- **`fs.protected_hardlinks=1`** is Ubuntu's default. It stops a user
  hard-linking files it doesn't own or can't write, which closes the
  `/etc/sudoers` case in the kernel. Keep the inode count anyway.
- **sudo:** Ubuntu's sudoers resets `HOME` and drops `SSH_AUTH_SOCK` even
  without `-i`. Keep `-i` and `env -u` regardless.
- **Test bed:** a Multipass Ubuntu VM on this Mac (`brew install --cask
  multipass`, needs your admin password). Not Docker, whose overlay filesystems
  have uneven ACL support. The `acl` package may need `apt install acl`.

### Steps

1. **Start the VM.** Confirm `setfacl` and `getfacl` exist and the filesystem
   supports ACLs.
2. **Verify every claim in the table and list above** inside the VM. Record the
   results in `docs/acl-semantics-linux.md`, in the same style as the macOS
   doc. Most likely to surprise:
   - whether an identical `setfacl -m` bumps ctime;
   - the mask after `cp -p`, `tar`, and creating a `0444` file;
   - `getfacl` on a fifo.
3. **Record the decisions in CLAUDE.md:** the mask handling, the Linux base
   path, and that a second platform now exists. CLAUDE.md's "no cross-platform
   abstraction" rule allowed one only at that point.
4. **Split the Darwin block out** behind the `case`. `./test.sh` must still pass
   on the Mac, unchanged.
5. **Write the Linux block** and the matching `test.sh` helpers, then get the
   tests passing in the VM.
6. **Write a Linux accounts section:** `adduser`, groups, install, launch
   function. Then repeat the setup on the Xubuntu machine.

## 4. More agent accounts

For another vendor (Codex, Gemini CLI, Aider, opencode), follow
`docs/accounts.md`:

1. Create the account and give it a private primary group with an unused gid.
2. `chmod 700` its home.
3. Add it to `agents-work` and/or `agents-scratch`, then flush the cache.
4. Install the tool as that account, and add a launch function like
   `claude-agent`.

Unknown per vendor: where it keeps credentials and config, and whether it has
the same `sudo -i` quirks. Once a less-trusted tool appears, give it
`agents-scratch` only. That's when the `work`/`scratch` split starts to matter.

## 5. Keep in mind

- **Two copies of Claude Code data.** Your account and `claude`'s each have
  their own memories and sessions for `voll`, `wizard` and `core`, and from now
  on they diverge. Mostly use one account per project. The copy step is in
  `docs/accounts.md`; the migration script skips folders `claude` already has.
- **Code you run from a root runs as you:** hooks, `package.json` scripts,
  Makefiles. See the README's out-of-scope list.
- **Keep `agent-users` outside the roots.** If an agent works on it, run sudo
  only on a root-owned installed copy.
- **After any `mv` into a root,** run `sudo agent-grant apply`. Repair git
  worktrees first.

## 6. Claims still unverified on macOS

- `--dangerously-skip-permissions` being refused under root.
- `safe.directory` path wildcards arriving in git 2.46.
- pnpm hard-linking `node_modules` on APFS; it may clone files instead.
- A mounted volume's root showing up in a scan.
- Both rename races on a path component: a symlink swap, or a hard link renamed
  over a scanned file.
