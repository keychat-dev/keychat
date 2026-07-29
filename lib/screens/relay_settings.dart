import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:workspace/l10n/app_localizations.dart';
import 'package:workspace/screens/login.dart';
import 'package:workspace/services/account_sync.dart';
import 'package:workspace/src/rust/api/relay.dart' as relay_api;

/// Lets the user view, add, and remove the Nostr relay URLs this device
/// uses. Persisted as JSON on the Rust side (relays.json), separate from
/// the display profile.
class RelaySettingsScreen extends StatefulWidget {
  const RelaySettingsScreen({super.key, this.onContinue});

  /// When set, this screen is being shown as an onboarding step (right
  /// after profile setup): a "Continue" button is shown at the bottom
  /// instead of expecting the user to navigate back manually.
  final VoidCallback? onContinue;

  @override
  State<RelaySettingsScreen> createState() => _RelaySettingsScreenState();
}

class _RelaySettingsScreenState extends State<RelaySettingsScreen> {
  final _urlController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  List<String> _urls = [];
  bool _loading = true;

  // null = not checked yet, otherwise online/offline per URL.
  final Map<String, bool?> _status = {};
  bool _checkingStatus = false;

  @override
  void initState() {
    super.initState();
    _loadRelays();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _loadRelays() async {
    final storageDir = await getApplicationDocumentsDirectory();
    final relayList = await relay_api.loadRelayList(storageDir: storageDir.path);
    setState(() {
      _urls = relayList.urls;
      _loading = false;
    });
    _checkStatuses();
  }

  Future<void> _checkStatuses() async {
    if (_urls.isEmpty) return;
    setState(() => _checkingStatus = true);
    final results = await relay_api.checkRelayStatuses(urls: _urls);
    if (!mounted) return;
    setState(() {
      for (var i = 0; i < _urls.length; i++) {
        _status[_urls[i]] = results[i];
      }
      _checkingStatus = false;
    });
  }

  Future<void> _persist() async {
    final storageDir = await getApplicationDocumentsDirectory();
    await relay_api.saveRelayList(storageDir: storageDir.path, urls: _urls);
    unawaited(announceRelayListUpdate());
  }

  void _addRelay() {
    if (!_formKey.currentState!.validate()) return;
    final url = _urlController.text.trim();
    setState(() {
      _urls = [..._urls, url];
      _urlController.clear();
    });
    _persist();
    _checkStatuses();
  }

  Future<void> _removeRelay(String url) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: KeychatColors.background,
          title: Text(l10n.removeRelayConfirmTitle),
          content: Text(l10n.removeRelayConfirmBody(url)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(MaterialLocalizations.of(dialogContext).cancelButtonLabel),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.removeRelay),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;

    setState(() {
      _urls = _urls.where((u) => u != url).toList();
      _status.remove(url);
    });
    _persist();
  }

  Future<void> _editRelay(String oldUrl) async {
    final newUrl = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _EditRelayDialog(initialUrl: oldUrl),
    );
    if (newUrl == null || newUrl == oldUrl) return;

    setState(() {
      final index = _urls.indexOf(oldUrl);
      final urls = [..._urls];
      urls[index] = newUrl;
      _urls = urls;
      _status.remove(oldUrl);
    });
    _persist();
    _checkStatuses();
  }

  void _reorderRelay(int oldIndex, int newIndex) {
    setState(() {
      final urls = [..._urls];
      final url = urls.removeAt(oldIndex);
      urls.insert(newIndex, url);
      _urls = urls;
    });
    _persist();
  }

  Future<void> _resetToDefaults() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: KeychatColors.background,
          title: Text(l10n.resetRelaysConfirmTitle),
          content: Text(l10n.resetRelaysConfirmBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(MaterialLocalizations.of(dialogContext).cancelButtonLabel),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.resetButton),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;

    final defaults = await relay_api.defaultRelays();
    if (!mounted) return;
    setState(() {
      _urls = defaults;
      _status.clear();
    });
    _persist();
    _checkStatuses();
  }

  String? _validateUrl(String? value) {
    final url = value?.trim() ?? '';
    final l10n = AppLocalizations.of(context)!;
    if (!url.startsWith('wss://') && !url.startsWith('ws://')) {
      return l10n.invalidRelayUrl;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: KeychatColors.background,
      appBar: AppBar(
        backgroundColor: KeychatColors.background,
        elevation: 0,
        foregroundColor: KeychatColors.textPrimary,
        title: Text(l10n.relaySettingsTitle),
        actions: [
          IconButton(
            onPressed: _resetToDefaults,
            tooltip: l10n.resetRelays,
            icon: const Icon(Icons.restart_alt),
          ),
          IconButton(
            onPressed: _checkingStatus ? null : _checkStatuses,
            icon: _checkingStatus
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Form(
                      key: _formKey,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _urlController,
                              decoration: _inputDecoration(l10n.relayUrlLabel),
                              validator: _validateUrl,
                            ),
                          ),
                          const SizedBox(width: 12),
                          SizedBox(
                            height: 52,
                            child: ElevatedButton(
                              onPressed: _addRelay,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: KeychatColors.primaryDark,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: Text(l10n.addRelay),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.relayCountHint,
                      style: TextStyle(
                        fontSize: 12,
                        color: KeychatColors.textSecondary.withValues(alpha: 0.8),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Expanded(child: _buildRelayList(l10n)),
                    if (widget.onContinue != null) ...[
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: ElevatedButton(
                          onPressed: widget.onContinue,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: KeychatColors.primaryDark,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(l10n.confirmButton),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildRelayList(AppLocalizations l10n) {
    if (_urls.isEmpty) {
      return Center(
        child: Text(
          l10n.noRelaysYet,
          style: const TextStyle(fontSize: 15, color: KeychatColors.textSecondary),
        ),
      );
    }
    return ReorderableListView.builder(
      itemCount: _urls.length,
      buildDefaultDragHandles: false,
      onReorderItem: _reorderRelay,
      proxyDecorator: (child, index, animation) {
        return Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          elevation: 4,
          shadowColor: Colors.black38,
          child: child,
        );
      },
      itemBuilder: (context, index) {
        final url = _urls[index];
        return _QuickDragStartListener(
          key: ValueKey(url),
          index: index,
          delay: const Duration(milliseconds: 200),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              decoration: BoxDecoration(
                color: KeychatColors.surface,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  _StatusDot(status: _status[url]),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      url,
                      style: const TextStyle(fontSize: 14, color: KeychatColors.textPrimary),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    onPressed: () => _editRelay(url),
                    tooltip: l10n.editRelay,
                    icon: const Icon(
                      Icons.edit_outlined,
                      size: 20,
                      color: KeychatColors.textSecondary,
                    ),
                  ),
                  IconButton(
                    onPressed: () => _removeRelay(url),
                    tooltip: l10n.removeRelay,
                    icon: const Icon(
                      Icons.close,
                      size: 20,
                      color: KeychatColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  InputDecoration _inputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      filled: true,
      fillColor: KeychatColors.surface,
      labelStyle: TextStyle(color: KeychatColors.textSecondary),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: KeychatColors.primary, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    );
  }
}

/// Dialog content for editing a relay URL in place. A dedicated
/// StatefulWidget so the TextEditingController's lifecycle (dispose) is
/// tied to the dialog's own element, not the caller's async gap — disposing
/// it manually right after `Navigator.pop()` races the dialog's exit
/// animation and crashes.
class _EditRelayDialog extends StatefulWidget {
  const _EditRelayDialog({required this.initialUrl});

  final String initialUrl;

  @override
  State<_EditRelayDialog> createState() => _EditRelayDialogState();
}

class _EditRelayDialogState extends State<_EditRelayDialog> {
  late final _controller = TextEditingController(text: widget.initialUrl);
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      backgroundColor: KeychatColors.background,
      title: Text(l10n.editRelay),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: l10n.relayUrlLabel,
            filled: true,
            fillColor: KeychatColors.surface,
            labelStyle: TextStyle(color: KeychatColors.textSecondary),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: KeychatColors.primary, width: 1.5),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          ),
          validator: (value) {
            final url = value?.trim() ?? '';
            return (!url.startsWith('wss://') && !url.startsWith('ws://'))
                ? l10n.invalidRelayUrl
                : null;
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        TextButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            Navigator.of(context).pop(_controller.text.trim());
          },
          child: Text(l10n.continueButton),
        ),
      ],
    );
  }
}

/// Like [ReorderableDelayedDragStartListener], but with a shorter long-press
/// delay before the drag starts (the default ~500ms feels sluggish here).
class _QuickDragStartListener extends ReorderableDragStartListener {
  const _QuickDragStartListener({
    super.key,
    required super.child,
    required super.index,
    required this.delay,
  });

  final Duration delay;

  @override
  MultiDragGestureRecognizer createRecognizer() {
    return DelayedMultiDragGestureRecognizer(delay: delay, debugOwner: this);
  }
}

/// Small colored dot showing whether a relay is reachable: grey while
/// unchecked/checking, green if online, red if offline.
class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});

  final bool? status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      true => Colors.green,
      false => Colors.red,
      null => KeychatColors.textSecondary.withValues(alpha: 0.4),
    };
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
