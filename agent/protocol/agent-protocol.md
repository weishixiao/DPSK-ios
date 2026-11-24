# Agent protocol

The harness is the brain; it never touches another process. Every privileged
action is a message to `dsh-go-agentd`, a launchd daemon outside the app's
sandbox. The app carries the same messages over the same XPC connection, so what
the AI can do is exactly what this document allows — there is no second path.

## Transport

One Mach service, one method:

```objc
// NSXPC, name "io.github.ccch1mneyyy.dshgo.agentd", interface AgentServiceProtocol
- (void)call:(NSData *)payload reply:(void (^)(NSData *reply))reply;
```

`payload` is UTF-8 JSON. Anything larger than 1 MiB is rejected by the service.
The connection is one-way per call: the reply is the answer or the error, and a
request that outlives its deadline is answered `ERR_TIMEOUT` rather than left
hanging.

## Request

```json
{ "id": "4F0C2A1E-...", "method": "probe.listProcesses", "params": {}, "confirmed": false }
```

| field | meaning |
|---|---|
| `id` | UUID the caller generates; echoed in the reply so answers cannot cross |
| `method` | one of the table below |
| `params` | method-specific object; unknown keys are rejected, not ignored |
| `confirmed` | the human pressed the confirmation button for *this* request |

## Reply

```json
{ "id": "4F0C2A1E-...", "ok": true, "result": { } }
{ "id": "4F0C2A1E-...", "ok": false, "error": { "code": "ERR_TARGET_NOT_ALLOWED", "message": "...", "detail": { } } }
```

## Methods

Every method that names a process takes `pid`. Every method that names one of
*the targets* is checked against the allowlist first (see below).

| method | params | result | risk |
|---|---|---|---|
| `probe.ping` | — | `{version, pid, uptime, allowlist}` | none |
| `probe.listProcesses` | — | `{processes:[{pid, uid, name, path, bundleId}]}` | none |
| `probe.modules` | `pid` | `{pid, modules:[{path, base, size}]}` | none |
| `probe.readMemory` | `pid, address, length` | `{hex, base}` | none (read-only) |
| `proc.info` | `pid` | `{pid, name, path, bundleId?, uid, ppid, archs?, arch?, platformBinary?, restricted?, hardened?, debuggable?, entitlements?, attachable, attachError?}` | none (read-only) |
| `proc.attach` | `pid` | `{pid, attachable}` | none — asks for the task port and gives it straight back |
| `mem.scan` | `pid, pattern, start?, end?, limit?` | `{pid, matches:[hex], count, start, end, bounded}` | none (read-only) |
| `mem.write` | `pid, address, hex` | `{written}` | **high** — needs `confirmed` |
| `frida.status` | — | `{available, server, inject, root, running, pid?, port?}` | none |
| `frida.start` | `port?` (default 27042) | `{pid, port, address}` | **high** — needs `confirmed` |
| `frida.stop` | — | `{stopped}` | low — only stops its own child |
| `frida.inject` | `pid, script, timeout?` | `{pid, exit, output, truncated}` | **high** — needs `confirmed` |
| `tweak.write` | `project, files` | `{project, directory, files:[name]}` | low — confined to the projects directory |
| `tweak.compile` / `build.package` | `project, args?` | `{project, artifact, exit, output, truncated}` | low — builds only |
| `pkg.install` | `project` | `{project, package, exit, output, truncated}` | **high** — needs `confirmed` |
| `tweak.inject` | `pid, dylib` | — | **reserved** |

`proc.info` is the answer to "can this target be worked on at all": `attachable`
is the result of an actual `task_for_pid`, and the `csops` fields say what the
target runs with. A field that the kernel would not answer is absent rather than
guessed, so `hardened` missing is not `hardened: false`.

`mem.scan` takes a hex pattern where `??` is a wildcard byte (`"41 ?? 43"` and
`"41??43"` are the same request). `start` defaults to `0x100000000` and `end` to
`0x2000000000`, the arm64 app space; the walk follows `vm_region_recurse_64`, so
unmapped gaps cost one syscall. Matches are capped at 4096, the pattern at 256
bytes, and the daemon reads at most 512 MiB of a target per call; `bounded` says
whether the answer was cut short by the cap rather than being complete.

`probe.ping` also names the jailbreak root the daemon resolved for itself, which
is how a caller learns where its `/usr/bin` actually is on a RootHide device.

`frida.*` is the instrumentation channel. `frida.start` needs `confirmed` because
a listening Frida server exposes everything the daemon can attach to, to any
local process that can open the port; it is tracked by a pid file so a later
request - or a restarted daemon - can stop it, and `frida.stop` only ever stops a
server it started. `frida.inject` is not a session: it writes one script, runs it
through `frida-inject` for a bounded time, and returns what it printed, which is
what a single question needs. A caller that wants to talk to one agent over and
over should start the server and speak its protocol on loopback instead.

`tweak.inject` is reserved: it answers `ERR_NOT_IMPLEMENTED` until the injection
path exists, so a caller cannot mistake silence for success. It is not the same
thing as `frida.inject`: one loads a compiled dylib into a process for good, the
other runs a script for a while.

`tweak.write` writes a Theos project as flat files under
`/var/mobile/Library/DshGoAgent/projects/<name>/`: a source file, a `Makefile`, a
`control`, a `Filter.plist`. Names are plain - no separators, no `..` - because the
project name is what confines the write, and a slash in it would be the write
leaving. A failed write does not leave half a project behind: every name is
validated before the first one is written.

`build.package` runs the toolchain's own `make package` in the project, through
the same executable directories as everything else, so the `make` it uses is the
one under the root that actually exists on this device. A non-zero exit is **not**
an error reply: the compiler's log is the useful part of a failed build, so the
reply carries `exit` and `output` and the caller reads them.

`pkg.install` installs the newest `.deb` in that project's `packages/` and nothing
else - "install what I just built" is deliberately narrower than "install any file
on this device", because `dpkg -i` runs maintainer scripts as root. On RootHide a
dylib `dpkg` placed is not necessarily trusted yet; `jbctl trustcache add` on the
installed dylib is the caller's next step, via `exec.run`, because the path
depends on the package layout rather than on anything the daemon knows.

### Rules the service enforces itself

These are not advice to the harness; they are checks in `DshGoAgentSafety`:

1. **Allowlist.** `/var/mobile/Library/DshGoAgent/allowlist.json` holds
   `{"bundleIds":["..."],"paths":["..."]}`. No pid outside it is attached to.
   The daemon has the permission to inspect anything; the allowlist is what
   keeps that permission to the apps its owner builds.
2. **Confirmation.** `mem.write` refuses an unconfirmed request with
   `ERR_CONFIRMATION_REQUIRED`, and the refusal names the target so a stray
   request in the log is readable.
3. **Bounds.** Memory reads are capped at 64 KiB per call and writes at 4 KiB;
   addresses must be 16-hex-digit strings, lengths integers in range, pids in
   `1...99999`. A malformed value is `ERR_BAD_PARAMS` and never reaches syscall.
4. **No shell.** `tweak.compile` runs `/usr/bin/make` with an argv array. The
   project name must match `^[A-Za-z0-9._-]+$` and resolve inside
   `/var/mobile/Library/DshGoAgent/projects`; nothing from a request is ever
   concatenated into a command string.
5. **Isolation.** The daemon catches every exception per request and answers an
   error: a bad message must not take down a daemon the whole workbench depends
   on. This is also why the privileged side is a daemon and not SpringBoard.

## Log

Every request is appended to `/var/mobile/Library/DshGoAgent/agentd.log` as one
line: time, id, method, target, outcome. The chat panel tails this file, so what
the UI shows as tool output is the same record the daemon wrote.
