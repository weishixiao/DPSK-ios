import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart' show MethodChannel, MissingPluginException, PlatformException;

/// The app's half of the privileged service, as a typed client.
///
/// The channel is deliberately one method wide (`call`): the daemon already has a
/// request envelope, and giving Flutter a second schema would mean two descriptions
/// of the same protocol drifting apart. Everything here is a thin, typed view of
/// that envelope - the daemon still decides what is allowed.
///
/// Nothing in this file holds a task port or a pid handle. A reply is a record of
/// what the daemon did, which is why the app can show it without being trusted
/// with the capability itself.
class AgentClient {
  AgentClient({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('dsh/agent');

  static final AgentClient instance = AgentClient();

  final MethodChannel _channel;

  /// Whether the daemon answered the last time anything asked. A daemon that is
  /// not installed is the normal case on a device without a jailbreak, so callers
  /// are expected to treat "unavailable" as an answer rather than an error.
  bool get isSupported => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  Future<AgentReply> call(
    String method, {
    Map<String, Object?> params = const <String, Object?>{},
    bool confirmed = false,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!isSupported) {
      return const AgentReply.unavailable();
    }
    try {
      final Object? reply = await _channel.invokeMethod<Object?>('call', <String, Object?>{
        'method': method,
        'params': params,
        'confirmed': confirmed,
        'timeout': timeout.inMilliseconds / 1000,
      });
      return AgentReply.fromChannel(reply);
    } on PlatformException catch (error) {
      return AgentReply.failed(AgentError('ERR_CHANNEL', error.message ?? error.code));
    } on MissingPluginException {
      return const AgentReply.unavailable();
    }
  }

  Future<AgentReply> available() async {
    if (!isSupported) return const AgentReply.unavailable();
    try {
      final bool? present = await _channel.invokeMethod<bool>('available');
      return AgentReply.ok(<String, Object?>{'available': present ?? false});
    } on PlatformException catch (error) {
      return AgentReply.failed(AgentError('ERR_CHANNEL', error.message ?? error.code));
    } on MissingPluginException {
      return const AgentReply.unavailable();
    }
  }

  /// The apps the allowlist permits, as the picker shows them.
  Future<AgentReply> listProcesses() => call('probe.listProcesses');

  /// Everything the daemon knows about one target, including whether a write
  /// would even be possible (`attachable`) and the entitlements it runs with.
  Future<AgentReply> processInfo(int pid) =>
      call('proc.info', params: <String, Object?>{'pid': pid});

  /// Searches one of the owner's processes for a byte pattern.
  ///
  /// The map is built by assignment rather than with collection-`if`, because a
  /// key whose value is `null` and a key that is absent mean different things to
  /// the daemon: absent uses its default, `null` is a rejected parameter.
  Future<AgentReply> scan(
    int pid, {
    required String pattern,
    String? start,
    String? end,
    int? limit,
  }) {
    final Map<String, Object?> params = <String, Object?>{'pid': pid, 'pattern': pattern};
    if (start != null) params['start'] = start;
    if (end != null) params['end'] = end;
    if (limit != null) params['limit'] = limit;
    return call('mem.scan', params: params);
  }

  Future<AgentReply> readMemory(int pid, {required String address, required int length}) =>
      call('probe.readMemory', params: <String, Object?>{
        'pid': pid,
        'address': address,
        'length': length,
      });

  /// Writes need `confirmed`: the flag is the human's answer, so a caller passes
  /// what the person actually agreed to rather than a default it chose itself.
  Future<AgentReply> writeMemory(int pid, {required String address, required String hex}) =>
      call('mem.write', params: <String, Object?>{
        'pid': pid,
        'address': address,
        'hex': hex,
      }, confirmed: true);

  Future<AgentReply> fridaStatus() => call('frida.status');

  Future<AgentReply> fridaInject(int pid, {required String script, int timeout = 15}) =>
      call('frida.inject', params: <String, Object?>{
        'pid': pid,
        'script': script,
        'timeout': timeout,
      }, confirmed: true);

  Future<AgentReply> writeTweak(String project, Map<String, String> files) =>
      call('tweak.write', params: <String, Object?>{'project': project, 'files': files});

  Future<AgentReply> buildPackage(String project) =>
      call('tweak.compile', params: <String, Object?>{'project': project},
          timeout: const Duration(minutes: 10));

  Future<AgentReply> installPackage(String project) =>
      call('pkg.install', params: <String, Object?>{'project': project}, confirmed: true);
}

/// One reply from the daemon: either a result or an error, never both.
class AgentReply {
  const AgentReply._(this.ok, this.result, this.error);

  const AgentReply.unavailable()
      : ok = false,
        result = null,
        error = const AgentError('ERR_AGENT_UNAVAILABLE',
            'the privileged service is not installed on this device');

  factory AgentReply.ok(Map<String, Object?> result) =>
      AgentReply._(true, Map<String, Object?>.unmodifiable(result), null);

  factory AgentReply.failed(AgentError error) => AgentReply._(false, null, error);

  /// The daemon answers `{ok: bool, result?, error?: {code, message}}`.
  factory AgentReply.fromChannel(Object? reply) {
    if (reply is! Map<Object?, Object?>) {
      return AgentReply.failed(const AgentError('ERR_INTERNAL', 'the reply was not an object'));
    }
    final Map<String, Object?> json = reply.cast<String, Object?>();
    if (json['ok'] != true) {
      final Object? raw = json['error'];
      if (raw is Map<Object?, Object?>) {
        final Map<String, Object?> failure = raw.cast<String, Object?>();
        return AgentReply.failed(AgentError(
          failure['code']?.toString() ?? 'ERR_INTERNAL',
          failure['message']?.toString() ?? 'the service refused the request',
        ));
      }
      return AgentReply.failed(const AgentError('ERR_INTERNAL', 'the service refused the request'));
    }
    final Object? body = json['result'];
    return AgentReply.ok(body is Map<Object?, Object?> ? body.cast<String, Object?>() : const <String, Object?>{});
  }

  final bool ok;
  final Map<String, Object?>? result;
  final AgentError? error;

  /// The error code when this failed, `null` when it did not.
  String? get code => error?.code;
}

class AgentError {
  const AgentError(this.code, this.message);

  /// `ERR_AGENT_UNAVAILABLE` and `ERR_CONFIRMATION_REQUIRED` are the two the UI
  /// acts on: the first is "there is no daemon here", the second is "ask first".
  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}