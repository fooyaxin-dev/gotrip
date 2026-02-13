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
      print('📖 读取用户资料: $uid');
      DocumentSnapshot doc = await _firestore.collection('users').doc(uid).get();
      
      if (doc.exists) {
        Map<String, dynamic> data = doc.data() as Map<String, dynamic>;
        print('✅ 读取成功');
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
      print('💾 开始更新用户资料到 Firestore');
      print('   UID: ${profile.uid}');
      
      Map<String, dynamic> dataToSave = profile.toMap();
      
      // 检查图片数据大小
      String profileImg = dataToSave['profileImageUrl'] ?? '';
      String bgImg = dataToSave['backgroundImageUrl'] ?? '';
      
      int profileSize = profileImg.length;
      int bgSize = bgImg.length;
      int totalSize = profileSize + bgSize;
      
      print('📊 数据大小检查:');
      print('   头像: ${(profileSize / 1024).toStringAsFixed(2)} KB');
      print('   背景: ${(bgSize / 1024).toStringAsFixed(2)} KB');
      print('   总计: ${(totalSize / 1024).toStringAsFixed(2)} KB');
      
      // Firestore 文档大小限制是 1MB
      if (totalSize > 1048576) { // 1MB
        print('⚠️  警告：文档大小超过 1MB 限制！');
        print('   建议：压缩图片或使用外部存储');
        return false;
      }
      
      await _firestore.collection('users').doc(profile.uid).set(
        dataToSave,
        SetOptions(merge: true),
      );
      
      print('✅ Firestore 更新成功！');
      return true;
    } catch (e) {
      print('❌ 更新用户资料失败: $e');
      return false;
    }
  }

  // 压缩并转换图片为 Base64
  Future<String?> imageToBase64(File imageFile, {int maxWidth = 800, int quality = 85}) async {
    try {
      print('🖼️ 开始处理图片...');
      print('   原始路径: ${imageFile.path}');
      
      // 检查文件是否存在
      if (!await imageFile.exists()) {
        print('❌ 文件不存在！');
        return null;
      }
      
      // 读取原始文件
      Uint8List imageBytes = await imageFile.readAsBytes();
      int originalSize = imageBytes.length;
      print('   原始大小: ${(originalSize / 1024).toStringAsFixed(2)} KB');
      
      // 解码图片
      img.Image? image = img.decodeImage(imageBytes);
      if (image == null) {
        print('❌ 无法解码图片');
        return null;
      }
      
      print('   原始尺寸: ${image.width}x${image.height}');
      
      // 如果图片太大，等比例缩小
      if (image.width > maxWidth) {
        int newHeight = (image.height * maxWidth / image.width).round();
        image = img.copyResize(image, width: maxWidth, height: newHeight);
        print('   调整后尺寸: ${image.width}x${image.height}');
      }
      
      // 压缩为 JPEG
      List<int> compressedBytes = img.encodeJpg(image, quality: quality);
      int compressedSize = compressedBytes.length;
      print('   压缩后大小: ${(compressedSize / 1024).toStringAsFixed(2)} KB');
      print('   压缩率: ${((1 - compressedSize / originalSize) * 100).toStringAsFixed(1)}%');
      
      // 转换为 Base64
      String base64String = 'data:image/jpeg;base64,${base64Encode(compressedBytes)}';
      print('   Base64 大小: ${(base64String.length / 1024).toStringAsFixed(2)} KB');
      
      // 检查大小限制（建议单张图片不超过 400KB）
      if (base64String.length > 409600) { // 400KB
        print('⚠️  图片仍然较大，尝试进一步压缩...');
        
        // 降低质量再压缩一次
        compressedBytes = img.encodeJpg(image, quality: 70);
        base64String = 'data:image/jpeg;base64,${base64Encode(compressedBytes)}';
        print('   再次压缩后: ${(base64String.length / 1024).toStringAsFixed(2)} KB');
      }
      
      print('✅ 图片处理完成！');
      return base64String;
      
    } catch (e, stackTrace) {
      print('❌ 图片处理失败: $e');
      print('Stack trace: $stackTrace');
      return null;
    }
  }

  // 上传头像（实际上是转换为 Base64）
  Future<String?> uploadProfileImage(File imageFile, String uid) async {
    print('\n🖼️ 处理头像');
    String? base64 = await imageToBase64(
      imageFile,
      maxWidth: 400, // 头像较小
      quality: 85,
    );
    
    if (base64 != null) {
      print('✅ 头像处理成功\n');
    } else {
      print('❌ 头像处理失败\n');
    }
    return base64;
  }

  // 上传背景图片（实际上是转换为 Base64）
  Future<String?> uploadBackgroundImage(File imageFile, String uid) async {
    print('\n🌄 处理背景图');
    String? base64 = await imageToBase64(
      imageFile,
      maxWidth: 800, // 背景图可以大一点
      quality: 80,
    );
    
    if (base64 != null) {
      print('✅ 背景图处理成功\n');
    } else {
      print('❌ 背景图处理失败\n');
    }
    return base64;
  }

  // 删除旧图片（Base64 方案不需要删除，直接覆盖即可）
  Future<void> deleteImageFromUrl(String imageUrl) async {
    // Base64 存储在数据库中，不需要单独删除
    // 更新时直接覆盖即可
    print('ℹ️  Base64 图片直接覆盖，无需删除');
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