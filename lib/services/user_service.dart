import 'dart:io';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import '../models/userModel.dart';

/// Result wrapper so callers know WHY a save failed, not just that it did.
class UserUpdateResult {
  final bool success;
  final String? error;

  const UserUpdateResult({required this.success, this.error});

  static const UserUpdateResult ok = UserUpdateResult(success: true);
  factory UserUpdateResult.failure(String error) =>
      UserUpdateResult(success: false, error: error);
}

/// UserService - 使用 Base64 存储图片（无需 Firebase Storage）
/// 完全免费！
class UserService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // Firestore document hard limit is 1MiB. Stay comfortably under it
  // since the doc also stores username/bio/counts etc.
  static const int _maxDocBytes = 900 * 1024; // 900 KB safety margin
  static const int _maxSingleImageBytes = 350 * 1024; // 350 KB per image

  String? get currentUserId => _auth.currentUser?.uid;

  // ─────────────────────────────────────────────
  // Read
  // ─────────────────────────────────────────────

  Future<UserProfile?> getUserProfile(String uid) async {
    try {
      if (kDebugMode) print('📖 Reading user profile: $uid');
      DocumentSnapshot doc =
          await _firestore.collection('users').doc(uid).get();

      if (doc.exists) {
        Map<String, dynamic> data = doc.data() as Map<String, dynamic>;
        return UserProfile.fromMap(data, uid);
      }
      if (kDebugMode) print('❌ User document does not exist');
      return null;
    } catch (e) {
      if (kDebugMode) print('❌ Failed to read user profile: $e');
      return null;
    }
  }

  Future<UserProfile?> getCurrentUserProfile() async {
    if (currentUserId == null) return null;
    return getUserProfile(currentUserId!);
  }

  // ─────────────────────────────────────────────
  // Write
  // ─────────────────────────────────────────────

  /// Updates the user profile. Returns a [UserUpdateResult] so the caller
  /// can show a specific error message (e.g. "images too large") instead
  /// of a generic failure.
  Future<UserUpdateResult> updateUserProfile(UserProfile profile) async {
    try {
      final dataToSave = profile.toMap();

      final profileImg = dataToSave['profileImageUrl'] as String? ?? '';
      final bgImg = dataToSave['backgroundImageUrl'] as String? ?? '';
      final totalSize = profileImg.length + bgImg.length;

      if (kDebugMode) {
        print('📊 Data size check:');
        print('   Profile image: ${(profileImg.length / 1024).toStringAsFixed(2)} KB');
        print('   Background image: ${(bgImg.length / 1024).toStringAsFixed(2)} KB');
        print('   Total: ${(totalSize / 1024).toStringAsFixed(2)} KB');
      }

      if (totalSize > _maxDocBytes) {
        if (kDebugMode) print('⚠️ Document size exceeds limit!');
        return UserUpdateResult.failure(
          'Your photos are too large to save. Please choose smaller images '
          'or try again — they will be compressed automatically.',
        );
      }

      await _firestore
          .collection('users')
          .doc(profile.uid)
          .set(dataToSave, SetOptions(merge: true));

      if (kDebugMode) print('✅ Firestore update successful!');
      return UserUpdateResult.ok;
    } catch (e) {
      if (kDebugMode) print('❌ Failed to update user profile: $e');
      return UserUpdateResult.failure('Something went wrong while saving. Please try again.');
    }
  }

  // ─────────────────────────────────────────────
  // Image processing
  // ─────────────────────────────────────────────

  /// Compresses [imageFile] and returns a base64 data URI, or null on failure.
  /// Guarantees the result is under [_maxSingleImageBytes] by progressively
  /// reducing quality, then dimensions, until it fits — or giving up safely.
  Future<String?> imageToBase64(
    File imageFile, {
    int maxWidth = 800,
    int quality = 85,
  }) async {
    try {
      if (!await imageFile.exists()) {
        if (kDebugMode) print('❌ File not exists!');
        return null;
      }

      final Uint8List imageBytes = await imageFile.readAsBytes();

      img.Image? image = img.decodeImage(imageBytes);
      if (image == null) {
        if (kDebugMode) print('❌ Picture decode failed!');
        return null;
      }

      // Initial resize if needed
      if (image.width > maxWidth) {
        final newHeight = (image.height * maxWidth / image.width).round();
        image = img.copyResize(image, width: maxWidth, height: newHeight);
      }

      String result = _encodeAndWrap(image, quality);

      // Progressive fallback: lower quality first
      if (result.length > _maxSingleImageBytes) {
        result = _encodeAndWrap(image, 70);
      }
      if (result.length > _maxSingleImageBytes) {
        result = _encodeAndWrap(image, 55);
      }

      // Still too big? Shrink dimensions and retry at moderate quality.
      int attempt = 0;
      while (result.length > _maxSingleImageBytes && attempt < 3) {
        final shrunk = img.copyResize(
          image!,
          width: (image.width * 0.75).round(),
        );
        image = shrunk;
        result = _encodeAndWrap(image, 60);
        attempt++;
      }

      if (kDebugMode) {
        print('✅ Image processed: ${(result.length / 1024).toStringAsFixed(2)} KB '
            '(after $attempt resize attempt(s))');
      }

      // Final guard — if still too big after all attempts, fail loudly
      // rather than silently saving something that will break the doc limit.
      if (result.length > _maxSingleImageBytes) {
        if (kDebugMode) print('❌ Could not compress image under limit');
        return null;
      }

      return result;
    } catch (e, stackTrace) {
      if (kDebugMode) {
        print('❌ Image processing failed: $e');
        print('Stack trace: $stackTrace');
      }
      return null;
    }
  }

  String _encodeAndWrap(img.Image image, int quality) {
    final bytes = img.encodeJpg(image, quality: quality);
    return 'data:image/jpeg;base64,${base64Encode(bytes)}';
  }

  /// uid is currently unused — kept so this method's signature stays stable
  /// if we migrate to Firebase Storage (path would be uid-based) later.
  Future<String?> uploadProfileImage(File imageFile, String uid) async {
    return imageToBase64(imageFile, maxWidth: 400, quality: 85);
  }

  /// uid is currently unused — kept so this method's signature stays stable
  /// if we migrate to Firebase Storage (path would be uid-based) later.
  Future<String?> uploadBackgroundImage(File imageFile, String uid) async {
    return imageToBase64(imageFile, maxWidth: 800, quality: 80);
  }

  Future<void> deleteImageFromUrl(String imageUrl) async {
    // Base64 is stored inline in Firestore; overwriting on update is enough.
  }

  // ─────────────────────────────────────────────
  // Streams
  // ─────────────────────────────────────────────

  Stream<UserProfile?> getUserProfileStream(String uid) {
    return _firestore.collection('users').doc(uid).snapshots().map((doc) {
      if (doc.exists) {
        return UserProfile.fromMap(doc.data() as Map<String, dynamic>, uid);
      }
      return null;
    });
  }

  Stream<UserProfile?> getCurrentUserProfileStream() {
    if (currentUserId == null) return Stream.value(null);
    return getUserProfileStream(currentUserId!);
  }
}