# hc runtime backend

hc is an experimental session-provider backend for herdr-core, the terminal core under Herdr.app.
It provides task terminals while Treehouse continues to provide git worktrees, the same split tmux uses.
herdr-core is not Herdr 1: the `herdr` backend ([`herdr-backend.md`](herdr-backend.md)) talks to the `herdr` multiplexer, and the two share no socket, id space, or CLI.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared selection and metadata semantics.
This page owns operator setup and supported limits; the adapter header in `bin/backends/hc.sh` explains implementation decisions.
[`verification/runtime-backends.md`](verification/runtime-backends.md#hc) records what was exercised against a real core.

## Setup

Prerequisites:

- Herdr Core at version 0.1.14 or later, self-identifying as `hc x.y.z`, and a core speaking protocol generation 1.
  Binary resolution uses an executable `FM_HC_BIN` override first, then `herdr-core` on `PATH`, then the `hc` alias.
  `hc` starts its own core on first use.
  [`bin/fm-install-hc.sh`](../bin/fm-install-hc.sh) owns installation usage and the checksum-verified release pin; updates remain operator-run.
- `jq` for JSON responses.
- Native secondmates additionally require hc 0.1.16 or later and Python 3 for read-only styled observation.
  The general installer pin remains suitable for ordinary terminals; select a release meeting the secondmate floor before launching a native secondmate.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

Select hc with local `config/backend` containing `hc`, `FM_BACKEND=hc` for one launch, or an explicit request to Firstmate.
It is never runtime auto-detected; see "Selection is explicit" below.

The core a task lands on is the one `HC_SESSION` names when the task is spawned, or hc's `default` session when it is unset.
Herdr.app shows the `default` session's terminals.

## Selection is explicit

hc is explicit-only, like zellij, orca, Paseo, and tern.
hc stamps `HC_TERMINAL_ID` into every process an hc terminal starts, including a tmux server or Herdr 1 client started inside one, so its presence never proves the captain chose hc and `fm_backend_detect` ignores it.

## Task shape and metadata

Each task is one hc terminal running the user's login shell in the project directory, started with `--no-parent --outlive-parent --no-notify` so it is independent of whichever hc terminal Firstmate itself runs in.
The terminal carries these labels:

| Label | Value | Purpose |
| --- | --- | --- |
| `firstmate.task` | `fm-<id>` | Task identity checked before input or close. |
| `firstmate.home` | `<hometag>` derived from the physical `FM_HOME` | Keeps two homes with the same task id apart. |
| `herdr.space` | `FM_HC_SPACE`, default `fm-<hometag>` | Groups a home's tasks in one Herdr.app space. |
| `herdr.tab` | `<hometag>-fm-<id>` | One Herdr.app tab per task. |

```text
backend=hc
window=<session>:<address>
hc_session=<session>
hc_terminal=<address>
hc_core_id=<permanent-core-id>
```

`<address>` is hc's terminal address such as `t7`.
Every adapter call sets exactly the recorded `HC_SESSION` and drops any inherited `HC_SOCKET`, which hc would otherwise prefer, so a task keeps reaching its own core even when the caller's environment names another one.
`FM_HC_SOCKET` is the deliberate socket pin tests and labs use instead of an inherited `HC_SOCKET`.
A missing address authorizes recovery only when the core still reports the recorded permanent identity; an absent, malformed, or foreign core binding refuses.
Input and durable inbox re-rings for core-bound task records also require that identity, even if a replacement core reuses the old labels and address.
An input, capture, or close that carries the task label refuses a terminal whose `firstmate.task` or `firstmate.home` label does not match, and a close without a label still refuses a terminal that lacks this home's labels.

## Operations

| Operation | hc command |
| --- | --- |
| Container ensure | `hc server status` plus the `hello` generation handshake over `hc connect` |
| Create task | `hc run --bg --no-parent --outlive-parent --no-notify --cwd <project> --label ...` |
| Capture | `hc read --lines <n>` |
| Visible capture | `hc read --lines 0` |
| Styled composer observation | Framed `terminal.attach` with `observe:true`, checked against `terminal.read`; never sends terminal input or resize frames |
| Send a line and submit | `hc send` |
| Submit with confirmation | `hc send --wait`; see submit safety under Limits |
| Named key | `hc keys` |
| Current path | `hc get`, the foreground process's `cwd` |
| Busy state | `hc get`, native `status.state` (`working` is busy) |
| Agent state | `hc get`, the foreground process and its process group, through the shared classifier |
| Close | `hc kill`, then `hc rm`, then `hc get` must answer not found |

## Persistent secondmates

Local seeded secondmate homes use the ordinary spawn, durable inbox, parent reporting, control, and liveness-recovery paths.
[`bin/fm-hc-secondmate-lib.sh`](../bin/fm-hc-secondmate-lib.sh) owns the native home binding and launch/readiness mechanics.
Startup binds the home lock to the actual harness descendant of the recorded terminal incarnation, so a caller supplying another `FM_HOME` cannot claim it.
Live, malformed, symlinked, or foreign ownership refuses launch without stealing the lock.
A failed readiness check preserves the endpoint and metadata for inspection, including native trust prompts.
Operator hook consent remains required; native secondmate launches keep the home's primary hooks enabled.

Managed hc Codex launches require `--no-daemon`, keeping tool execution inside the hc terminal instead of reusing a shared vendor daemon's environment.
Raw hc Codex commands are refused because the managed launch boundary cannot be established for them.
The secondmate receives its own supervisor endpoint independently of its future worker backend configuration.
Selecting hc for the mate does not change inherited `config/backend`; recovery retains the mate's recorded hc core and session even when that configuration names another backend.

[`agent-control.md`](agent-control.md) owns graceful exit and same-home relaunch.
The native busy signal precedes control's interrupt, and typed exit requires a complete, stable, empty composer observation.
Unknown, pending, changing, or unsupported screens refuse input.
A missing secondmate terminal uses the existing secondmate recovery path, preserves the home and child records, and reuses the app tab label on its replacement.
Children have independent lifetimes and are never stopped by their parent's recovery.
Existing attachment views and legacy endpoints are not adopted or migrated automatically.

## Limits

- `hc send` always presses Enter, so hc cannot type without submitting.
  `bin/fm-spawn.sh` pastes and submits the spawn launch line with `hc send` and consumes the Enter that follows it.
- Submitting a message uses one bounded `hc send --wait`.
  A started turn or a still-working wait confirms it natively; otherwise the adapter falls back to the composer screen, with Enter retries only for a proven pending composer.
  A blocked terminal (exit 9) returns `unknown` without typing or retrying and is never forced.
- hc reports one foreground process per terminal.
  When that process is a launcher, the adapter also reads the rest of its process group from `ps`, which works only for terminals on the local machine.
- Right after a terminal starts, `hc get` can report no foreground process yet, and agent state reads `unreadable` until the shell is up.
- Remote hc secondmates are unsupported.
- A worker inherits `HC_SESSION`, `HC_TERMINAL_ID`, `HC_TERMINAL_SOCKET`, and `HC_SCOPE` from its terminal, and the `config/launch-env-allowlist` floor keeps them; Codex native status and actual tool context are covered by the credentialed lifecycle guard below.
  Native secondmate lifecycle for other harnesses is not live-verified by that guard.
- Naming a Herdr.app space needs the app window and is not done; whether the labels above display as intended in Herdr.app is not verified.
- hc has no event stream this adapter consumes; supervision polls like tmux.

## Tests

`tests/fm-backend-hc.test.sh` pins routing, core identity, busy state, and refusal behavior against a fake `hc` and real process trees.
`tests/fm-hc-secondmate-lock.test.sh` proves native home-lock ancestry and foreign-owner refusal with real processes.
`tests/fm-hc-screen.test.sh` checks the read-only framing contract and complete-screen refusals.
`FM_HC_SECONDMATE_LIVE=1 bin/fm-test-run.sh tests/fm-hc-secondmate-live-e2e.test.sh` exercises a real Codex in a genuinely seeded scratch home, including tool context, correlated replies, lifecycle, and recovery.
`tests/fm-backend-hc-liveness-live-e2e.test.sh` is the default-on live guard: it launches every installed harness bare in a private core and requires `alive`.
`tests/fm-backend-hc-smoke.test.sh` drives the real binary in an isolated lab; [`bin/fm-hc-lab.sh`](../bin/fm-hc-lab.sh) owns the isolation and metadata-tripwire contract, and [`tests/hc-test-safety.sh`](../tests/hc-test-safety.sh) owns guarded test teardown.
The smoke skips when no resolved Core binary or `jq` is available; provisioning and teardown failures fail the test.
For CI coverage, see [`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend); the workflow requires `jq` and rejects the `hc not found` skip.
[`bin/fm-hc-ci-cleanup.sh`](../bin/fm-hc-ci-cleanup.sh) owns job-end cleanup mechanics.
