import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:workspace/l10n/app_localizations.dart';
import 'package:workspace/screens/login.dart';
import 'package:workspace/src/rust/api/attachment.dart' as attachment_api;

/// Lets the user view, add, and remove Blossom-compatible file upload
/// servers — same shape as [RelaySettingsScreen]'s relay list, but with one
/// server always marked "default" (the one actually used for uploads,
/// unless a fallback is picked from the switch-server dialog after a failed
/// send). The default server is shown on its own, highlighted, above the
/// rest of the list.
class AttachmentServerSettingsScreen extends StatefulWidget {
  const AttachmentServerSettingsScreen({super.key});

  @override
  State<AttachmentServerSettingsScreen> createState() => _AttachmentServerSettingsScreenState();
}

class _AttachmentServerSettingsScreenState extends State<AttachmentServerSettingsScreen> {
  final _urlController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  List<String> _urls = [];
  String? _defaultUrl;
  bool _loading = true;

  final Map<String, bool?> _status = {};
  bool _checkingStatus = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final storageDir = await getApplicationDocumentsDirectory();
    final list = await attachment_api.loadUploadServers(storageDir: storageDir.path);
    if (!mounted) return;
    setState(() {
      _urls = list.urls;
      _defaultUrl = list.defaultUrl;
      _loading = false;
    });
    _checkStatuses();
  }

  Future<void> _checkStatuses() async {
    if (_urls.isEmpty) return;
    setState(() => _checkingStatus = true);
    final results = await Future.wait(
      _urls.map((url) async {
        try {
          return await attachment_api.checkUploadServerStatus(url: url);
        } catch (_) {
          return false;
        }
      }),
    );
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
    await attachment_api.saveUploadServers(
      storageDir: storageDir.path,
      urls: _urls,
      defaultUrl: _defaultUrl!,
    );
  }

  void _addServer() {
    if (!_formKey.currentState!.validate()) return;
    final url = _urlController.text.trim();
    setState(() {
      _urls = [..._urls, url];
      _defaultUrl ??= url;
      _urlController.clear();
    });
    _persist();
    _checkStatuses();
  }

  Future<void> _removeServer(String url) async {
    final l10n = AppLocalizations.of(context)!;
    if (_urls.length <= 1) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.cannotRemoveOnlyServer)));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: KeychatColors.background,
        title: Text(l10n.removeAttachmentServerConfirmTitle),
        content: Text(l10n.removeAttachmentServerConfirmBody(url)),
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
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _urls = _urls.where((u) => u != url).toList();
      _status.remove(url);
      if (_defaultUrl == url) _defaultUrl = _urls.first;
    });
    _persist();
  }

  Future<void> _editServer(String oldUrl) async {
    final newUrl = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _EditServerDialog(initialUrl: oldUrl),
    );
    if (newUrl == null || newUrl == oldUrl) return;
    setState(() {
      final index = _urls.indexOf(oldUrl);
      final urls = [..._urls];
      urls[index] = newUrl;
      _urls = urls;
      _status.remove(oldUrl);
      if (_defaultUrl == oldUrl) _defaultUrl = newUrl;
    });
    _persist();
    _checkStatuses();
  }

  void _setAsDefault(String url) {
    setState(() => _defaultUrl = url);
    _persist();
  }

  Future<void> _resetToDefaults() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: KeychatColors.background,
        title: Text(l10n.resetAttachmentServersConfirmTitle),
        content: Text(l10n.resetAttachmentServersConfirmBody),
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
      ),
    );
    if (confirmed != true) return;
    final defaults = await attachment_api.defaultUploadServers();
    if (!mounted) return;
    setState(() {
      _urls = defaults;
      _defaultUrl = defaults.first;
      _status.clear();
    });
    _persist();
    _checkStatuses();
  }

  String? _validateUrl(String? value) {
    final url = value?.trim() ?? '';
    final l10n = AppLocalizations.of(context)!;
    if (!url.startsWith('https://') && !url.startsWith('http://')) {
      return l10n.invalidAttachmentServerUrl;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final others = _urls.where((u) => u != _defaultUrl).toList();
    return Scaffold(
      backgroundColor: KeychatColors.background,
      appBar: AppBar(
        backgroundColor: KeychatColors.background,
        elevation: 0,
        foregroundColor: KeychatColors.textPrimary,
        title: Text(l10n.attachmentServerSettingsTitle),
        actions: [
          IconButton(
            onPressed: _resetToDefaults,
            tooltip: l10n.resetAttachmentServers,
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
                              keyboardType: TextInputType.url,
                              decoration: _inputDecoration(l10n.attachmentServerUrlLabel),
                              validator: _validateUrl,
                            ),
                          ),
                          const SizedBox(width: 12),
                          SizedBox(
                            height: 52,
                            child: ElevatedButton(
                              onPressed: _addServer,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: KeychatColors.primaryDark,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: Text(l10n.addAttachmentServer),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: _urls.isEmpty
                          ? Center(
                              child: Text(
                                l10n.noAttachmentServersYet,
                                style: const TextStyle(
                                  fontSize: 15,
                                  color: KeychatColors.textSecondary,
                                ),
                              ),
                            )
                          : ListView(
                              children: [
                                if (_defaultUrl != null)
                                  _ServerTile(
                                    url: _defaultUrl!,
                                    isDefault: true,
                                    status: _status[_defaultUrl],
                                    onEdit: () => _editServer(_defaultUrl!),
                                    onRemove: () => _removeServer(_defaultUrl!),
                                  ),
                                if (others.isNotEmpty) const SizedBox(height: 24),
                                for (final url in others) ...[
                                  _ServerTile(
                                    url: url,
                                    isDefault: false,
                                    status: _status[url],
                                    onEdit: () => _editServer(url),
                                    onRemove: () => _removeServer(url),
                                    onSetDefault: () => _setAsDefault(url),
                                  ),
                                  const SizedBox(height: 16),
                                ],
                              ],
                            ),
                    ),
                  ],
                ),
              ),
            ),
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

/// A single server row — the default one is drawn with a highlighted
/// border/badge and no "set as default" action; others get a tappable
/// star-outline icon to promote them instead.
class _ServerTile extends StatelessWidget {
  const _ServerTile({
    required this.url,
    required this.isDefault,
    required this.status,
    required this.onEdit,
    required this.onRemove,
    this.onSetDefault,
  });

  final String url;
  final bool isDefault;
  final bool? status;
  final VoidCallback onEdit;
  final VoidCallback onRemove;
  final VoidCallback? onSetDefault;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: KeychatColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: isDefault
            ? Border.all(color: KeychatColors.primaryDark, width: 1.5)
            : null,
      ),
      child: Row(
        children: [
          if (isDefault)
            IconButton(
              onPressed: null,
              icon: const Icon(Icons.star, size: 20, color: KeychatColors.primaryDark),
            )
          else
            IconButton(
              onPressed: onSetDefault,
              tooltip: l10n.setAsDefaultServer,
              icon: const Icon(
                Icons.star_border,
                size: 20,
                color: KeychatColors.textSecondary,
              ),
            ),
          _StatusDot(status: status),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isDefault)
                  Text(
                    l10n.attachmentServerDefaultBadge,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: KeychatColors.primaryDark,
                    ),
                  ),
                Text(
                  url,
                  style: const TextStyle(fontSize: 14, color: KeychatColors.textPrimary),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onEdit,
            tooltip: l10n.editRelay,
            icon: const Icon(Icons.edit_outlined, size: 20, color: KeychatColors.textSecondary),
          ),
          IconButton(
            onPressed: onRemove,
            tooltip: l10n.removeRelay,
            icon: const Icon(Icons.close, size: 20, color: KeychatColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _EditServerDialog extends StatefulWidget {
  const _EditServerDialog({required this.initialUrl});

  final String initialUrl;

  @override
  State<_EditServerDialog> createState() => _EditServerDialogState();
}

class _EditServerDialogState extends State<_EditServerDialog> {
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
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            labelText: l10n.attachmentServerUrlLabel,
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
            return (!url.startsWith('https://') && !url.startsWith('http://'))
                ? l10n.invalidAttachmentServerUrl
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

/// Small colored dot showing whether a server is reachable: grey while
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
