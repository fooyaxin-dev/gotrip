// services/error_handler.dart
//
// 统一的错误提示工具。
// 目的：替换掉代码里 `catch (e) { print(e); }` 这种「静默失败」的写法，
// 让用户操作失败时至少能看到一个 SnackBar，而不是毫无反应。

import 'package:flutter/material.dart';

class ErrorHandler {
  ErrorHandler._();

  /// 显示一个统一样式的错误 SnackBar。
  /// [message] 给用户看的友善提示文字（必填）
  /// [error]   catch 到的异常对象（可选，方便排查用）
  static void showError(
    BuildContext context, {
    required String message,
    Object? error,
  }) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(children: [
          const Icon(Icons.error_outline_rounded, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(message)),
        ]),
        backgroundColor: Colors.red[700],
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 3),
      ),
    );
  }
}