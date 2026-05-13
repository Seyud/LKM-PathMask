# TODO

## Multi-path hiding

Current status: `nohello.ko` hides one path per module load through the
`target_path` module parameter.

Planned direction:

- Accept multiple target paths from a module parameter or config file.
- Resolve each path to a `(dev, inode)` pair at module load time.
- Replace the single `target_dev` / `target_ino` check with a small target
  table and loop-based matcher.
- Decide how to handle paths that do not exist at load time.

## Scoped hiding / allowlist

Current status: hiding is global. Any process that reaches the hooked kernel
paths sees the target as missing.

Planned direction:

- Add an allowlist for UIDs, process names, or both.
- Let trusted apps or shell/root still access the file while hiding it from
  other apps.
- Keep the default demo behavior simple, but document the risk clearly.

