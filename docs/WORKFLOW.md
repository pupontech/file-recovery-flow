# Recovery Workflow Contract

This document is the initial acceptance boundary for implementation.

1. Preflight elevation, File Scavenger discovery, and R-Studio discovery must be explicit and logged.
2. Source selection must expose volume and physical-disk identity where Windows provides it.
3. The destination must be selected with a Windows folder browser, sanitized into a unique client folder, and separated from the source physical disk.
4. Job metadata, append-only recovery log, and resumable state must be written before scanner work begins.
5. File Scavenger short and long scan/recovery stages must be distinct. Scan completion is not recovery completion.
6. No long stage may start until the preceding recovery stage is verified complete.
7. File Scavenger close must be graceful first; force close is a guarded last resort only after active recovery is known to be finished.
8. R-Studio may be launched for handoff, but no destructive or automatic analysis action is allowed.
9. Every unsupported vendor operation must be surfaced as a manual operator gate, not guessed or silently skipped.
10. Resume must never rerun a completed stage without an explicit operator choice.

## Live validation gate

A technician with licensed File Scavenger and R-Studio installations must validate the real application controls and end-to-end workflow on a disposable/test recovery case before production use. CI cannot prove vendor GUI behavior without those applications.
