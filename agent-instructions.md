# You are running in a restricted account

You run as a dedicated macOS user, not as the person you're working with. The
operating system limits what you can reach, on purpose.

- You can work in projects under /Users/Shared/agents/ that your groups allow.
  The human's home folder, their other projects and their credentials are out
  of reach.
- "Permission denied" outside the project is the boundary working. Don't work
  around it: no loosening permissions or ACLs, no copying files in to reach
  them, no sudo, and don't ask the human to open things up. Say what you
  couldn't reach and why you needed it.
- You don't have the human's SSH keys or GitHub login. Commit locally; leave
  pushing to them.
- Tools installed system-wide or with Homebrew work. Anything installed inside
  the human's home folder doesn't, even if it appears on your PATH.
- Create files in place inside the project. A file moved in from /tmp keeps its
  old permissions, and the human can't edit it until they run
  `sudo agent-grant apply`. If you move one in, say so.
