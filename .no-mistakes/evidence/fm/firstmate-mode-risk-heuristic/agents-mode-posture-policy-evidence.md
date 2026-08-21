# AGENTS.md delivery-mode policy evidence

Target commit: `d5b181a5b49b21010c0bc0125c079e097f328ce7`

The end-user-facing agent instruction now reads as one continuous policy block:

> A current explicit captain instruction wins; otherwise the project's registry entry is the captain's standing posture, and dropping below its rigor needs a reason you can state.
> A mechanical, well-trodden change (a version bump, a config tweak, copying an established pattern) is itself a sufficient reason.
> Symmetrically, raising a task above a direct-PR project's standing posture is warranted for genuinely new or risky work (a new algorithm, a concurrency-sensitive change, unfamiliar territory) even when the project defaults lighter.

The committed diff changes only `AGENTS.md`, adding exactly the latter two full sentences immediately after the standing-posture sentence. `git diff --check` accepts the change with no whitespace errors.
