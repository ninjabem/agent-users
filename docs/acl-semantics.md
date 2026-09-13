# ACL semantics on macOS

Verified on macOS 26.4.1 (APFS). Most of this was tested with scratch files as
their owner, which shows what ACLs *say*. The last section covers what the
kernel enforces for a second uid.

## Rights have two names

Directory names and file names are aliases for the same bits:

| directory          | file      |
|--------------------|-----------|
| `list`             | `read`    |
| `add_file`         | `write`   |
| `search`           | `execute` |
| `add_subdirectory` | `append`  |

A directory entry granting `list,add_file,search,add_subdirectory` shows up on
inheriting files as `read,write,execute,append`. `ls -le` prints whichever name
fits the object.

## Inheritance happens at creation, and only then

- `touch`, `mkdir`, `cp` (with or without `-p`) and `ditto` into a granted
  directory all produce inherited entries.
- **`mv` does not.** A rename keeps whatever ACL the object already had.
  `/private/tmp`, `/private/var/folders` (`$TMPDIR`), `/Users/Shared` and home
  directories are all on the one Data volume, so moves between them are renames.
  Moving a project into a root gives the whole moved tree no grant. So does any
  tool that writes to `$TMPDIR` and renames into place.
- **Adding an ACL to an existing directory does not propagate** to anything
  already inside it. Reconcile has to walk the tree.
- Inherited entries on subdirectories keep `file_inherit,directory_inherit`.
  Inherited entries on files drop those flags. Both are marked `inherited`.
- Explicit entries sort before inherited ones.

## Copies

| operation | explicit entries at source | inherited entries at source |
|-----------|----------------------------|-----------------------------|
| `cp`      | dropped                    | dropped                     |
| `cp -p`   | kept                       | dropped                     |
| `ditto`   | kept                       | dropped                     |

In every case the destination also gets fresh inherited entries from its new
parent. Inherited entries are recomputed on copy, never carried over.

## Removal: `chmod -a`

- **Matching ignores inheritance flags and the `inherited` marker.** The
  directory spec, `file_inherit,directory_inherit` included, removes the
  flagless inherited entry on a file in a single pass. A flagless spec removes a
  directory entry that carries the flags.
- **It subtracts rights; it does not match whole entries.** Running
  `-a "user:X allow read"` against an entry granting `read,write` leaves `write`.
  An entry disappears only once no rights remain. To remove an entry, use a spec
  that includes every right it grants.

## Flags that are easy to swap

- `-i` removes the `inherited` **marker**, so inherited entries become explicit.
- `-I` removes inherited **entries**.
- `-N` removes the whole ACL. `-C` fails if an ACL is not in canonical order.
  `+ai` adds an entry already marked inherited.
- `+a` places denies before allows regardless of insertion order.

## Writing an entry that already exists

- `chmod +a` (and `+ai`) with an entry identical to an existing one adds no
  duplicate and exits 0, **but still updates the file's ctime.** git's index
  records ctime (`core.trustctime`, on by default), so rewriting every ACL in a
  tree makes every file fail git's stat check. Compare before writing.
- `chmod -a` on a file with no ACL fails with `No ACL present`, exit 1.
- `chmod -N` on a file with no ACL exits 0 and leaves ctime alone.

## rsync

`/usr/bin/rsync` is openrsync (protocol 29). Its help lists
`--extended-attributes` and no ACL option. Don't count on it to carry ACLs;
run reconcile after any rsync-based restore.

## Entry order

- `chmod +a` puts a new entry at the **top** of its class. Denies sort before
  allows and explicit before inherited. Adding the group, then the user,
  gives `0: user…` and `1: group…`.
- Inherited entries keep the parent's order.
- Rebuilding a descendant with `chmod -N`, then `+ai` for each entry in the
  order used on the parent, gives text identical to natural inheritance.
- That includes files given the *directory* spec with inherit flags: the file
  drops the flags and shows file names for the rights. One spec string serves
  roots, directories and files, so "correct" is a string comparison against
  `ls -le`.

## Symlinks, hard links, and other objects

- **`chmod +a` follows a symlink passed as an operand.** The entry lands on the
  target, which can be anywhere. Reconcile runs as root, so a symlink inside a
  root pointing at another root, or at a system directory, would get the grant
  written there. `chmod -h` writes to the link itself instead.
- **`chmod -h` protects only against a symlink in the last path component.** If
  a directory along the path is swapped for a symlink between the scan and the
  write, the write lands under the symlink's target. Renaming a hard link to an
  outside file over a scanned path does the same, and `-h` can't help because
  the path then names a regular file. Both take an agent actively racing
  reconcile, which is the hostile case this repo excludes. (Not tested.)
- `find` does not follow symlinks by default (`-P`), so `find <root> ! -type l`
  only yields objects that really live under the root.
- **A user can hard-link a file it cannot read.** Verified in review: an
  unprivileged user ran `ln /private/etc/sudoers x` successfully, and the link
  count went to 2. `/private/etc/master.passwd` was refused with `EPERM`.
  `/private/etc`, `/Users/Shared` and `$TMPDIR` are one device. An ACL lives on
  the inode, so granting a hard-linked file inside a root would grant every
  other link to it too, as root. Reconcile grants a hard-linked file only when
  its scan of that root finds as many links to the inode as the link count
  says, and refuses it otherwise.
- **Hard links inside one tree are common.** npm links esbuild's binary between
  `node_modules/esbuild/bin/esbuild` and
  `node_modules/@esbuild/darwin-arm64/bin/esbuild`. Refusing every hard link
  would fail any such project on every run. A local `git clone` from outside
  the root hard-links objects back to the source repo; use `--no-hardlinks`.
- **`chmod` on a fifo blocks** opening it when nothing is writing, while
  `ls -le` on it returns at once. **On a socket it fails** with
  `Operation not supported on socket`. Both verified in review. Reconcile only
  touches regular files and directories. A fifo created inside a root still
  inherits normally.
- `find -xdev` still lists a mount point itself, just not what's under it, and
  `hdiutil attach -mountpoint` works without admin. A mounted volume's root can
  therefore show up in a scan. (Not tested.)

## Scanning a tree

- `find -acl` and `find ! -acl` select objects with or without an extended ACL.
  Cheap, but they can't tell a correct ACL from a wrong one.
- `ls -lde` sorts its operands. `ls -ldef` keeps them in the order given, so the
  output of `find -print0 | xargs -0 ls -ldef` lines up with find's list.
- If a file vanishes between `find` and `ls`, `ls` prints one header fewer and
  every later pairing shifts. Count headers against names and distrust the
  whole scan on a mismatch.
- `ls -i` adds the inode as the first field of each header and leaves the ACL
  lines unchanged.

## Principals resolve at write time

`chmod +a "group:nosuch allow read" f` fails with
`Unable to translate 'nosuch' to a UUID`. The group must exist before anything
references it.

## Group ownership follows the parent

A new file takes its parent directory's group, not its creator's primary group
(BSD semantics). A file created in a `wheel`-group directory by a `staff` user
is group `wheel`.

## Enforcement for an agent account

Tested end to end after the first real `apply`, with an agent account that
belongs only to `agents-scratch`:

- **The agent can work inside its root.** Via `sudo -u <agent> -i`, it created
  a directory and a file in `scratch` and read the file back.
- **It is kept out of other roots.** `ls` on `work` got `Permission denied`.
- **What it creates inherits exactly the expected pair.** Its new directory and
  file carried `user:<human>` and `group:agents-scratch` as inherited entries,
  and `agent-grant apply --check` stayed clean. The text `agent-grant` compares
  against matches what real inheritance produces for another uid.
- **The human keeps full use.** As the human, without sudo, appending to the
  agent-owned file and `rm -r` on the agent-owned directory both worked,
  through the human's ACL entry.
- The agent's files were owned by the agent, with group `wheel` (the root's
  group, not the agent's primary group) and modes `755`/`644` from its umask.
  Those mode bits don't matter behind a `go-rwx` root.
