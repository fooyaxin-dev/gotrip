import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'userModel.dart';
import '../../services/user_service.dart';

class EditProfilePage extends StatefulWidget {
  final UserProfile userProfile;

  const EditProfilePage({super.key, required this.userProfile});

  @override
  State<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends State<EditProfilePage> {
  final UserService _userService = UserService();
  final ImagePicker _picker = ImagePicker();
  
  late TextEditingController _displayNameController;
  late TextEditingController _usernameController;
  late TextEditingController _bioController;
  
  File? _newProfileImage;
  File? _newBackgroundImage;
  
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _usernameController = TextEditingController(text: widget.userProfile.username);
    _bioController = TextEditingController(text: widget.userProfile.bio);
    
    print('═══════════════════════════════════════');
    print('📝 EditProfilePage 初始化');
    print('═══════════════════════════════════════');
    print('当前数据:');
    print('  username: ${widget.userProfile.username}');
    print('  bio: ${widget.userProfile.bio}');
    print('  profileImageUrl: ${widget.userProfile.profileImageUrl}');
    print('  backgroundImageUrl: ${widget.userProfile.backgroundImageUrl}');
    print('═══════════════════════════════════════');
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  // 选择图片
  Future<void> _pickImage(ImageSource source, bool isProfileImage) async {
    try {
      print('📸 开始选择图片: ${isProfileImage ? "头像" : "背景"}');
      
      final XFile? image = await _picker.pickImage(
        source: source,
        maxWidth: 1080,
        maxHeight: 1080,
        imageQuality: 85,
      );

      if (image != null) {
        print('✅ 图片已选择: ${image.path}');
        print('   文件大小: ${await File(image.path).length()} bytes');
        
        setState(() {
          if (isProfileImage) {
            _newProfileImage = File(image.path);
            print('   → 设置为新头像');
          } else {
            _newBackgroundImage = File(image.path);
            print('   → 设置为新背景');
          }
        });
      } else {
        print('❌ 用户取消选择图片');
      }
    } catch (e) {
      print('❌ 选择图片失败: $e');
      _showErrorSnackBar('选择图片失败: $e');
    }
  }

  // 显示选择图片来源对话框
  void _showImageSourceDialog(bool isProfileImage) {
    showModalBottomSheet(
      context: context,
      builder: (BuildContext context) {
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('从相册选择'),
                onTap: () {
                  Navigator.pop(context);
                  _pickImage(ImageSource.gallery, isProfileImage);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera),
                title: const Text('拍照'),
                onTap: () {
                  Navigator.pop(context);
                  _pickImage(ImageSource.camera, isProfileImage);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  // 保存更改 - 带详细调试
  Future<void> _saveChanges() async {
    print('\n═══════════════════════════════════════');
    print('💾 开始保存更改');
    print('═══════════════════════════════════════');
    
    setState(() {
      _isLoading = true;
    });

    try {
      // 初始化 URL（使用当前的值）
      String profileImageUrl = widget.userProfile.profileImageUrl;
      String backgroundImageUrl = widget.userProfile.backgroundImageUrl;
      
      print('📋 初始值:');
      print('  profileImageUrl: $profileImageUrl');
      print('  backgroundImageUrl: $backgroundImageUrl');
      print('');

      // 上传新头像
      if (_newProfileImage != null) {
        print('📤 上传新头像...');
        print('  文件路径: ${_newProfileImage!.path}');
        
        String? newUrl = await _userService.uploadProfileImage(
          _newProfileImage!,
          widget.userProfile.uid,
        );
        
        print('📥 上传结果:');
        print('  返回的 URL: $newUrl');
        
        if (newUrl != null && newUrl.isNotEmpty) {
          print('  ✅ 头像上传成功！');
          
          // 删除旧图片（如果有）
          if (profileImageUrl.isNotEmpty) {
            print('  🗑️ 删除旧头像: $profileImageUrl');
            await _userService.deleteImageFromUrl(profileImageUrl);
          }
          
          profileImageUrl = newUrl;
          print('  ✅ 头像 URL 已更新: $profileImageUrl');
        } else {
          print('  ❌ 头像上传失败！返回的 URL 为空');
        }
        print('');
      } else {
        print('ℹ️  没有新头像需要上传');
        print('');
      }

      // 上传新背景图
      if (_newBackgroundImage != null) {
        print('📤 上传新背景图...');
        print('  文件路径: ${_newBackgroundImage!.path}');
        
        String? newUrl = await _userService.uploadBackgroundImage(
          _newBackgroundImage!,
          widget.userProfile.uid,
        );
        
        print('📥 上传结果:');
        print('  返回的 URL: $newUrl');
        
        if (newUrl != null && newUrl.isNotEmpty) {
          print('  ✅ 背景图上传成功！');
          
          // 删除旧图片（如果有）
          if (backgroundImageUrl.isNotEmpty) {
            print('  🗑️ 删除旧背景图: $backgroundImageUrl');
            await _userService.deleteImageFromUrl(backgroundImageUrl);
          }
          
          backgroundImageUrl = newUrl;
          print('  ✅ 背景图 URL 已更新: $backgroundImageUrl');
        } else {
          print('  ❌ 背景图上传失败！返回的 URL 为空');
        }
        print('');
      } else {
        print('ℹ️  没有新背景图需要上传');
        print('');
      }

      // 准备要保存的数据
      print('📋 准备保存到数据库的数据:');
      print('  username: ${_usernameController.text.trim()}');
      print('  bio: ${_bioController.text.trim()}');
      print('  profileImageUrl: $profileImageUrl');
      print('  backgroundImageUrl: $backgroundImageUrl');
      print('');

      // 创建更新后的用户资料
      UserProfile updatedProfile = widget.userProfile.copyWith(
        username: _usernameController.text.trim(),
        bio: _bioController.text.trim(),
        profileImageUrl: profileImageUrl,
        backgroundImageUrl: backgroundImageUrl,
      );

      print('🔍 检查 updatedProfile:');
      print('  profileImageUrl: ${updatedProfile.profileImageUrl}');
      print('  backgroundImageUrl: ${updatedProfile.backgroundImageUrl}');
      print('');

      print('💾 调用 updateUserProfile...');
      Map<String, dynamic> dataToSave = updatedProfile.toMap();
      print('📤 要保存的 Map:');
      dataToSave.forEach((key, value) {
        print('  $key: $value');
      });
      print('');

      // 保存到数据库
      bool success = await _userService.updateUserProfile(updatedProfile);

      print('💾 保存结果: $success');
      print('');

      if (success) {
        print('✅ 保存成功！');
        print('═══════════════════════════════════════\n');
        
        if (mounted) {
          Navigator.pop(context, true); // 返回 true 表示已更新
          _showSuccessSnackBar('保存成功！');
        }
      } else {
        print('❌ 保存失败！');
        print('═══════════════════════════════════════\n');
        _showErrorSnackBar('保存失败，请重试');
      }
    } catch (e, stackTrace) {
      print('❌ 保存过程中出错: $e');
      print('Stack trace: $stackTrace');
      print('═══════════════════════════════════════\n');
      _showErrorSnackBar('保存失败: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _showSuccessSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('编辑资料'),
        actions: [
          TextButton(
            onPressed: _isLoading ? null : _saveChanges,
            child: _isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text(
                    '保存',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            // 背景图片编辑
            _buildBackgroundImageSection(),

            const SizedBox(height: 20),

            // 头像编辑
            _buildProfileImageSection(),

            const SizedBox(height: 30),

            // 表单
            Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildTextField(
                    controller: _usernameController,
                    label: '用户名',
                    hint: '输入您的用户名 (例如: @username)',
                    maxLength: 30,
                  ),
                  const SizedBox(height: 20),
                  _buildTextField(
                    controller: _bioController,
                    label: '个人简介',
                    hint: '介绍一下自己...',
                    maxLines: 4,
                    maxLength: 150,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBackgroundImageSection() {
    return Stack(
      children: [
        // 背景图片
        Container(
          height: 200,
          width: double.infinity,
          decoration: BoxDecoration(
            color: Colors.grey[300],
            image: _newBackgroundImage != null
                ? DecorationImage(
                    image: FileImage(_newBackgroundImage!),
                    fit: BoxFit.cover,
                  )
                : (widget.userProfile.backgroundImageUrl.isNotEmpty
                    ? DecorationImage(
                        image: NetworkImage(widget.userProfile.backgroundImageUrl),
                        fit: BoxFit.cover,
                      )
                    : null),
          ),
          child: _newBackgroundImage == null && widget.userProfile.backgroundImageUrl.isEmpty
              ? const Center(
                  child: Icon(
                    Icons.image,
                    size: 50,
                    color: Colors.grey,
                  ),
                )
              : null,
        ),
        // 编辑按钮
        Positioned(
          right: 10,
          bottom: 10,
          child: FloatingActionButton.small(
            heroTag: 'bg',
            onPressed: () => _showImageSourceDialog(false),
            backgroundColor: Colors.white,
            child: const Icon(Icons.camera_alt, color: Colors.black87),
          ),
        ),
      ],
    );
  }

  Widget _buildProfileImageSection() {
    return Stack(
      children: [
        CircleAvatar(
          radius: 60,
          backgroundColor: Colors.orange,
          child: CircleAvatar(
            radius: 57,
            backgroundColor: Colors.white,
            child: CircleAvatar(
              radius: 55,
              backgroundImage: _newProfileImage != null
                  ? FileImage(_newProfileImage!)
                  : (widget.userProfile.profileImageUrl.isNotEmpty
                      ? NetworkImage(widget.userProfile.profileImageUrl)
                      : const AssetImage('asset/images/profile.jpg')) as ImageProvider,
            ),
          ),
        ),
        Positioned(
          right: 0,
          bottom: 0,
          child: FloatingActionButton.small(
            heroTag: 'profile',
            onPressed: () => _showImageSourceDialog(true),
            backgroundColor: Colors.orange,
            child: const Icon(Icons.camera_alt, color: Colors.white, size: 20),
          ),
        ),
      ],
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    int maxLines = 1,
    int? maxLength,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          maxLines: maxLines,
          maxLength: maxLength,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: Colors.grey[400]),
            filled: true,
            fillColor: Colors.grey[100],
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Colors.orange, width: 2),
            ),
          ),
        ),
      ],
    );
  }
}