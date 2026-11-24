/// The reverse-engineering half of the chat, as pure functions.
///
/// One window serves both jobs: an ordinary question goes to the general agent,
/// and the moment a person picks a process the conversation is *about that
/// process*. The switch is a value, not a mode the UI remembers in several
/// places: `modeFor` answers it from the target alone, so a target that is
/// cleared is a chat again by construction.
///
/// Nothing here talks to the daemon. What a target *is* comes from `proc.info`;
/// what to say about it, and which instructions to give the model, is decided
/// here, where it can be tested without a device.
library;

enum AgentMode { chat, reverse }

class AgentTarget {
  const AgentTarget({
    required this.pid,
    required this.name,
    this.bundleId,
    this.path,
    this.arch,
    this.archs = const <String>[],
    this.attachable = false,
    this.entitlements = const <String>[],
    this.hardened,
    this.platformBinary,
  });

  /// Builds a target from the daemon's `proc.info` reply. Fields the daemon could
  /// not answer stay absent rather than being given a plausible default: an
  /// unknown `hardened` is not "not hardened", and the prompt says so.
  factory AgentTarget.fromProcessInfo(Map<String, Object?> json) {
    final Object? archs = json['archs'];
    final Object? entitlements = json['entitlements'];
    final Object? hardened = json['hardened'];
    final Object? platformBinary = json['platformBinary'];
    return AgentTarget(
      pid: _int(json['pid']) ?? 0,
      name: json['name']?.toString() ?? 'pid ${json['pid']}',
      bundleId: json['bundleId']?.toString(),
      path: json['path']?.toString(),
      arch: json['arch']?.toString(),
      archs: archs is List<Object?> ? archs.map((Object? item) => item.toString()).toList() : const <String>[],
      attachable: json['attachable'] == true,
      entitlements: entitlements is List<Object?>
          ? entitlements.map((Object? item) => item.toString()).toList()
          : const <String>[],
      hardened: hardened is bool ? hardened : null,
      platformBinary: platformBinary is bool ? platformBinary : null,
    );
  }

  final int pid;
  final String name;
  final String? bundleId;
  final String? path;
  final String? arch;
  final List<String> archs;

  /// Whether a `task_for_pid` succeeded when the daemon asked. This is the field
  /// that decides if the rest is actionable at all.
  final bool attachable;
  final List<String> entitlements;
  final bool? hardened;
  final bool? platformBinary;

  /// What the picker and the chip show.
  String get label => bundleId ?? name;

  Map<String, Object?> toJson() => <String, Object?>{
        'pid': pid,
        'name': name,
        if (bundleId != null) 'bundleId': bundleId,
        if (path != null) 'path': path,
        if (arch != null) 'arch': arch,
        if (archs.isNotEmpty) 'archs': archs,
        'attachable': attachable,
        if (entitlements.isNotEmpty) 'entitlements': entitlements,
        if (hardened != null) 'hardened': hardened,
        if (platformBinary != null) 'platformBinary': platformBinary,
      };

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }
}

/// Which conversation this is.
AgentMode modeFor(AgentTarget? target) => target == null ? AgentMode.chat : AgentMode.reverse;

/// The block that turns a general assistant into an analysis of one process.
///
/// It is a context block rather than a system message because the window stays
/// the same window: the person can still ask a general question with a target
/// picked, and the block is what keeps the answer about the target when it is.
String reverseContextBlock(AgentTarget target) {
  final StringBuffer buffer = StringBuffer()
    ..writeln('[target]')
    ..writeln('pid: ${target.pid}');
  if (target.bundleId != null) buffer.writeln('bundleId: ${target.bundleId}');
  if (target.path != null) buffer.writeln('path: ${target.path}');
  if (target.arch != null) buffer.writeln('arch: ${target.arch}');
  if (target.archs.length > 1) buffer.writeln('archs: ${target.archs.join(', ')}');
  if (target.platformBinary != null) buffer.writeln('platformBinary: ${target.platformBinary}');
  if (target.hardened != null) buffer.writeln('hardened: ${target.hardened}');
  buffer
    ..writeln('attachable: ${target.attachable}')
    ..writeln('entitlements: ${target.entitlements.isEmpty ? '(none reported)' : target.entitlements.join(', ')}')
    ..writeln()
    ..writeln('[how to work on this target]');

  if (!target.attachable) {
    buffer.writeln(
      'The daemon could not get a task port for this process. Static analysis is still '
      'possible (read the binary, its entitlements and its strings); say what is blocked '
      'before proposing dynamic work, and name the entitlement or trust-cache entry that '
      'would change the answer.',
    );
  } else {
    buffer.writeln(
      'The process is attachable. Prefer the cheapest evidence first: static reading, then '
      'one `mem.scan` or `frida.inject` to confirm a hypothesis, then a hook only for what '
      'the previous two could not show.',
    );
  }
  buffer
    ..writeln()
    ..writeln('Rules for this target:')
    ..writeln('- Name addresses as the daemon reports them: hex strings, no 0x, no leading zeros.');
  if (target.archs.length > 1) {
    buffer.writeln(
      '- The binary is fat (${target.archs.join(' + ')}); a hook must be built for arm64e as '
      'well as arm64, or it will only load in one of them.',
    );
  }
  buffer
    ..writeln('- Every write needs the person to confirm it; ask for that in words, do not assume it.')
    ..writeln('- Deliverables are files a Theos build can compile: `Tweak.xm`, `Makefile` with '
        '`ARCHS = arm64 arm64e`, and a `Filter.plist` naming this bundle id.')
    ..writeln('- Scope: this is the owner\'s own device, for learning and security research. '
        'Refuse requests that target someone else\'s device, paid services, or another '
        'person\'s data.')
    ..writeln()
    ..writeln('The person\'s question about this target:');
  return buffer.toString();
}