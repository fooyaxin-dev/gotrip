import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
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

class UserService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;

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
  //
  // Firestore doc now only ever holds a Storage download URL (or, for
  // legacy accounts, a base64 data URI that hasn't been migrated yet —
  // the UI's _getImageProvider already handles both). No more manual
  // byte-size gating against the 1MiB document limit; Storage has no
  // such ceiling and the image itself is compressed before upload.
  // ─────────────────────────────────────────────

  Future<UserUpdateResult> updateUserProfile(
    UserProfile profile,
  ) async {
    final currentUid = _auth.currentUser?.uid;

    if (currentUid == null) {
      return UserUpdateResult.failure(
        'You need to be logged in to update your profile.',
      );
    }

    // Safety guard:
    // A user should only update their own profile through this service.
    if (currentUid != profile.uid) {
      return UserUpdateResult.failure(
        'You are not allowed to update this profile.',
      );
    }

    try {
      // Only update fields that are actually editable from Edit Profile.
      //
      // Do NOT write:
      // - postCount
      // - favouriteCount
      //
      // Those counters are maintained independently by their own
      // transaction-based services and must never be overwritten by
      // a stale UserProfile object.
      await _firestore
          .collection('users')
          .doc(currentUid)
          .set(
        {
          'username': profile.username,
          'bio': profile.bio,
          'profileImageUrl': profile.profileImageUrl,
          'backgroundImageUrl': profile.backgroundImageUrl,
        },
        SetOptions(merge: true),
      );

      if (kDebugMode) {
        print(
          '✅ User profile editable fields updated successfully',
        );
      }

      return UserUpdateResult.ok;
    } catch (e) {
      if (kDebugMode) {
        print(
          '❌ Failed to update user profile: $e',
        );
      }

      return UserUpdateResult.failure(
        'Something went wrong while saving. Please try again.',
      );
    }
  }
  
  // ─────────────────────────────────────────────
  // Image upload — Firebase Storage
  // ─────────────────────────────────────────────

  /// The `image` package can't decode HEIC (iOS's default camera-roll
  /// format), so a straight `img.decodeImage()` call on those bytes
  /// returns null even though the file itself is a perfectly valid photo
  /// (that's why the picker's preview — which uses the OS-native decoder
  /// via FileImage/Image.file — still shows it fine). This fallback
  /// re-decodes through Flutter's own native codec (dart:ui), which does
  /// understand HEIC on iOS, then re-encodes to PNG bytes that `image`
  /// CAN read, before continuing the normal resize/compress pipeline.
  Future<Uint8List?> _decodeViaNativeFallback(Uint8List rawBytes) async {
    try {
      final codec = await ui.instantiateImageCodec(rawBytes);
      final frame = await codec.getNextFrame();
      final byteData = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      if (byteData == null) return null;
      return byteData.buffer.asUint8List();
    } catch (e) {
      if (kDebugMode) print('❌ Native fallback decode failed: $e');
      return null;
    }
  }

  Future<String?> _uploadCompressed({
    required File imageFile,
    required String uid,
    required String kind, // 'profile' | 'background'
    required int maxWidth,
    int quality = 85,
  }) async {
    try {
      if (!await imageFile.exists()) {
        if (kDebugMode) print('❌ File does not exist!');
        return null;
      }

      final Uint8List rawBytes = await imageFile.readAsBytes();
      img.Image? image = img.decodeImage(rawBytes);

      // 🆕 image 包解不了（多半是 HEIC）→ 走原生解码器兜底一次
      if (image == null) {
        if (kDebugMode) print('⚠️ img.decodeImage failed, trying native fallback (likely HEIC)...');
        final pngBytes = await _decodeViaNativeFallback(rawBytes);
        if (pngBytes != null) {
          image = img.decodeImage(pngBytes);
        }
      }

      if (image == null) {
        if (kDebugMode) print('❌ Image decode failed even after fallback!');
        return null;
      }

      if (image.width > maxWidth) {
        final newHeight = (image.height * maxWidth / image.width).round();
        image = img.copyResize(image, width: maxWidth, height: newHeight);
      }

      final compressedBytes = img.encodeJpg(image, quality: quality);

      final fileName = '${kind}_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final ref = _storage.ref().child('profile_images/$uid/$fileName');

      final uploadTask = await ref.putData(
        Uint8List.fromList(compressedBytes),
        SettableMetadata(contentType: 'image/jpeg'),
      );

      final url = await uploadTask.ref.getDownloadURL();

      if (kDebugMode) {
        print('✅ Uploaded $kind image: $fileName '
            '(${(compressedBytes.length / 1024).toStringAsFixed(1)} KB)');
      }
      return url;
    } catch (e, st) {
      if (kDebugMode) {
        print('❌ _uploadCompressed($kind) failed: $e');
        print(st);
      }
      return null;
    }
  }

  /// 512px is plenty for an avatar shown at most at ~120dp.
  Future<String?> uploadProfileImage(File imageFile, String uid) async {
    return _uploadCompressed(
      imageFile: imageFile,
      uid: uid,
      kind: 'profile',
      maxWidth: 512,
      quality: 85,
    );
  }

  /// Background banners get shown wider, so keep more resolution.
  Future<String?> uploadBackgroundImage(File imageFile, String uid) async {
    return _uploadCompressed(
      imageFile: imageFile,
      uid: uid,
      kind: 'background',
      maxWidth: 1080,
      quality: 80,
    );
  }

  /// Best-effort cleanup of a replaced image. No-ops safely for legacy
  /// base64 data URIs or empty strings — there's nothing in Storage to
  /// delete for those, so this never throws for old accounts.
  Future<void> deleteImageFromUrl(String imageUrl) async {
    if (imageUrl.isEmpty || !imageUrl.startsWith('http')) return;
    try {
      await _storage.refFromURL(imageUrl).delete();
    } catch (e) {
      if (kDebugMode) print('⚠️ deleteImageFromUrl failed (non-fatal): $e');
    }
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