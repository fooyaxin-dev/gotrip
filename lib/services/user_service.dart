import 'dart:io';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import '../modules/profile/userModel.dart';

/// UserService - 使用 Base64 存储图片（无需 Firebase Storage）
/// 完全免费！
class UserService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // 获取当前用户ID
  String? get currentUserId => _auth.currentUser?.uid;

  // 获取用户资料
  Future<UserProfile?> getUserProfile(String uid) async {
    try {
      print('📖 Reading user profile: $uid');
      DocumentSnapshot doc = await _firestore.collection('users').doc(uid).get();
      
      if (doc.exists) {
        Map<String, dynamic> data = doc.data() as Map<String, dynamic>;
        print('✅ Read successful');
        return UserProfile.fromMap(data, uid);
      }
      print('❌ 用户文档不存在');
      return null;
    } catch (e) {
      print('❌ 读取用户资料失败: $e');
      return null;
    }
  }

  // 获取当前用户资料
  Future<UserProfile?> getCurrentUserProfile() async {
    if (currentUserId == null) return null;
    return getUserProfile(currentUserId!);
  }

  // 更新用户资料
  Future<bool> updateUserProfile(UserProfile profile) async {
    try {
      print('💾 Starting to update user profile in Firestore');
      print('   UID: ${profile.uid}');
      
      Map<String, dynamic> dataToSave = profile.toMap();
      
      // 检查图片数据大小
      String profileImg = dataToSave['profileImageUrl'] ?? '';
      String bgImg = dataToSave['backgroundImageUrl'] ?? '';
      
      int profileSize = profileImg.length;
      int bgSize = bgImg.length;
      int totalSize = profileSize + bgSize;
      
      print('📊 Data size check:');
      print('   Profile image: ${(profileSize / 1024).toStringAsFixed(2)} KB');
      print('   Background image: ${(bgSize / 1024).toStringAsFixed(2)} KB');
      print('   Total: ${(totalSize / 1024).toStringAsFixed(2)} KB');
      
      // Firestore 文档大小限制是 1MB
      if (totalSize > 1048576) { // 1MB
        print('⚠️  Warning: Document size exceeds 1MB limit!');
        print('   Recommendation: Compress images or use external storage');
        return false;
      }
      
      await _firestore.collection('users').doc(profile.uid).set(
        dataToSave,
        SetOptions(merge: true),
      );
      
      print('✅ Firestore update successful!');
      return true;
    } catch (e) {
      print('❌ Failed to update user profile: $e');
      return false;
    }
  }

  // 压缩并转换图片为 Base64
  Future<String?> imageToBase64(File imageFile, {int maxWidth = 800, int quality = 85}) async {
    try {
      print('🖼️ Starting to process image...');
      print('   Original path: ${imageFile.path}');
      
      // 检查文件是否存在
      if (!await imageFile.exists()) {
        print('❌ File not exists!');
        return null;
      }
      
      // 读取原始文件
      Uint8List imageBytes = await imageFile.readAsBytes();
      int originalSize = imageBytes.length;
      print('   Original size: ${(originalSize / 1024).toStringAsFixed(2)} KB');
      
      // 解码图片
      img.Image? image = img.decodeImage(imageBytes);
      if (image == null) {
        print('❌ Picture decode failed!');
        return null;
      }
      
      print('   Original dimensions: ${image.width}x${image.height}');
      
      // 如果图片太大，等比例缩小
      if (image.width > maxWidth) {
        int newHeight = (image.height * maxWidth / image.width).round();
        image = img.copyResize(image, width: maxWidth, height: newHeight);
        print('   Adjusted dimensions: ${image.width}x${image.height}');
      }
      
      // 压缩为 JPEG
      List<int> compressedBytes = img.encodeJpg(image, quality: quality);
      int compressedSize = compressedBytes.length;
      print('   Compressed size: ${(compressedSize / 1024).toStringAsFixed(2)} KB');
      print('   Compression ratio: ${((1 - compressedSize / originalSize) * 100).toStringAsFixed(1)}%');
      
      // 转换为 Base64
      String base64String = 'data:image/jpeg;base64,${base64Encode(compressedBytes)}';
      print('   Base64 size: ${(base64String.length / 1024).toStringAsFixed(2)} KB');
      
      // 检查大小限制（建议单张图片不超过 400KB）
      if (base64String.length > 409600) { // 400KB
        print('⚠️  Image still too large, trying further compression...');
        
        // 降低质量再压缩一次
        compressedBytes = img.encodeJpg(image, quality: 70);
        base64String = 'data:image/jpeg;base64,${base64Encode(compressedBytes)}';
        print('   Again compressed: ${(base64String.length / 1024).toStringAsFixed(2)} KB');
      }
      
      print('✅ Image processing completed!');
      return base64String;
      
    } catch (e, stackTrace) {
      print('❌ Image processing failed: $e');
      print('Stack trace: $stackTrace');
      return null;
    }
  }

  // 上传头像（实际上是转换为 Base64）
  Future<String?> uploadProfileImage(File imageFile, String uid) async {
    print('\n🖼️ Processing profile image...');
    String? base64 = await imageToBase64(
      imageFile,
      maxWidth: 400, // 头像较小
      quality: 85,
    );
    
    if (base64 != null) {
      print('✅ Profile image processing successful\n');
    } else {
      print('❌ Profile image processing failed\n');
    }
    return base64;
  }

  // 上传背景图片（实际上是转换为 Base64）
  Future<String?> uploadBackgroundImage(File imageFile, String uid) async {
    print('\n🌄 Processing background image...');
    String? base64 = await imageToBase64(
      imageFile,
      maxWidth: 800, // 背景图可以大一点
      quality: 80,
    );
    
    if (base64 != null) {
      print('✅ Background image processing successful\n');
    } else {
      print('❌ Background image processing failed\n');
    }
    return base64;
  }

  // 删除旧图片（Base64 方案不需要删除，直接覆盖即可）
  Future<void> deleteImageFromUrl(String imageUrl) async {
    // Base64 存储在数据库中，不需要单独删除
    // 更新时直接覆盖即可
    print('ℹ️  Base64 picture stored in Firestore, no separate deletion needed');
  }

  // Stream 监听用户资料变化
  Stream<UserProfile?> getUserProfileStream(String uid) {
    return _firestore.collection('users').doc(uid).snapshots().map((doc) {
      if (doc.exists) {
        return UserProfile.fromMap(doc.data() as Map<String, dynamic>, uid);
      }
      return null;
    });
  }

  // Stream 监听当前用户资料
  Stream<UserProfile?> getCurrentUserProfileStream() {
    if (currentUserId == null) return Stream.value(null);
    return getUserProfileStream(currentUserId!);
  }
}