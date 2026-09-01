// services/error_handler.dart
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Centralized, user-friendly error classification and presentation utility.
///
/// Prevents raw technical exceptions, database paths, and API keys from leaking
/// into the user interface while ensuring clear recovery paths for network,
/// auth, storage, and permission errors.
class ErrorHandler {
  ErrorHandler._();

  /// Translates technical exceptions into human-friendly, actionable messages.
  static String userFriendlyMessage(
    Object? error, {
    String defaultMessage = 'An unexpected error occurred. Please try again.',
  }) {
    if (error == null) return defaultMessage;

    if (error is FirebaseAuthException) {
      switch (error.code) {
        case 'user-not-found':
        case 'wrong-password':
        case 'invalid-credential':
          return 'Incorrect email or password. Please check your credentials.';
        case 'invalid-email':
          return 'Please enter a valid email address.';
        case 'email-already-in-use':
          return 'This email address is already registered. Please sign in instead.';
        case 'weak-password':
          return 'Password is too weak. Please use at least 8 characters with letters and numbers.';
        case 'network-request-failed':
          return 'Network error. Please check your connection and try again.';
        case 'too-many-requests':
          return 'Too many attempts. Please wait a moment before trying again.';
        case 'user-disabled':
          return 'This account has been disabled. Please contact support.';
        case 'operation-not-allowed':
          return 'This sign-in method is currently disabled.';
        case 'requires-recent-login':
          return 'For your security, please log in again to complete this action.';
        case 'unauthenticated':
          return 'You need to be logged in to perform this action.';
        default:
          return error.message ?? defaultMessage;
      }
    }

    if (error is FirebaseException) {
      switch (error.code) {
        case 'permission-denied':
          return 'You do not have permission to perform this action.';
        case 'unavailable':
          return 'Service is temporarily unavailable. Please check your connection.';
        case 'unauthenticated':
          return 'You need to be logged in to perform this action.';
        case 'deadline-exceeded':
          return 'Request timed out. Please check your network and try again.';
        case 'not-found':
          return 'The requested record was not found or has been deleted.';
        case 'already-exists':
          return 'This record already exists.';
        case 'resource-exhausted':
          return 'Service is temporarily busy. Please try again in a few moments.';
        default:
          return defaultMessage;
      }
    }

    if (error is SocketException || error is HttpException) {
      return 'No internet connection. Please check your Wi-Fi or mobile data.';
    }

    if (error is TimeoutException) {
      return 'The connection timed out. Please check your network and try again.';
    }

    if (error is PlatformException) {
      if (error.code == 'network_error') {
        return 'Network communication failed. Please check your connection.';
      }
      if (error.code == 'sign_in_canceled' || error.code == 'canceled') {
        return 'Operation was cancelled.';
      }
      if (error.code == 'PERMISSION_DENIED' ||
          error.code == 'permission_denied') {
        return 'Permission denied. Please grant the required permission in device Settings.';
      }
      return error.message ?? defaultMessage;
    }

    final str = error.toString();
    if (str.contains('SocketException') ||
        str.contains('Failed host lookup') ||
        str.contains('Network is unreachable') ||
        str.contains('network-request-failed')) {
      return 'No internet connection. Please check your Wi-Fi or mobile data.';
    }
    if (str.contains('unavailable') ||
        str.contains('cloud_firestore/unavailable')) {
      return 'Service is temporarily unavailable. Please check your connection.';
    }
    if (str.contains('permission-denied') ||
        str.contains('cloud_firestore/permission-denied')) {
      return 'You do not have permission to perform this action.';
    }
    if (str.contains('unauthenticated') ||
        str.contains('cloud_firestore/unauthenticated')) {
      return 'You need to be logged in to perform this action.';
    }
    if (str.contains('TimeoutException') || str.contains('timed out')) {
      return 'Request timed out. Please try again.';
    }

    // Filter out raw Exception prefixes
    if (str.startsWith('Exception:') || str.startsWith('Error:')) {
      final clean = str.replaceFirst(RegExp(r'^(Exception|Error):\s*'), '');
      if (!clean.contains('[') &&
          !clean.contains('{') &&
          !clean.contains('cloud_firestore') &&
          clean.length < 120) {
        return clean;
      }
    }

    return defaultMessage;
  }

  /// Displays a standardized floating error SnackBar.
  static void showError(
    BuildContext context, {
    String? message,
    Object? error,
    VoidCallback? onRetry,
  }) {
    if (!context.mounted) return;
    final text = message ?? userFriendlyMessage(error);

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(children: [
          const Icon(Icons.error_outline_rounded,
              color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ]),
        action: onRetry != null
            ? SnackBarAction(
                label: 'Retry',
                textColor: Colors.amberAccent,
                onPressed: onRetry,
              )
            : null,
        backgroundColor: const Color(0xFFD32F2F),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: onRetry != null
            ? const Duration(seconds: 4)
            : const Duration(seconds: 3),
      ),
    );
  }

  /// Displays a subtle non-blocking information or offline SnackBar.
  static void showInfo(
    BuildContext context, {
    required String message,
    IconData icon = Icons.info_outline_rounded,
  }) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(children: [
          Icon(icon, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ]),
        backgroundColor: const Color(0xFF374151),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// Reusable State Components (Error, Empty, Offline)
// ─────────────────────────────────────────────

/// Reusable full-page or section error state card with optional retry and secondary actions.
class AppErrorStateView extends StatelessWidget {
  final String? title;
  final String message;
  final VoidCallback? onRetry;
  final String retryLabel;
  final VoidCallback? onSecondary;
  final String? secondaryLabel;
  final IconData icon;

  const AppErrorStateView({
    super.key,
    this.title,
    required this.message,
    this.onRetry,
    this.retryLabel = 'Retry',
    this.onSecondary,
    this.secondaryLabel,
    this.icon = Icons.error_outline_rounded,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 48, color: const Color(0xFFE53935)),
            ),
            const SizedBox(height: 16),
            if (title != null) ...[
              Text(
                title!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1F2937),
                ),
              ),
              const SizedBox(height: 8),
            ],
            Text(
              message,
              textAlign: TextAlign.center,
              style:
                  TextStyle(fontSize: 14, color: Colors.grey[600], height: 1.4),
            ),
            if (onRetry != null || onSecondary != null) ...[
              const SizedBox(height: 20),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (onSecondary != null) ...[
                    OutlinedButton(
                      onPressed: onSecondary,
                      style: OutlinedButton.styleFrom(
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 10),
                      ),
                      child: Text(secondaryLabel ?? 'Go Back',
                          style: TextStyle(color: Colors.grey[700])),
                    ),
                    const SizedBox(width: 12),
                  ],
                  if (onRetry != null)
                    ElevatedButton.icon(
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: Text(retryLabel),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6366F1),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 10),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Reusable empty state view with icon, title, description, and action button.
class AppEmptyStateView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const AppEmptyStateView({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 52, color: Colors.grey[400]),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: Color(0xFF374151),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style:
                  TextStyle(fontSize: 13, color: Colors.grey[500], height: 1.4),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: onAction,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6366F1),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                ),
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Non-blocking banner indicating that cached data is being displayed because the device is offline.
class AppOfflineBanner extends StatelessWidget {
  final String message;
  final String retryLabel;
  final VoidCallback? onRetry;

  const AppOfflineBanner({
    super.key,
    this.message = "You're offline. Some features may be unavailable.",
    this.retryLabel = 'Check Connection',
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: const Color(0xFF4B5563),
      child: Row(
        children: [
          const Icon(Icons.cloud_off_rounded, color: Colors.white, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
          if (onRetry != null)
            GestureDetector(
              onTap: onRetry,
              child: Text(
                retryLabel,
                style: const TextStyle(
                  color: Colors.amberAccent,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
