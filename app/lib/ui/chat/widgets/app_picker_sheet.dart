// The composer's 应用 sheet: every installed app, by name, filtered as you type.
//
// Selecting one does not attach a file and does not start a call. It puts a
// single message into the conversation naming the app — display name and bundle
// identifier — so the model has something concrete to reason about. That is the
// whole hand-off: the app itself is never launched, inspected or attached to.

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../phone/phone_channel.dart';
import '../../common/app_sheet.dart';

/// Opens the picker. Returns the chosen app, or null when dismissed.
Future<InstalledApp?> showAppPickerSheet(BuildContext context, {required PhoneChannel channel}) {
  return showAppSheet<InstalledApp>(
    context,
    isScrollControlled: true,
    builder: (_) => _AppPicker(channel: channel),
  );
}

class _AppPicker extends StatefulWidget {
  const _AppPicker({required this.channel});

  final PhoneChannel channel;

  @override
  State<_AppPicker> createState() => _AppPickerState();
}

class _AppPickerState extends State<_AppPicker> {
  late Future<List<InstalledApp>> _apps = widget.channel.installedApps();
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                autofocus: true,
                decoration: InputDecoration(
                  hintText: l10n.chatAppsTile,
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (value) => setState(() => _query = value.trim().toLowerCase()),
              ),
            ),
            Expanded(
              child: FutureBuilder<List<InstalledApp>>(
                future: _apps,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final all = snapshot.data ?? const <InstalledApp>[];
                  final shown = _query.isEmpty
                      ? all
                      : all
                          .where((a) =>
                              a.name.toLowerCase().contains(_query) || a.bundleId.toLowerCase().contains(_query))
                          .toList();
                  if (shown.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(all.isEmpty ? phoneNotReadyReason : l10n.chatAppsTile,
                            style: Theme.of(context).textTheme.bodyMedium),
                      ),
                    );
                  }
                  return ListView.builder(
                    itemCount: shown.length,
                    itemBuilder: (context, index) {
                      final app = shown[index];
                      return ListTile(
                        title: Text(app.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(app.bundleId, maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () => Navigator.pop(context, app),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
