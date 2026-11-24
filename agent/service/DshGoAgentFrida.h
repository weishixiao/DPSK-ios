#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The dynamic-instrumentation channel.
///
/// Frida is the fastest way to answer a question about a running process without
/// writing a tweak first, and on a RootHide device it needs exactly what the
/// daemon has: a process outside the app sandbox and the entitlement to attach.
/// The app cannot host the server itself, so the daemon owns it.
///
/// Two shapes, deliberately different:
///
/// - a long-lived `frida-server` on loopback, for a client that speaks the Frida
///   protocol and wants a REPL;
/// - `frida.inject`, which runs one script for a bounded time and returns what it
///   printed - a single call that needs no protocol client and no port.
///
/// Nothing here decides what a script may do: the allowlist decided which
/// processes the caller can name, and a script that runs under the daemon's
/// identity can do anything the daemon can. That is why starting the server
/// needs the confirmation flag.

/// Whether the tools exist, whether a server is up, and where it listens.
NSDictionary *DshGoAgentFridaStatus(void);

/// Start `frida-server` on 127.0.0.1:`port`, tracked by a pid file so a later
/// request - or a restarted daemon - can find and stop it.
NSDictionary *_Nullable DshGoAgentFridaStart(uint16_t port, NSError *_Nullable *_Nullable error);

/// Stop the server this daemon started. A server it did not start is left alone:
/// killing something someone else launched is not this call's decision.
BOOL DshGoAgentFridaStop(NSError *_Nullable *_Nullable error);

/// Run `source` against `pid` through `frida-inject` for at most `timeout`
/// seconds, and return what it printed.
///
/// This is not a session: the script is a script, it runs, and the output comes
/// back. A caller that needs to send several messages to one agent should use the
/// server instead, which is what `frida.start` is for.
NSDictionary *_Nullable DshGoAgentFridaInject(pid_t pid,
                                             NSString *source,
                                             NSTimeInterval timeout,
                                             NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END