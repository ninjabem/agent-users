# Home directory exposure

A separate uid protects only what modes and ACLs protect. Before granting
anything, check what the agent user can already reach without a grant.

## Observed (macOS 26.4.1)

- **Default home modes differ between accounts.** An account created recently
  got `drwxr-x---`. An older home on the same machine was `drwxr-xr-x`. Don't
  assume either; check with `ls -led ~`.
- **The agent account's primary group is `staff` (gid 20)**, the same group as
  the human's. So `750` on the human's home still gives the agent read and search
  through the group bits. Only `700` keeps it out. Check with `id <agent>`.
- **`staff` membership comes only from the primary group.** The `staff` record
  has no nested groups, and its `GroupMembership` is just `root`. Changing an
  agent account's `PrimaryGroupID` from 20 to a private group took it out of
  `staff`: `id` lost `20(staff)`, and `dsmemberutil checkmembership` said "not a
  member". Right after the change, both still reported `staff` until the
  membership cache was flushed or expired. The account is uid 502, so this is
  not a uid-range rule.
- **The kernel agrees.** Via `sudo -u <agent> -i`, `cat` of a `640 mono:staff`
  file in a `750 mono:staff` directory got `Permission denied`. No positive
  control was run while the account was still in `staff`, but no ACLs or other
  groups were involved, so group membership is the only thing that could have
  allowed it.
- **A `700` home holds.** With the human's home at `700`,
  `sudo -u <agent> -i ls /Users/<human>` gets `Permission denied`.
- **Agent accounts can read each other's homes, going by the mode bits.** A new
  account's home is `750` with group `staff`, and every such account is in
  `staff`. With one account per vendor, each can list and read the others'
  homes, except files that are themselves `0600`.
- **Top-level folders are protected; dotfiles are not.** `Desktop`, `Documents`,
  `Downloads` and `Library` are `700`. Tool config folders are typically created
  `755` with `644` files under the default `022` umask. One example seen: a cloud
  CLI credentials file at `0644` inside a `755` folder, readable by every local
  account.
- **An agent account's own home starts empty.** A binary the human installed
  under their home (e.g. `~/.local/bin/claude`) is unreachable once that home is
  `700`. The agent user needs its own install.

## Consequence for layout

`search` on a folder lets a user open any child *by name* if that child's own
modes allow it. Listing isn't needed; the names of well-known dotfolders are
public knowledge.

- **Grant root inside `$HOME`:** the agent needs `search` on `$HOME`, so every
  `755` dotfolder becomes readable. Closing that takes a recursive `go-rwx` over
  the home, plus a umask change so new files don't reopen it.
- **Grant root outside `$HOME`:** `/`, `/Users` and `/Users/Shared` already
  allow traversal by anyone (`/Users/Shared` is `1777`). No ACL is needed on any
  folder above the root, `$HOME` can be `700` with no exceptions, and the modes
  of files inside the home stop mattering.
