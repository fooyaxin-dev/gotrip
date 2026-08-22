import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../main/onBoarding.dart';
import '../../services/userPreference_service.dart';
import '../itinerary/itineraryPage.dart';
import '../../services/error_handler.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String _selectedLanguage = 'EN';
  bool _notificationsEnabled = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F6FF),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF8F6FF),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new,
              color: Colors.black87, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Settings',
            style: TextStyle(
                color: Colors.black87,
                fontSize: 18,
                fontWeight: FontWeight.bold)),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [

          // ── Personalization ──────────────────
          _buildSectionHeader('Personalization'),
          _buildTile(
            icon: Icons.tune_rounded,
            iconColor: const Color(0xFF7C4DFF),
            iconBg: const Color(0xFFF0EBFF),
            title: 'Edit Preferences',
            subtitle: 'Update your interests & travel style',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => OnboardingPage(
                  isEditing: true,
                  onDone: () => setState(() {}),
                ),
              ),
            ),
          ),
          _buildTile(
            icon: Icons.restart_alt_rounded,
            iconColor: const Color(0xFFE74C3C),
            iconBg: const Color(0xFFFFEBEB),
            title: 'Reset Preferences',
            subtitle: 'Start fresh with new recommendations',
            onTap: () => _showResetDialog(),
          ),

          const SizedBox(height: 20),

          // ── App Settings ─────────────────────
          // _buildSectionHeader('App Settings'),
          // _buildLanguageTile(),
          // _buildSwitchTile(
          //   icon: Icons.notifications_rounded,
          //   iconColor: const Color(0xFFFF6B35),
          //   iconBg: const Color(0xFFFFF0EB),
          //   title: 'Notifications',
          //   subtitle: 'Get updates about nearby places',
          //   value: _notificationsEnabled,
          //   onChanged: (val) => setState(() => _notificationsEnabled = val),
          // ),

          const SizedBox(height: 20),

          // ── Account ──────────────────────────
          _buildSectionHeader('Account'),
          // _buildTile(
          //   icon: Icons.lock_outline_rounded,
          //   iconColor: const Color(0xFF3498DB),
          //   iconBg: const Color(0xFFEBF5FF),
          //   title: 'Change Password',
          //   subtitle: 'Update your account password',
          //   onTap: () => _showChangePasswordDialog(),
          // ),
          _buildTile(
            icon: Icons.logout_rounded,
            iconColor: const Color(0xFFE74C3C),
            iconBg: const Color(0xFFFFEBEB),
            title: 'Log Out',
            subtitle: 'Sign out of your account',
            onTap: () => _showLogoutDialog(),
          ),

          const SizedBox(height: 20),

          // ── About ────────────────────────────
          _buildSectionHeader('About'),
          _buildTile(
            icon: Icons.info_outline_rounded,
            iconColor: Colors.grey,
            iconBg: Colors.grey[100]!,
            title: 'App Version',
            subtitle: 'GoTrip v1.0.0',
            onTap: null,
            showArrow: false,
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────
  // Widgets
  // ─────────────────────────────────────────────

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(title,
          style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.grey[500],
              letterSpacing: 0.5)),
    );
  }

  Widget _buildTile({
    required IconData icon,
    required Color iconColor,
    required Color iconBg,
    required String title,
    required String subtitle,
    required VoidCallback? onTap,
    bool showArrow = true,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: Container(
          width: 42, height: 42,
          decoration: BoxDecoration(
              color: iconBg, borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, color: iconColor, size: 22),
        ),
        title: Text(title,
            style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.w600, color: Colors.black87)),
        subtitle: Text(subtitle,
            style: TextStyle(fontSize: 12, color: Colors.grey[500])),
        trailing: showArrow
            ? Icon(Icons.chevron_right, color: Colors.grey[400])
            : null,
      ),
    );
  }

  Widget _buildSwitchTile({
    required IconData icon,
    required Color iconColor,
    required Color iconBg,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: Container(
          width: 42, height: 42,
          decoration: BoxDecoration(
              color: iconBg, borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, color: iconColor, size: 22),
        ),
        title: Text(title,
            style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.w600, color: Colors.black87)),
        subtitle: Text(subtitle,
            style: TextStyle(fontSize: 12, color: Colors.grey[500])),
        trailing: Switch(
          value: value,
          onChanged: onChanged,
          activeColor: const Color(0xFF7C4DFF),
        ),
      ),
    );
  }

  // Widget _buildLanguageTile() {
  //   return Container(
  //     margin: const EdgeInsets.only(bottom: 10),
  //     decoration: BoxDecoration(
  //       color: Colors.white,
  //       borderRadius: BorderRadius.circular(16),
  //       boxShadow: [BoxShadow(
  //           color: Colors.black.withOpacity(0.04),
  //           blurRadius: 8, offset: const Offset(0, 2))],
  //     ),
  //     child: ListTile(
  //       contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
  //       leading: Container(
  //         width: 42, height: 42,
  //         decoration: BoxDecoration(
  //             color: const Color(0xFFEBFFF5),
  //             borderRadius: BorderRadius.circular(12)),
  //         child: const Icon(Icons.language_rounded,
  //             color: Color(0xFF2ECC71), size: 22),
  //       ),
  //       title: const Text('Language',
  //           style: TextStyle(
  //               fontSize: 15, fontWeight: FontWeight.w600, color: Colors.black87)),
  //       subtitle: const Text('App display language',
  //           style: TextStyle(fontSize: 12, color: Colors.grey)),
  //       trailing: Container(
  //         decoration: BoxDecoration(
  //           color: const Color(0xFFF0EBFF),
  //           borderRadius: BorderRadius.circular(8),
  //         ),
  //         child: Row(
  //           mainAxisSize: MainAxisSize.min,
  //           children: ['EN', 'CN'].map((lang) {
  //             final isSelected = _selectedLanguage == lang;
  //             return GestureDetector(
  //               onTap: () => setState(() => _selectedLanguage = lang),
  //               child: Container(
  //                 padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
  //                 decoration: BoxDecoration(
  //                   color: isSelected
  //                       ? const Color(0xFF7C4DFF)
  //                       : Colors.transparent,
  //                   borderRadius: BorderRadius.circular(8),
  //                 ),
  //                 child: Text(lang,
  //                     style: TextStyle(
  //                         fontSize: 13,
  //                         fontWeight: FontWeight.bold,
  //                         color: isSelected ? Colors.white : Colors.grey[600])),
  //               ),
  //             );
  //           }).toList(),
  //         ),
  //       ),
  //     ),
  //   );
  // }

  // ─────────────────────────────────────────────
  // Dialogs
  // ─────────────────────────────────────────────

  void _showLogoutDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Log Out',
            style: TextStyle(fontWeight: FontWeight.bold)),
        content: const Text('Are you sure you want to log out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel', style: TextStyle(color: Colors.grey[600])),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);

              UserPreferenceService.instance.clearLocalSession();

              await FirebaseAuth.instance.signOut();

              if (mounted) {
                Navigator.of(context).pushNamedAndRemoveUntil('/', (_) => false);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE74C3C),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Log Out',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showChangePasswordDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Change Password',
            style: TextStyle(fontWeight: FontWeight.bold)),
        content: TextField(
          controller: controller,
          obscureText: true,
          decoration: InputDecoration(
            hintText: 'New password',
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel', style: TextStyle(color: Colors.grey[600])),
          ),
          ElevatedButton(
            onPressed: () async {
              final newPwd = controller.text.trim();
              if (newPwd.length < 6) return;
              try {
                await FirebaseAuth.instance.currentUser
                    ?.updatePassword(newPwd);
                if (mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Password updated!')),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Failed: $e')),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF7C4DFF),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Update',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }


  void _showResetDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Reset Preferences',
            style: TextStyle(fontWeight: FontWeight.bold)),
        content: const Text(
            'This will clear all your interests and recommendation history. '
            'You can set them again anytime.\n\nAre you sure?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel', style: TextStyle(color: Colors.grey[600])),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                await UserPreferenceService.instance.reset();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Preferences reset successfully'),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ErrorHandler.showError(context, message: 'Failed to reset preferences. Please try again.');
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE74C3C),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Reset',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

  }
}

