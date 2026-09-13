# Agent accounts

One account per vendor. Each has its own primary group instead of `staff`, a
`700` home, and membership in the trust-level groups it may use.

## Why not `staff`

The `claude` account on the reference machine came with primary group `staff`
and a `750` home, so every such account can read every other one's home, plus
any other object readable by group `staff`. Details in
[home-exposure.md](home-exposure.md).

Giving each account a private group, like Linux's user-private groups, removes
that whole class without anyone enumerating it. After the change, the directory
service no longer lists the account in `staff`, and the kernel denies it a
`staff`-only file. The `700` home closes the account-to-account case on its
own as well. A single shared `agents` group
would not: agents would share a group again. Trust-level groups stay extra
memberships.

## Groups

Once per account, and once per trust level:

```
sudo dseditgroup -o create -i <gid> -r "<vendor> agent" <vendor>
sudo dseditgroup -o create -i <gid> -r "Agents: <level>" agents-<level>
```

`-i` is optional; without it `dseditgroup` picks a gid. Setting it keeps a
trust-level group from taking the gid a later account's private group would
want. Matching an account's uid is a convention, not a requirement. A group
must exist before `agent-grant apply` names it in an ACL.

## Move the account off `staff`

```
sudo dscl . -create /Users/<vendor> PrimaryGroupID <gid>
sudo chmod 700 /Users/<vendor>
sudo dseditgroup -o edit -a <vendor> -t user agents-<level>
sudo dsmemberutil flushcache
```

- **Don't `chgrp -R` the home.** Once the home is `700`, no other account can
  reach anything inside it, so the group on those files doesn't matter. The
  old group would linger anyway: new files take their parent directory's
  group, not the creator's primary group ([acl-semantics.md](acl-semantics.md)).
- **Root can't walk another user's `Library` from a terminal.** `sudo chgrp -R`
  over an agent's home printed `Operation not permitted` for hundreds of
  privacy-protected paths: Mail, Messages, Safari, HomeKit, Group Containers,
  each container's `.com.apple.containermanagerd.metadata.plist`, and `.Trash`.
  Directories appear twice. This is most likely TCC (the terminal's Full Disk
  Access wasn't checked). The files it could change now have a mixed group,
  which is harmless behind `700`.
- `chgrp -R` doesn't follow symlinks it meets while walking (`-P` is the
  default); it changes the links themselves. Verified on 26.4.1. This differs
  from `chmod +a`, which follows a symlink operand.

## Check

```
id <vendor>                                          # no 20(staff)
dsmemberutil checkmembership -U <vendor> -G staff    # not a member
```

Both keep reporting `staff` right after the change, until the membership cache
is flushed (`sudo dsmemberutil flushcache`) or expires.

The kernel agrees (verified on 26.4.1). To see it for yourself, open a file that
only group `staff` can read, as the account:

```
sudo -u <vendor> -i cat <staff-only-file>             # Permission denied
```

## Launching with sudo

Observed on 26.4.1, comparing `env` under each form:

| Variable        | `sudo -u <vendor>` | `sudo -u <vendor> -i` |
|-----------------|--------------------|-----------------------|
| `USER`          | `<vendor>`         | `<vendor>`            |
| `HOME`          | yours              | `/Users/<vendor>`     |
| `SSH_AUTH_SOCK` | yours              | yours                 |

- **Always `-i`.** Without it the agent gets your `HOME`, which it can't read.
- **`-i` still passes your `SSH_AUTH_SOCK`,** probably through `env_keep` in
  `/etc/sudoers` (not checked). The agent can't use it today. The socket itself
  is `srw-rw-rw-`, but it sits in a `drwx------` directory you own under
  `/var/run/com.apple.launchd.*`. That protection comes from launchd's
  directory mode, not from sudo, so drop the variable when launching.
- **With `-i`, the agent's login shell expands `$` in your command.**
  `sudo -u <vendor> -i sh -c 'd=/x; mkdir "$d"'` ran `mkdir ""` and printed
  `mkdir: .: No such file or directory`. The agent's zsh expanded `$d`, which is
  unset there, before `sh` saw the string. `;`, `&&`, `>` and quotes arrived
  intact. This is documented in sudo(8), version 1.9.17p2, under `-i`: the
  command is backslash-escaped except for alphanumerics, underscores, hyphens
  and dollar signs, then passed to the login shell with `-c`. Keep `$` out of anything
  passed through `sudo -i`, including prompts given to an agent on the command
  line.

## Git inside roots

- An agent account's login shell doesn't include Homebrew's paths. It gets
  only `/etc/paths` and `/etc/paths.d`, so it uses Apple's `/usr/bin/git`,
  2.39.5 on 26.4.1.
- Repos in a root are usually owned by you, which trips the agent's git
  "dubious ownership" check. Per-folder wildcards for `safe.directory` came in a
  later git (2.46, from memory; not tested). The agent account turns the check
  off for itself instead:
  `sudo -u <vendor> -i git config --global safe.directory '*'`. The account can
  only reach the roots, so little is lost. With that set, `git status` as the
  agent works in a repo you own.

## Claude Code in the account

What worked on 26.4.1 with Claude Code 2.1.270:

1. Switch to the agent account in the GUI, install Claude Code with the
   official installer, and log in there. The binary ends up at
   `/Users/<vendor>/.local/bin/claude`.
2. Back in your own session, run it through `sudo -u <vendor> -i` from a project
   folder inside a root.

- `claude --dangerously-skip-permissions -p …` under `sudo -u <vendor> -i`
  authenticated and ran.
- No `~/.claude/.credentials.json` existed afterwards, so the credentials are
  presumably in the account's login Keychain (not inspected).
- It still authenticated after the agent's GUI session was logged out. How is
  unclear: no `.credentials.json` existed when checked, and a logged-out
  account's Keychain would normally be locked.
- The `claude-agent` function from the README launched Claude Code, already
  logged in, in the project folder.
- **Not tested:** whether it still authenticates after a restart.
