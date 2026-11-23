# Agent protocol

The harness is the brain; it never touches another process. Every privileged
action is a message to `dpsk-agentd`, a launchd daemon outside the app's
sandbox. The app carries the same messages over the same XPC connection, so what
the AI can do is exactly what this document allows — there is no second path.

## Transport

One Mach service, one method:

```objc
// NSXPC, name "com.dpsk.agentd", interface AgentServiceProtocol
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
| `mem.write` | `pid, address, hex` | `{written}` | **high** — needs `confirmed` |
| `tweak.compile` | `project, args?` | `{artifact, log}` | low — builds only |
| `tweak.inject` | `pid, dylib` | — | **reserved** |

`tweak.inject` is reserved: it answers `ERR_NOT_IMPLEMENTED` until the injection
path exists, so a caller cannot mistake silence for success.

### Rules the service enforces itself

These are not advice to the harness; they are checks in `DPSKAgentSafety`:

1. **Allowlist.** `/var/mobile/Library/DPSKAgent/allowlist.json` holds
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
   `/var/mobile/Library/DPSKAgent/projects`; nothing from a request is ever
   concatenated into a command string.
5. **Isolation.** The daemon catches every exception per request and answers an
   error: a bad message must not take down a daemon the whole workbench depends
   on. This is also why the privileged side is a daemon and not SpringBoard.

## Log

Every request is appended to `/var/mobile/Library/DPSKAgent/agentd.log` as one
line: time, id, method, target, outcome. The chat panel tails this file, so what
the UI shows as tool output is the same record the daemon wrote.
