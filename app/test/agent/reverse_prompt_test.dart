import 'package:dsh_app/agent/reverse_prompt.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('routing', () {
    test('no target is the general chat', () {
      expect(modeFor(null), AgentMode.chat);
    });

    test('a target is the reverse conversation', () {
      const AgentTarget target = AgentTarget(pid: 42, name: 'Settings');
      expect(modeFor(target), AgentMode.reverse);
    });

    test('clearing the target is a chat again, without other state', () {
      const AgentTarget target = AgentTarget(pid: 42, name: 'Settings');
      expect(modeFor(target), AgentMode.reverse);
      expect(modeFor(null), AgentMode.chat);
    });
  });

  group('proc.info to target', () {
    test('keeps what the daemon answered', () {
      final AgentTarget target = AgentTarget.fromProcessInfo(<String, Object?>{
        'pid': 4242,
        'name': 'SpringBoard',
        'bundleId': 'com.apple.springboard',
        'path': '/System/Library/CoreServices/SpringBoard.app/SpringBoard',
        'arch': 'arm64e',
        'archs': <Object?>['arm64', 'arm64e'],
        'attachable': true,
        'entitlements': <Object?>['platform-application', 'task_for_pid-allow'],
        'hardened': false,
        'platformBinary': true,
      });
      expect(target.pid, 4242);
      expect(target.label, 'com.apple.springboard');
      expect(target.archs, <String>['arm64', 'arm64e']);
      expect(target.attachable, isTrue);
      expect(target.entitlements, contains('task_for_pid-allow'));
      expect(target.hardened, isFalse);
      expect(target.platformBinary, isTrue);
    });

    test('a missing csops answer stays unknown rather than becoming false', () {
      final AgentTarget target = AgentTarget.fromProcessInfo(<String, Object?>{
        'pid': 7,
        'name': 'helper',
        'attachable': false,
      });
      // The daemon omits a field the kernel would not answer; the app must not
      // invent "not hardened" or "not a platform binary" from that silence.
      expect(target.hardened, isNull);
      expect(target.platformBinary, isNull);
      expect(target.arch, isNull);
      expect(target.entitlements, isEmpty);
      expect(target.label, 'helper');
    });

    test('a numeric pid that arrives as a string still parses', () {
      final AgentTarget target = AgentTarget.fromProcessInfo(<String, Object?>{'pid': '99', 'name': 'x'});
      expect(target.pid, 99);
    });
  });

  group('the context block', () {
    const AgentTarget attached = AgentTarget(
      pid: 900,
      name: 'Demo',
      bundleId: 'com.example.demo',
      path: '/private/var/containers/Bundle/Application/Demo.app/Demo',
      arch: 'arm64',
      archs: <String>['arm64', 'arm64e'],
      attachable: true,
      entitlements: <String>['get-task-allow'],
    );

    test('names the target the daemon reported', () {
      final String block = reverseContextBlock(attached);
      expect(block, contains('pid: 900'));
      expect(block, contains('bundleId: com.example.demo'));
      expect(block, contains('path: /private/var/containers/Bundle/Application/Demo.app/Demo'));
      expect(block, contains('attachable: true'));
    });

    test('a fat binary is called out before a hook is proposed', () {
      expect(reverseContextBlock(attached), contains('arm64e'));
      expect(reverseContextBlock(attached), contains('fat'));
    });

    test('an unattachable target says what is blocked instead of pretending', () {
      const AgentTarget blocked = AgentTarget(pid: 1, name: 'blocked', attachable: false);
      final String block = reverseContextBlock(blocked);
      expect(block, contains('attachable: false'));
      expect(block, contains('could not get a task port'));
      // The attachable branch is the one that proposes dynamic work; a blocked
      // target must not get it.
      expect(block, isNot(contains('Prefer the cheapest evidence first')));
    });

    test('the deliverable and the scope are both stated', () {
      final String block = reverseContextBlock(attached);
      expect(block, contains('Tweak.xm'));
      expect(block, contains('ARCHS = arm64 arm64e'));
      expect(block, contains('Filter.plist'));
      expect(block, contains('confirm'));
      expect(block, contains('learning and security research'));
    });

    test('the entitlements are listed, or their absence is stated', () {
      expect(reverseContextBlock(attached), contains('get-task-allow'));
      const AgentTarget bare = AgentTarget(pid: 2, name: 'bare', attachable: true);
      expect(reverseContextBlock(bare), contains('(none reported)'));
    });
  });
}