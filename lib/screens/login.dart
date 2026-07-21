import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:workspace/l10n/app_localizations.dart';
import 'package:workspace/languages.dart';

/// Greige-based color palette.
class KeychatColors {
  static const background = Color(0xFFF1ECE4);
  static const surface = Color(0xFFE7DFD2);
  static const primary = Color(0xFFA6957D);
  static const primaryDark = Color(0xFF6F6252);
  static const textPrimary = Color(0xFF4A4238);
  static const textSecondary = Color(0xFF8B8070);
}

/// Profile (display name / status message) setup screen shown before account creation.
/// KeyChat has no concept of a fixed account key, so this only decides
/// the display profile used across the app.
class ProfileSetupScreen extends StatefulWidget {
  const ProfileSetupScreen({super.key, this.onContinue, this.onSelectLanguage});

  final void Function(String displayName, String statusMessage, String? avatarPath)? onContinue;
  final ValueChanged<Locale>? onSelectLanguage;

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _displayNameController = TextEditingController();
  final _statusMessageController = TextEditingController();
  String? _avatarPath;

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

  void _handleContinue() {
    if (!_formKey.currentState!.validate()) return;
    widget.onContinue?.call(
      _displayNameController.text.trim(),
      _statusMessageController.text.trim(),
      _avatarPath,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: KeychatColors.background,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildAvatarPicker(),
                      const SizedBox(height: 24),
                      Text(
                        l10n.appTitle,
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w600,
                          color: KeychatColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        l10n.profileSetupSubtitle,
                        style: TextStyle(
                          fontSize: 14,
                          color: KeychatColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 40),
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
                          onPressed: _handleContinue,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: KeychatColors.primaryDark,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(
                            l10n.continueButton,
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (widget.onSelectLanguage != null)
              Positioned(
                top: 8,
                right: 16,
                child: _LanguageSelector(onSelected: widget.onSelectLanguage!),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatarPicker() {
    final avatarPath = _avatarPath;
    return GestureDetector(
      onTap: _pickAvatar,
      child: Container(
        width: 88,
        height: 88,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: KeychatColors.surface,
          borderRadius: BorderRadius.circular(24),
        ),
        child: avatarPath != null
            ? Image.file(File(avatarPath), width: 88, height: 88, fit: BoxFit.cover)
            : Icon(
                Icons.add_a_photo_outlined,
                size: 32,
                color: KeychatColors.textSecondary,
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

class _LanguageSelector extends StatelessWidget {
  const _LanguageSelector({required this.onSelected});

  final ValueChanged<Locale> onSelected;

  @override
  Widget build(BuildContext context) {
    final currentCode = Localizations.localeOf(context).languageCode;
    return PopupMenuButton<Locale>(
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final locale in AppLocalizations.supportedLocales)
          PopupMenuItem(
            value: locale,
            child: Text(languageNames[locale.languageCode] ?? locale.languageCode.toUpperCase()),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.translate, size: 18, color: KeychatColors.textSecondary),
            const SizedBox(width: 6),
            Text(
              languageNames[currentCode] ?? currentCode.toUpperCase(),
              style: const TextStyle(color: KeychatColors.textSecondary, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}
