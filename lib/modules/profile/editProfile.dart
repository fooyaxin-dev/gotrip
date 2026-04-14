import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../models/userModel.dart';
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
    print('  profileImageUrl length: ${widget.userProfile.profileImageUrl.length}');
    print('  backgroundImageUrl length: ${widget.userProfile.backgroundImageUrl.length}');
    print('═══════════════════════════════════════');
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  // ⭐ 新增：从 Base64 或 URL 获取 ImageProvider
  ImageProvider? _getImageProvider(String imageUrl) {
    if (imageUrl.isEmpty) {
      return null; // 返回 null，让调用者处理默认情况
    }

    // 检查是否是 Base64 图片
    if (imageUrl.startsWith('data:image')) {
      try {
        // 提取 Base64 部分
        String base64String = imageUrl.split(',')[1];
        Uint8List bytes = base64Decode(base64String);
        print('✅ Base64 picture decode successful，size: ${bytes.length} bytes');
        return MemoryImage(bytes);
      } catch (e) {
        print('❌ Base64 decode failed: $e');
        return null;
      }
    }

    // 如果是 URL（未来可能用）
    if (imageUrl.startsWith('http')) {
      return NetworkImage(imageUrl);
    }

    return null;
  }

  // 选择图片
  Future<void> _pickImage(ImageSource source, bool isProfileImage) async {
    try {
   
      
      final XFile? image = await _picker.pickImage(
        source: source,
        maxWidth: 1080,
        maxHeight: 1080,
        imageQuality: 85,
      );

      if (image != null) {
        print('✅ selected image: ${image.path}');
        print('   file size: ${await File(image.path).length()} bytes');
        
        setState(() {
          if (isProfileImage) {
            _newProfileImage = File(image.path);
            print('   → set as new profile image');
          } else {
            _newBackgroundImage = File(image.path);
            print('   → set as new background image');
          }
        });
      } else {
        print('❌ user cancelled image selection');
      }
    } catch (e) {
      print('❌ choose image failed: $e');
      _showErrorSnackBar('choose image failed: $e');
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
                title: const Text('choose from gallery'),
                onTap: () {
                  Navigator.pop(context);
                  _pickImage(ImageSource.gallery, isProfileImage);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera),
                title: const Text('take a photo'),
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

  // 保存更改
  Future<void> _saveChanges() async {
    print('\n═══════════════════════════════════════');
    print('💾 start saving changes');
    print('═══════════════════════════════════════');
    
    setState(() {
      _isLoading = true;
    });

    try {
      // 初始化 URL（使用当前的值）
      String profileImageUrl = widget.userProfile.profileImageUrl;
      String backgroundImageUrl = widget.userProfile.backgroundImageUrl;
      
      print('📋 initial values:');
      print('  profileImageUrl length: ${profileImageUrl.length}');
      print('  backgroundImageUrl length: ${backgroundImageUrl.length}');
      print('');

      // 上传新头像
      if (_newProfileImage != null) {
        print('📤 start processing new profile image...');
        print('  file path: ${_newProfileImage!.path}');
        
        String? newUrl = await _userService.uploadProfileImage(
          _newProfileImage!,
          widget.userProfile.uid,
        );
        
        print('📥 processing result:');
        print('  returned Base64 length: ${newUrl?.length ?? 0}');
        
        if (newUrl != null && newUrl.isNotEmpty) {
          print('  ✅ profile image processing successful!');
          profileImageUrl = newUrl;
          print('  ✅ profile image updated');
        } else {
          print('  ❌ profile image processing failed!');
        }
        print('');
      } else {
        print('ℹ️  no new profile image to upload');
        print('');
      }

      // 上传新背景图
      if (_newBackgroundImage != null) {
        print('📤 start processing new background image...');
        print('  file path: ${_newBackgroundImage!.path}');
        
        String? newUrl = await _userService.uploadBackgroundImage(
          _newBackgroundImage!,
          widget.userProfile.uid,
        );
        
        print('📥 processing result:');
        print('  returned Base64 length: ${newUrl?.length ?? 0}');
        
        if (newUrl != null && newUrl.isNotEmpty) {
          print('  ✅ background image processing successful!');
          backgroundImageUrl = newUrl;
          print('  ✅ background image updated');
        } else {
          print('  ❌ background image processing failed!');
        }
        print('');
      } else {
        print('ℹ️  no new background image to upload');
        print('');
      }

      // 准备要保存的数据
      print('📋 initial values:');
      print('  username: ${_usernameController.text.trim()}');
      print('  bio: ${_bioController.text.trim()}');
      print('  profileImageUrl length: ${profileImageUrl.length}');
      print('  backgroundImageUrl length: ${backgroundImageUrl.length}');
      print('');

      // 创建更新后的用户资料
      UserProfile updatedProfile = widget.userProfile.copyWith(
        username: _usernameController.text.trim(),
        bio: _bioController.text.trim(),
        profileImageUrl: profileImageUrl,
        backgroundImageUrl: backgroundImageUrl,
      );

      print('💾 use updateUserProfile...');

      // 保存到数据库
      bool success = await _userService.updateUserProfile(updatedProfile);

      print('💾 save result: $success');
      print('');

      if (success) {
        print('✅ save successful!');
        print('═══════════════════════════════════════\n');
        
        if (mounted) {
          Navigator.pop(context, true); // 返回 true 表示已更新
          _showSuccessSnackBar('save successful！');
        }
      } else {
        print('❌ save failed: unknown error');
        print('═══════════════════════════════════════\n');
        _showErrorSnackBar('save failed，please try again');
      }
    } catch (e, stackTrace) {
      print('❌ 保存过程中出错: $e');
      print('Stack trace: $stackTrace');
      print('═══════════════════════════════════════\n');
      _showErrorSnackBar('save failed: $e');
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
        title: const Text('edit profile'),
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
                    'save',
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
                    label: 'username',
                    hint: 'enter your username (e.g., @username)',
                    maxLength: 30,
                  ),
                  const SizedBox(height: 20),
                  _buildTextField(
                    controller: _bioController,
                    label: 'bio',
                    hint: 'tell us about yourself...',
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
    // ⭐ 优先显示新选择的图片，否则显示数据库中的图片
    ImageProvider? backgroundImage;
    
    if (_newBackgroundImage != null) {
      // 用户刚选择的新图片
      backgroundImage = FileImage(_newBackgroundImage!);
      print('🖼️ displaying newly selected background image');
    } else {
      // 数据库中的图片（Base64 或 URL）
      backgroundImage = _getImageProvider(widget.userProfile.backgroundImageUrl);
      if (backgroundImage != null) {
        print('🖼️ displaying background image from database');
      } else {
        print('🖼️ no background image, displaying default');
      }
    }

    return Stack(
      children: [
        // 背景图片
        Container(
          height: 200,
          width: double.infinity,
          decoration: BoxDecoration(
            color: Colors.grey[300],
            image: backgroundImage != null
                ? DecorationImage(
                    image: backgroundImage,
                    fit: BoxFit.cover,
                  )
                : null,
          ),
          child: backgroundImage == null
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.image,
                        size: 50,
                        color: Colors.grey,
                      ),
                      SizedBox(height: 8),
                      Text(
                        'click the button below to add a background image',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ],
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
    // ⭐ 优先显示新选择的图片，否则显示数据库中的图片
    ImageProvider profileImage;
    
    if (_newProfileImage != null) {
      // 用户刚选择的新图片
      profileImage = FileImage(_newProfileImage!);
      print('👤 displaying newly selected profile image');
    } else {
      // 数据库中的图片（Base64 或 URL）
      ImageProvider? dbImage = _getImageProvider(widget.userProfile.profileImageUrl);
      if (dbImage != null) {
        profileImage = dbImage;
        print('👤 displaying profile image from database');
      } else {
        // 默认头像
        profileImage = const AssetImage('assets/images/profile.jpg');
        print('👤 displaying default profile image');
      }
    }

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
              backgroundImage: profileImage,
              onBackgroundImageError: (exception, stackTrace) {
                print('❌ profile image loading failed: $exception');
              },
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