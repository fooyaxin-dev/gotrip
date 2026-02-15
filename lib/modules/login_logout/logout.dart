import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:ui'; // 用于模糊效果
import 'login.dart'; // 假设你有一个登录页面

class AuthService {
  static Future<void> logout(BuildContext context) async {
    final bool? confirm = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent, // 关键：背景透明才能看到圆角和模糊
      builder: (context) => Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor.withOpacity(0.9),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 顶部的指示条
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            const Icon(Icons.logout_rounded, size: 60, color: Colors.redAccent),
            const SizedBox(height: 16),
            const Text(
              'Oh no! You\'re leaving...',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Are you sure you want to log out?',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 32),
            Row(
              children: [
                // 取消按钮
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context, false),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                    ),
                    child: const Text('Maybe later'),
                  ),
                ),
                const SizedBox(width: 16),
                // 确认退出按钮
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context, true), // ✅ 重点
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                      elevation: 0,
                    ),
                    child: const Text('Yes, Logout'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20), // 留白，防止被底部虚拟按键遮挡
          ],
        ),
      ),
    );

    if (confirm == true) {
      await FirebaseAuth.instance.signOut();

      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginPage()),
        (route) => false,
      );
    }

  }
}