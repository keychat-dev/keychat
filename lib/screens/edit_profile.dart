import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:workspace/l10n/app_localizations.dart';
import 'package:workspace/screens/login.dart';
import 'package:workspace/services/account_sync.dart';
import 'package:workspace/src/rust/api/account.dart' as account_api;

/// Lets the user change their avatar, display name, and status message.
/// Pops with the updated [account_api.Account] once saved, or nothing if
/// the user cancels.
class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key, required this.profile});

  final account_api.Account profile;

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _displayNameController = TextEditingController(
    text: widget.profile.displayName,
  );
  late final _statusMessageController = TextEditingController(
    text: widget.profile.statusMessage,
  );
  late String? _avatarPath = widget.profile.avatarPath;
  bool _saving = false;

  @override
  void dispose() {
    _displayNameController.dispose();
    _statusMessageController.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 85,
    );
    if (picked == null) return;
    setState(() => _avatarPath = picked.path);
  }

  Future<void> _handleSave() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final storageDir = await getApplicationDocumentsDirectory();
    var avatarPath = _avatarPath;
    // Only copy the picked file into permanent storage if it isn't already
    // there (i.e. the user picked a new image rather than keeping the old one).
    if (avatarPath != null && !avatarPath.startsWith(storageDir.path)) {
      final extension = avatarPath.split('.').last;
      final destination = '${storageDir.path}/avatar.$extension';
      await File(avatarPath).copy(destination);
      avatarPath = destination;
    }

    await account_api.saveAccount(
      storageDir: storageDir.path,
      displayName: _displayNameController.text.trim(),
      statusMessage: _statusMessageController.text.trim(),
      avatarPath: avatarPath,
    );
    final saved = (await account_api.loadAccount(storageDir: storageDir.path))!;
    final avatarChanged = avatarPath != widget.profile.avatarPath;
    unawaited(publishAccountBackup(saved));
    unawaited(publishProfileUpdateToFriends(saved, avatarChanged: avatarChanged));

    if (!mounted) return;
    Navigator.of(context).pop(saved);
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
        title: Text(l10n.editProfile),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildAvatarPicker(),
                const SizedBox(height: 32),
                TextFormField(
                  controller: _displayNameController,
                  decoration: _inputDecoration(l10n.displayNameLabel),
                  validator: (value) => (value == null || value.trim().isEmpty)
                      ? l10n.displayNameRequired
                      : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _statusMessageController,
                  decoration: _inputDecoration(l10n.statusMessageLabel),
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    onPressed: _saving ? null : _handleSave,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: KeychatColors.primaryDark,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: _saving
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(
                            l10n.continueButton,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAvatarPicker() {
    final avatarPath = _avatarPath;
    return Center(
      child: GestureDetector(
        onTap: _pickAvatar,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 88,
              height: 88,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: KeychatColors.surface,
                borderRadius: BorderRadius.circular(24),
              ),
              child: avatarPath != null
                  ? Image.file(File(avatarPath), width: 88, height: 88, fit: BoxFit.cover)
                  : const Icon(
                      Icons.photo_outlined,
                      size: 32,
                      color: KeychatColors.textSecondary,
                    ),
            ),
            Positioned(
              right: -6,
              bottom: -6,
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  shape: BoxShape.circle,
                  border: Border.all(color: KeychatColors.background, width: 2),
                ),
                child: const Icon(Icons.photo_camera_outlined, size: 16, color: Colors.white),
              ),
            ),
          ],
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
