import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../models/userModel.dart';
import '../../services/user_service.dart';
import '../../services/apps_Loading.dart';
import 'package:image_cropper/image_cropper.dart';

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
    _usernameController =
        TextEditingController(text: widget.userProfile.username);
    _bioController = TextEditingController(text: widget.userProfile.bio);
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  // ── Image helpers ─────────────────────────────────────────────────────

  ImageProvider? _getImageProvider(String imageUrl) {
    if (imageUrl.isEmpty) return null;

    if (imageUrl.startsWith('data:image')) {
      try {
        final base64String = imageUrl.split(',')[1];
        final bytes = base64Decode(base64String);
        return MemoryImage(bytes);
      } catch (e) {
        if (kDebugMode) print('❌ Base64 decode failed: $e');
        return null;
      }
    }

    if (imageUrl.startsWith('http')) {
      return NetworkImage(imageUrl);
    }

    return null;
  }


  Future<void> _pickImage(ImageSource source, bool isProfileImage) async {
    try {
      final XFile? image = await _picker.pickImage(
        source: source,
        maxWidth: 1080,
        maxHeight: 1080,
        imageQuality: 85,
      );

      if (image == null) return;

      // 🆕 选完图先裁剪，让用户自己框选要显示的区域
      final cropped = await _cropImage(File(image.path), isProfileImage);
      if (cropped == null) return; // 用户中途取消裁剪，不改变现有图片

      setState(() {
        if (isProfileImage) {
          _newProfileImage = cropped;
        } else {
          _newBackgroundImage = cropped;
        }
      });
    } catch (e) {
      _showErrorSnackBar('Could not select image: $e');
    }
  }

  // 🆕 profile → 圆形裁剪；background → 长方形横幅比例裁剪
  Future<File?> _cropImage(File imageFile, bool isProfileImage) async {
    final cropped = await ImageCropper().cropImage(
      sourcePath: imageFile.path,
      aspectRatio: isProfileImage
          ? const CropAspectRatio(ratioX: 1, ratioY: 1)   // 圆形头像用 1:1 画布，裁剪框会以圆形呈现
          : const CropAspectRatio(ratioX: 16, ratioY: 9),  // 长方形 banner
      compressQuality: 85,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: isProfileImage ? 'Crop Profile Photo' : 'Crop Background Photo',
          toolbarColor: const Color(0xFF7C4DFF),
          toolbarWidgetColor: Colors.white,
          activeControlsWidgetColor: const Color(0xFF7C4DFF),
          lockAspectRatio: true,
          cropStyle: isProfileImage ? CropStyle.circle : CropStyle.rectangle, // 🆕 圆形 vs 长方形
        ),
        IOSUiSettings(
          title: isProfileImage ? 'Crop Profile Photo' : 'Crop Background Photo',
          aspectRatioLockEnabled: true,
          resetAspectRatioEnabled: false,
          aspectRatioPickerButtonHidden: true,
          cropStyle: isProfileImage ? CropStyle.circle : CropStyle.rectangle, // 🆕
        ),
      ],
    );
    return cropped != null ? File(cropped.path) : null;
  }

  void _showImageSourceDialog(bool isProfileImage) {
    showModalBottomSheet(
      context: context,
      builder: (BuildContext context) {
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('Choose from gallery'),
                onTap: () {
                  Navigator.pop(context);
                  _pickImage(ImageSource.gallery, isProfileImage);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera),
                title: const Text('Take a photo'),
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

  // ── Save ───────────────────────────────────────────────────────────────

  Future<void> _saveChanges() async {
    setState(() => _isLoading = true);

    // capture originals before they get overwritten below
    final oldProfileUrl    = widget.userProfile.profileImageUrl;
    final oldBackgroundUrl = widget.userProfile.backgroundImageUrl;

    try {
      String profileImageUrl = widget.userProfile.profileImageUrl;
      String backgroundImageUrl = widget.userProfile.backgroundImageUrl;

      if (_newProfileImage != null) {
        final newUrl = await _userService.uploadProfileImage(
          _newProfileImage!,
          widget.userProfile.uid,
        );
        if (newUrl != null && newUrl.isNotEmpty) {
          profileImageUrl = newUrl;
        } else {
          if (mounted) setState(() => _isLoading = false);
          _showErrorSnackBar(
            'Could not process your profile photo. Please try a different image.',
          );
          return;
        }
      }

      if (_newBackgroundImage != null) {
        final newUrl = await _userService.uploadBackgroundImage(
          _newBackgroundImage!,
          widget.userProfile.uid,
        );
        if (newUrl != null && newUrl.isNotEmpty) {
          backgroundImageUrl = newUrl;
        } else {
          if (mounted) setState(() => _isLoading = false);
          _showErrorSnackBar(
            'Could not process your background photo. Please try a different image.',
          );
          return;
        }
      }

      final updatedProfile = widget.userProfile.copyWith(
        username: _usernameController.text.trim(),
        bio: _bioController.text.trim(),
        profileImageUrl: profileImageUrl,
        backgroundImageUrl: backgroundImageUrl,
      );

      final result = await _userService.updateUserProfile(updatedProfile);

      if (!mounted) return;
      setState(() => _isLoading = false);

      if (result.success) {
        // ── fire-and-forget cleanup of replaced images ──
        if (_newProfileImage != null && oldProfileUrl != profileImageUrl) {
          _userService.deleteImageFromUrl(oldProfileUrl);
        }
        if (_newBackgroundImage != null && oldBackgroundUrl != backgroundImageUrl) {
          _userService.deleteImageFromUrl(oldBackgroundUrl);
        }

        Navigator.pop(context, true);
        _showSuccessSnackBar('Profile saved successfully!');
      } else {
        _showErrorSnackBar(result.error ?? 'Save failed, please try again.');
      }
    } catch (e) {
      if (kDebugMode) print('❌ Error while saving profile: $e');
      if (mounted) setState(() => _isLoading = false);
      _showErrorSnackBar('Something went wrong: $e');
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

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit Profile'),
        actions: [
          TextButton(
            onPressed: _isLoading ? null : _saveChanges,
            child: _isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: TravelLoadingIndicator(size: 22),
                  )
                : const Text(
                    'Save',
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
            _buildBackgroundImageSection(),
            const SizedBox(height: 20),
            _buildProfileImageSection(),
            const SizedBox(height: 30),
            Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildTextField(
                    controller: _usernameController,
                    label: 'Username',
                    hint: 'Enter your username (e.g., @username)',
                    maxLength: 30,
                  ),
                  const SizedBox(height: 20),
                  _buildTextField(
                    controller: _bioController,
                    label: 'Bio',
                    hint: 'Tell us about yourself...',
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
    ImageProvider? backgroundImage;

    if (_newBackgroundImage != null) {
      backgroundImage = FileImage(_newBackgroundImage!);
    } else {
      backgroundImage =
          _getImageProvider(widget.userProfile.backgroundImageUrl);
    }

    return Stack(
      children: [
        Container(
          height: 200,
          width: double.infinity,
          decoration: BoxDecoration(
            color: Colors.grey[300],
            image: backgroundImage != null
                ? DecorationImage(image: backgroundImage, fit: BoxFit.cover)
                : null,
          ),
          child: backgroundImage == null
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.image, size: 50, color: Colors.grey),
                      SizedBox(height: 8),
                      Text(
                        'Tap the camera icon to add a background photo',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                )
              : null,
        ),
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
    ImageProvider profileImage;

    if (_newProfileImage != null) {
      profileImage = FileImage(_newProfileImage!);
    } else {
      final dbImage = _getImageProvider(widget.userProfile.profileImageUrl);
      profileImage = dbImage ?? const AssetImage('assets/images/profile.jpg');
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
                if (kDebugMode) print('❌ Profile image loading failed: $exception');
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