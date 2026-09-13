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
| `PATH`          | not checked        | yours, reordered      |

- **Always `-i`.** Without it the agent gets your `HOME`, which it can't read.
- **`-i` still passes your `SSH_AUTH_SOCK`,** probably through `env_keep` in
  `/etc/sudoers` (not checked). The agent can't use it today. The socket itself
  is `srw-rw-rw-`, but it sits in a `drwx------` directory you own under
  `/var/run/com.apple.launchd.*`. That protection comes from launchd's
  directory mode, not from sudo, so drop the variable when launching.
- **`-i` also keeps your `PATH`,** reordered. The login shell's `path_helper`
  (run from `/etc/zprofile`) moves the `/etc/paths` entries to the front and
  keeps yours after them. So the agent finds Homebrew tools through your PATH.
  Tools can resolve differently: `python3` was `/usr/local/bin/python3` for the
  agent but Homebrew's for you. PATH entries inside your home are dead ends for
  the agent.
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
- **Moving a repo breaks its worktrees.** Git records worktree locations as
  absolute paths in both directions. After `mv`, `git worktree list` marks
  linked worktrees prunable, and inside one git says "not a git repository".
  `git -C <repo> worktree repair <new paths…>` fixed both a sibling worktree
  and one nested inside the repo (`.claude/worktrees/…`). Verified with Apple
  git 2.39.5.

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

## Claude Code data when a repo moves

- **Per-project memories and session transcripts are filed by path.** They live
  in `~/.claude/projects/<slug>/`, where the slug is the absolute project path
  with every character outside `A-Za-z0-9-` replaced by `-`:
  `printf '%s' "$path" | tr -c 'A-Za-z0-9-' '-'`. Checked against five existing
  folders, including `_` and `/-` in the path. After a move, Claude Code starts
  that project fresh unless the folder is renamed to the new slug.
- `~/.claude.json` also keys per-project entries by absolute path, so the
  folder-trust prompt comes back after a move.
- **Each account has its own `~/.claude`.** The agent account sees none of your
  memories or sessions. To give it a project's, copy the slug folder into its
  `~/.claude/projects/`.
- Anything inside the repo moves with it: `CLAUDE.md`, `.claude/skills`,
  `.claude/settings*.json`.
- **Copying works, sessions included.** You read and the agent writes, so the
  agent owns the copy:
  `tar -C ~/.claude/projects -cf - ./<slug> | sudo -u <vendor> tar -C /Users/<vendor>/.claude/projects -xf -`.
  The `./` matters, because slugs start with `-`. Launched as the agent in the
  moved repo, `/resume` listed the old sessions and resumed a named one.

## Telling the agent it's restricted

The boundary doesn't depend on the agent knowing about it; the kernel enforces
it either way. Telling it saves effort. An agent that hits `Permission denied`
with no context tends to try workarounds, or asks you to loosen permissions.

`agent-instructions.md` in this repo is a short user-level instruction file for
agent accounts. It describes the limits without mapping what lies outside them.
Install it wherever the vendor reads user-level instructions. For Claude Code
that's `~/.claude/CLAUDE.md` in the agent's home; it isn't overwritten if one
already exists:

```
sudo -u claude test -e /Users/claude/.claude/CLAUDE.md && echo "exists, not overwritten" || sudo -u claude tee /Users/claude/.claude/CLAUDE.md < agent-instructions.md > /dev/null
```

Your shell opens `agent-instructions.md`, so the agent never needs access to
this repo. For other vendors, check their docs for the equivalent file.
