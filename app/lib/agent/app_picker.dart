import 'package:dsh_app/agent/agent_client.dart';
import 'package:dsh_app/agent/reverse_prompt.dart';
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

/// The app picker: the front door of the reverse flow.
///
/// It lists what the daemon's allowlist permits - only apps, only ones the
/// daemon can name - and, on selection, asks for `proc.info` so what the caller
/// receives is a target with the architecture, entitlements and `attachable`
/// answer filled in, not a bare pid. A daemon that is not installed is an empty
/// answer with a reason, not an exception: the sheet says so and stays open.
///
/// Returns the chosen target, or null when the person closed it.
Future<AgentTarget?> showAgentAppPicker(BuildContext context) {
  return showModalBottomSheet<AgentTarget>(
    context: context,
    isScrollControlled: true,
    builder: (BuildContext sheetContext) => const AgentAppPicker(),
  );
}

class AgentAppPicker extends StatefulWidget {
  const AgentAppPicker({super.key});

  @override
  State<AgentAppPicker> createState() => _AgentAppPickerState();
}

class _AgentAppPickerState extends State<AgentAppPicker> {
  final TextEditingController _query = TextEditingController();
  List<AgentTarget> _apps = const <AgentTarget>[];
  bool _loading = true;
  String? _failure;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final AgentReply reply = await AgentClient.instance.listProcesses();
    if (!mounted) return;
    final Object? processes = reply.result?['processes'];
    final List<AgentTarget> apps = <AgentTarget>[];
    if (reply.ok && processes is List<Object?>) {
      for (final Object? entry in processes) {
        if (entry is Map<Object?, Object?>) {
          final AgentTarget target = AgentTarget.fromProcessInfo(entry.cast<String, Object?>());
          if (target.bundleId != null) apps.add(target);
        }
      }
      apps.sort((AgentTarget a, AgentTarget b) => a.label.compareTo(b.label));
    }
    setState(() {
      _loading = false;
      _apps = apps;
      _failure = reply.ok ? null : (reply.error?.message ?? reply.code);
    });
  }

  /// The daemon only reports app bundles, and the allowlist is the daemon's
  /// decision; this filter is on top of that, for what the person typed.
  List<AgentTarget> get _filtered {
    final String needle = _query.text.trim().toLowerCase();
    if (needle.isEmpty) return _apps;
    return _apps
        .where((AgentTarget app) =>
            app.label.toLowerCase().contains(needle) || (app.name.toLowerCase().contains(needle)))
        .toList();
  }

  Future<void> _pick(AgentTarget app) async {
    final AgentReply reply = await AgentClient.instance.processInfo(app.pid);
    if (!mounted) return;
    if (!reply.ok) {
      setState(() => _failure = reply.error?.message ?? reply.code);
      return;
    }
    Navigator.of(context).pop(AgentTarget.fromProcessInfo(reply.result ?? const <String, Object?>{}));
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context)!;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(l10n.agentTargetPick, style: Theme.of(context).textTheme.titleMedium),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _query,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(hintText: l10n.agentTargetSearch, isDense: true),
                ),
              ),
              Expanded(child: _body(l10n)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(AppLocalizations l10n) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_failure != null && _apps.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
            l10n.agentTargetUnavailable,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    }
    final List<AgentTarget> apps = _filtered;
    if (apps.isEmpty) {
      return Center(child: Text(l10n.agentTargetEmpty, style: Theme.of(context).textTheme.bodySmall));
    }
    return ListView.builder(
      itemCount: apps.length,
      itemBuilder: (BuildContext context, int index) {
        final AgentTarget app = apps[index];
        return ListTile(
          leading: const Icon(Icons.apps_outlined),
          title: Text(app.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: app.bundleId == null
              ? null
              : Text(app.bundleId!, maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: () => _pick(app),
        );
      },
    );
  }
}