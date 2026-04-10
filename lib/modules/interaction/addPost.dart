import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:io';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import '../../services/userPost_service.dart';
import '../../services/placesAPI_service.dart'; 

class PostingPage extends StatefulWidget {
  const PostingPage({super.key});

  @override
  State<PostingPage> createState() => _PostingPageState();
}

class _PostingPageState extends State<PostingPage> {
  int rating = 0;
  bool isAnonymous = false;
  bool allowComments = true;
  bool allowShare = true;
  bool isUploading = false;

  List<File> selectedImages = [];
  final ImagePicker _picker = ImagePicker();

  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _contentController = TextEditingController();

  String? selectedCity;   
  String? selectedLocation; 
  List<String> selectedTags = [];
  List<String> mentionedFriends = [];
  String? selectedTopic;
  String selectedVisibility = "public";

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final UserStatsService _statsService = UserStatsService();

  final List<String> availableTags = [
    'food', 'travel', 'photography', 'daily', 'vlog',
    'fashion', 'fitness', 'beauty', 'study', 'work'
  ];

  final List<String> hotTopics = [
    '#malaysia', '#KLCC', '#penang', '#cameratips', '#foodie', '#travelvlog', '#transport', '#journey', '#niceView', '#happyTravel',
  
  ];

  // ===== 从 formattedAddress 解析城市 =====
  // 格式: "Street, Area, PostCode City, State, Country"
  // 策略: 找含邮编的段，提取其中的城市名；备用倒数第2段
  String _extractCityFromAddress(String address) {
    if (address.isEmpty) return '';
    final parts = address.split(',').map((s) => s.trim()).toList();
    for (final part in parts) {
      final match = RegExp(r'^\d{4,6}\s+(.+)$').firstMatch(part);
      if (match != null) return match.group(1)!.trim();
    }
    if (parts.length >= 2) return parts[parts.length - 2];
    return parts.first;
  }

  // ===== 保存图片到本地 =====
  Future<List<String>> _saveImagesToLocal(List<File> images) async {
    List<String> imagePaths = [];
    try {
      final directory = await getApplicationDocumentsDirectory();
      final postsDir = Directory('${directory.path}/posts');
      if (!await postsDir.exists()) await postsDir.create(recursive: true);
      for (int i = 0; i < images.length; i++) {
        String fileName = '${DateTime.now().millisecondsSinceEpoch}_$i.jpg';
        String filePath = '${postsDir.path}/$fileName';
        await images[i].copy(filePath);
        imagePaths.add(filePath);
      }
      return imagePaths;
    } catch (e) {
      throw Exception('Save Images Failed: $e');
    }
  }

  // ===== 图片转 Base64 =====
  Future<List<String>> _convertImagesToBase64(List<File> images) async {
    List<String> base64Images = [];
    try {
      for (var image in images) {
        List<int> imageBytes = await image.readAsBytes();
        base64Images.add(base64Encode(imageBytes));
      }
      return base64Images;
    } catch (e) {
      throw Exception('Convert Images to Base64 Failed: $e');
    }
  }

  // ===== 保存帖子到 Firestore =====
  Future<void> _savePostToFirestore(List<String> imagePaths) async {
    try {
      User? currentUser = _auth.currentUser;
      if (currentUser == null) throw Exception('User not logged in');

      String userId = currentUser.uid;
      DocumentSnapshot userDoc = await _firestore.collection('users').doc(userId).get();

      String userName = 'Unknown User';
      String? userPhoto;

      if (userDoc.exists) {
        Map<String, dynamic> userData = userDoc.data() as Map<String, dynamic>;
        userName = userData['username'] ??
            currentUser.displayName ??
            currentUser.email?.split('@')[0] ??
            'User_${userId.substring(0, 8)}';
        userPhoto = userData['profileImageUrl'];
      }

      Map<String, dynamic> postData = {
        'title': _titleController.text,
        'content': _contentController.text,
        'imagePaths': imagePaths,
        'rating': rating,
        'isAnonymous': isAnonymous,
        'allowComments': allowComments,
        'allowShare': allowShare,
        'city': selectedCity,         // ✅ 用于 InteractionPage 按城市过滤
        'location': selectedLocation, // 具体地点名称
        'tags': selectedTags,
        'mentionedFriends': mentionedFriends,
        'topic': selectedTopic,
        'visibility': selectedVisibility,
        'createdAt': FieldValue.serverTimestamp(),
        'userId': userId,
        'userName': userName,
        'userPhoto': userPhoto,
        'userEmail': currentUser.email,
        'likes': 0,
        'comments': 0,
        'shares': 0,
      };

      await _firestore.collection('posts').add(postData);
    } catch (e) {
      throw Exception('Save Post Failed: $e');
    }
  }

  // ===== 图片相关 =====
  Future<void> _pickImageFromGallery() async {
    try {
      final List<XFile>? images = await _picker.pickMultiImage();
      if (images != null && images.isNotEmpty) {
        setState(() {
          for (var image in images) {
            if (selectedImages.length < 9) selectedImages.add(File(image.path));
          }
        });
      }
    } catch (e) {
      _showErrorDialog('Select Images Failed: $e');
    }
  }

  Future<void> _takePhoto() async {
    try {
      final XFile? photo = await _picker.pickImage(source: ImageSource.camera, imageQuality: 80);
      if (photo != null) setState(() => selectedImages.add(File(photo.path)));
    } catch (e) {
      _showErrorDialog('Take Photo Failed: $e');
    }
  }

  Future<void> _pickVideo() async {
    try {
      final XFile? video = await _picker.pickVideo(source: ImageSource.gallery, maxDuration: const Duration(minutes: 5));
      if (video != null) _showSuccessDialog('Video Selected Successfully');
    } catch (e) {
      _showErrorDialog('Select Video Failed: $e');
    }
  }

  void _showImageSourceDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20)),
          ),
          child: SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const SizedBox(height: 20),
              const Text('选择上传方式', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              ListTile(
                leading: const Icon(Icons.camera_alt, color: Color(0xFFD35D3E)),
                title: const Text('Take Photo'),
                onTap: () { Navigator.pop(context); _takePhoto(); },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library, color: Color(0xFFD35D3E)),
                title: const Text('Choose from Gallery'),
                onTap: () { Navigator.pop(context); _pickImageFromGallery(); },
              ),
              ListTile(
                leading: const Icon(Icons.videocam, color: Color(0xFFD35D3E)),
                title: const Text('Select Video'),
                onTap: () { Navigator.pop(context); _pickVideo(); },
              ),
              const SizedBox(height: 10),
              ListTile(
                title: const Center(child: Text('Cancel', style: TextStyle(color: Colors.grey))),
                onTap: () => Navigator.pop(context),
              ),
              const SizedBox(height: 10),
            ]),
          ),
        );
      },
    );
  }

  void _removeImage(int index) => setState(() => selectedImages.removeAt(index));

  // ===== ✅ 地点选择 — 改用 Google Autocomplete =====
  void _showLocationPicker() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _LocationPickerSheet(
        onPlaceSelected: (String placeName, String address) {
          final city = _extractCityFromAddress(address);
          setState(() {
            selectedLocation = placeName;
            selectedCity = city;
          });
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Location Selected: $placeName${city.isNotEmpty ? ' · $city' : ''}'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 1),
          ));
        },
      ),
    );
  }

  // ===== 标签 =====
  void _showTagPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(builder: (context, setModalState) {
          return Container(
            height: 400,
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20)),
            ),
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  const Text('Add Tags', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
                ]),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: availableTags.map((tag) {
                      bool isSelected = selectedTags.contains(tag);
                      return GestureDetector(
                        onTap: () {
                          setModalState(() {
                            if (isSelected) {
                              selectedTags.remove(tag);
                            } else {
                              if (selectedTags.length < 5) selectedTags.add(tag);
                            }
                          });
                          setState(() {});
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: isSelected ? const Color(0xFFD35D3E) : Colors.grey[200],
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(tag, style: TextStyle(color: isSelected ? Colors.white : Colors.black, fontSize: 14)),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
            ]),
          );
        });
      },
    );
  }

  // ===== 话题 =====
  void _showTopicPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          height: 350,
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20)),
          ),
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                const Text('Select Topic', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
              ]),
            ),
            Expanded(
              child: ListView(children: hotTopics.map((topic) {
                return ListTile(
                  leading: const Icon(Icons.tag, color: Color(0xFFD35D3E)),
                  title: Text(topic),
                  trailing: selectedTopic == topic ? const Icon(Icons.check, color: Color(0xFFD35D3E)) : null,
                  onTap: () {
                    setState(() => selectedTopic = topic);
                    Navigator.pop(context);
                    _showSuccessDialog('Topic Added Successfully');
                  },
                );
              }).toList()),
            ),
          ]),
        );
      },
    );
  }

  // // ===== @好友 =====
  // void _showMentionFriends() {
  //   showModalBottomSheet(
  //     context: context,
  //     backgroundColor: Colors.transparent,
  //     isScrollControlled: true,
  //     builder: (context) {
  //       return Container(
  //         height: MediaQuery.of(context).size.height * 0.7,
  //         decoration: const BoxDecoration(
  //           color: Colors.white,
  //           borderRadius: BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20)),
  //         ),
  //         child: Column(children: [
  //           Padding(
  //             padding: const EdgeInsets.all(16),
  //             child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
  //               const Text('@ Friends', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
  //               IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
  //             ]),
  //           ),
  //           Padding(
  //             padding: const EdgeInsets.symmetric(horizontal: 16),
  //             child: TextField(
  //               decoration: InputDecoration(hintText: 'Search Friends', prefixIcon: const Icon(Icons.search), border: OutlineInputBorder(borderRadius: BorderRadius.circular(10))),
  //             ),
  //           ),
  //           const SizedBox(height: 10),
  //           Expanded(
  //             child: ListView(children: [
  //               _buildFriendItem('小明', '@xiaoming'),
  //               _buildFriendItem('小红', '@xiaohong'),
  //               _buildFriendItem('Traveler01', '@traveler01'),
  //               _buildFriendItem('GoTrip User', '@gotripuser'),
  //             ]),
  //           ),
  //         ]),
  //       );
  //     },
  //   );
  // }

  Widget _buildFriendItem(String name, String username) {
    bool isSelected = mentionedFriends.contains(username);
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Colors.primaries[name.hashCode % Colors.primaries.length],
        child: Text(name[0], style: const TextStyle(color: Colors.white)),
      ),
      title: Text(name),
      subtitle: Text(username),
      trailing: Checkbox(
        value: isSelected,
        activeColor: const Color(0xFFD35D3E),
        onChanged: (bool? value) {
          setState(() {
            if (value == true) mentionedFriends.add(username);
            else mentionedFriends.remove(username);
          });
        },
      ),
    );
  }

  // ===== 可见范围 =====
  void _showVisibilitySettings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20)),
          ),
          child: SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const SizedBox(height: 20),
              const Text('谁可以看', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              _buildVisibilityOption('public', 'visible by everyone', Icons.public),
              _buildVisibilityOption('friends', 'only friends can see', Icons.people),
              _buildVisibilityOption('private', 'only me can see', Icons.lock),
              const SizedBox(height: 20),
            ]),
          ),
        );
      },
    );
  }

  Widget _buildVisibilityOption(String title, String subtitle, IconData icon) {
    bool isSelected = selectedVisibility == title;
    return ListTile(
      leading: Icon(icon, color: isSelected ? const Color(0xFFD35D3E) : Colors.grey),
      title: Text(title, style: TextStyle(fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
      subtitle: Text(subtitle),
      trailing: isSelected ? const Icon(Icons.check, color: Color(0xFFD35D3E)) : null,
      onTap: () {
        setState(() => selectedVisibility = title);
        Navigator.pop(context);
      },
    );
  }

  // ===== 发布 =====
  Future<void> _publishPost() async {
    if (_titleController.text.isEmpty || _contentController.text.isEmpty) {
      _showErrorDialog('Please fill in the title and content');
      return;
    }
    if (selectedImages.isEmpty) {
      _showErrorDialog('Please upload at least one image');
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator(color: Color(0xFFD35D3E))),
    );

    setState(() => isUploading = true);

    try {
      List<String> imagePaths = await _saveImagesToLocal(selectedImages);
      await _savePostToFirestore(imagePaths);
      await _statsService.incrementPostCount();

      Navigator.pop(context);
      _showSuccessDialog('Post published successfully!');
      await Future.delayed(const Duration(seconds: 1));
      Navigator.pop(context);
    } catch (e) {
      Navigator.pop(context);
      _showErrorDialog('Failed to publish post: $e');
    } finally {
      setState(() => isUploading = false);
    }
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Error'),
        content: Text(message),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
  }

  void _showSuccessDialog(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.green, duration: const Duration(seconds: 1)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leadingWidth: 80,
        leading: TextButton(
          onPressed: isUploading ? null : () => Navigator.pop(context),
          child: Text("Cancel", style: TextStyle(color: isUploading ? Colors.grey : Colors.black54, fontSize: 16)),
        ),
        title: Row(mainAxisSize: MainAxisSize.min, children: [
          const Text("Post", style: TextStyle(color: Colors.black, fontSize: 17, fontWeight: FontWeight.bold)),
          const SizedBox(width: 4),
        ]),
        centerTitle: true,
        actions: [
          
          const SizedBox(width: 12),
          Center(
            child: GestureDetector(
              onTap: isUploading ? null : _publishPost,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                decoration: BoxDecoration(
                  color: isUploading ? Colors.grey : const Color(0xFFD35D3E),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text("Post", style: TextStyle(color: Colors.white, fontSize: 14)),
              ),
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Stack(children: [
        SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const SizedBox(height: 20),

            // ── 图片区 ──
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                ...selectedImages.asMap().entries.map((entry) {
                  int index = entry.key;
                  File image = entry.value;
                  return Stack(children: [
                    Container(
                      width: 100, height: 100,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        image: DecorationImage(image: FileImage(image), fit: BoxFit.cover),
                      ),
                    ),
                    Positioned(
                      top: 2, right: 2,
                      child: GestureDetector(
                        onTap: () => _removeImage(index),
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), shape: BoxShape.circle),
                          child: const Icon(Icons.close, color: Colors.white, size: 16),
                        ),
                      ),
                    ),
                  ]);
                }),
                if (selectedImages.length < 9)
                  GestureDetector(
                    onTap: _showImageSourceDialog,
                    child: CustomPaint(
                      painter: DottedBorderPainter(),
                      child: SizedBox(
                        width: 100, height: 100,
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Icon(Icons.camera_alt_outlined, color: Colors.grey[700], size: 30),
                          const SizedBox(height: 4),
                          Text("Upload Video/Photo", style: TextStyle(color: Colors.grey[500], fontSize: 10)),
                        ]),
                      ),
                    ),
                  ),
              ],
            ),

            const SizedBox(height: 30),

            TextField(
              controller: _titleController,
              enabled: !isUploading,
              decoration: const InputDecoration(
                hintText: "Enter title~",
                hintStyle: TextStyle(color: Colors.grey, fontSize: 16),
                border: InputBorder.none,
              ),
            ),
            Divider(color: Colors.grey[200], thickness: 1),

            TextField(
              controller: _contentController,
              enabled: !isUploading,
              maxLines: 8,
              decoration: const InputDecoration(
                hintText: " What's on your mind? Share your travel experience, tips, or stories with the community!",
                hintStyle: TextStyle(color: Colors.grey, fontSize: 14),
                border: InputBorder.none,
              ),
            ),

            const SizedBox(height: 20),

            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: Colors.grey[50], borderRadius: BorderRadius.circular(12)),
              child: Column(children: [
                // ✅ 地点按钮 — label 显示 "地点 · 城市"
                _buildFeatureButton(
                  icon: Icons.location_on_outlined,
                  label: selectedLocation != null
                      ? '$selectedLocation${selectedCity != null && selectedCity!.isNotEmpty ? ' · $selectedCity' : ''}'
                      : 'Add Location',
                  onTap: _showLocationPicker,
                  hasValue: selectedLocation != null,
                ),
                const Divider(height: 20),
                _buildFeatureButton(
                  icon: Icons.tag,
                  label: selectedTopic ?? 'Add Topic',
                  onTap: _showTopicPicker,
                  hasValue: selectedTopic != null,
                ),
                const Divider(height: 20),
                _buildFeatureButton(
                  icon: Icons.sell_outlined,
                  label: selectedTags.isEmpty ? 'Add Tags' : selectedTags.join(', '),
                  onTap: _showTagPicker,
                  hasValue: selectedTags.isNotEmpty,
                ),
                const Divider(height: 20),
                // _buildFeatureButton(
                //   icon: Icons.alternate_email,
                //   label: mentionedFriends.isEmpty ? '@ 好友' : '已选择 ${mentionedFriends.length} 位好友',
                //   onTap: _showMentionFriends,
                //   hasValue: mentionedFriends.isNotEmpty,
                // ),
                const Divider(height: 20),
                _buildFeatureButton(
                  icon: Icons.visibility_outlined,
                  label: 'Visibility: $selectedVisibility',
                  onTap: _showVisibilitySettings,
                  hasValue: true,
                ),
              ]),
            ),

            const SizedBox(height: 30),

            // ── 评分 ──
            Row(children: [
              const Text("Rating", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(width: 15),
              ...List.generate(5, (index) => GestureDetector(
                onTap: isUploading ? null : () => setState(() => rating = index + 1),
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(Icons.star_rounded, size: 32, color: index < rating ? Colors.orange : Colors.grey[300]),
                ),
              )),
            ]),

            const SizedBox(height: 25),

            _buildSwitchOption('Anonymous', 'Anonymous will hide your avatar and nickname', isAnonymous, (v) => setState(() => isAnonymous = v)),
            const SizedBox(height: 15),
            _buildSwitchOption('Allow Comments', 'Other users can comment on your post', allowComments, (v) => setState(() => allowComments = v)),
            const SizedBox(height: 15),
            _buildSwitchOption('Allow Sharing', 'Other users can share your post', allowShare, (v) => setState(() => allowShare = v)),

            const SizedBox(height: 150),
          ]),
        ),

        // ── 发布浮动按钮 ──
        if (!isUploading)
          Positioned(
            right: 20, bottom: 30,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: _publishPost,
                borderRadius: BorderRadius.circular(40),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 25, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFD35D3E).withOpacity(0.9),
                    borderRadius: BorderRadius.circular(40),
                    boxShadow: [BoxShadow(color: const Color(0xFFD35D3E).withOpacity(0.3), blurRadius: 15, offset: const Offset(0, 5))],
                  ),
                  child: const Row(children: [
                    Icon(Icons.send_rounded, color: Colors.white, size: 20),
                    SizedBox(width: 10),
                    Text("Post", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                  ]),
                ),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _buildFeatureButton({required IconData icon, required String label, required VoidCallback onTap, required bool hasValue}) {
    return InkWell(
      onTap: isUploading ? null : onTap,
      child: Row(children: [
        Icon(icon, color: hasValue ? const Color(0xFFD35D3E) : Colors.grey[600], size: 22),
        const SizedBox(width: 12),
        Expanded(
          child: Text(label,
            style: TextStyle(fontSize: 15, color: hasValue ? Colors.black : Colors.grey[600], fontWeight: hasValue ? FontWeight.w500 : FontWeight.normal),
            maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        Icon(Icons.chevron_right, color: Colors.grey[400]),
      ]),
    );
  }

  Widget _buildSwitchOption(String title, String subtitle, bool value, Function(bool) onChanged) {
    return Row(children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(subtitle, style: TextStyle(color: Colors.grey[500], fontSize: 12)),
      ])),
      Switch(value: value, activeColor: const Color(0xFFD35D3E), onChanged: isUploading ? null : onChanged),
    ]);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }
}

// =====================================================
// ✅ Location Picker Sheet — Google Autocomplete
// =====================================================
class _LocationPickerSheet extends StatefulWidget {
  final void Function(String placeName, String address) onPlaceSelected;
  const _LocationPickerSheet({required this.onPlaceSelected});

  @override
  State<_LocationPickerSheet> createState() => _LocationPickerSheetState();
}

class _LocationPickerSheetState extends State<_LocationPickerSheet> {
  final TextEditingController _ctrl = TextEditingController();
  List<Map<String, dynamic>> _suggestions = [];
  bool _loading = false;
  bool _fetchingDetail = false;

  Future<void> _onChanged(String input) async {
    if (input.trim().length < 2) {
      setState(() => _suggestions = []);
      return;
    }
    setState(() => _loading = true);
    try {
      final results = await PlacesApiService.autocomplete(input: input);
      setState(() => _suggestions = results);
    } catch (_) {
      setState(() => _suggestions = []);
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _onSuggestionTap(Map<String, dynamic> suggestion) async {
    final placeId   = suggestion['placeId'] as String;
    final placeName = suggestion['mainText'] as String? ?? suggestion['description'] as String? ?? '';

    setState(() => _fetchingDetail = true);
    try {
      final detail  = await PlacesApiService.getPlaceLatLng(placeId);
      final address = detail?['address'] as String? ?? suggestion['secondaryText'] as String? ?? '';
      Navigator.pop(context);
      widget.onPlaceSelected(placeName, address);
    } catch (_) {
      final address = suggestion['secondaryText'] as String? ?? '';
      Navigator.pop(context);
      widget.onPlaceSelected(placeName, address);
    } finally {
      if (mounted) setState(() => _fetchingDetail = false);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20)),
      ),
      child: Stack(children: [
        Column(children: [
          // 标题
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const Text('Select Location', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
            ]),
          ),

          // 搜索栏
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _ctrl,
              autofocus: true,
              onChanged: _onChanged,
              decoration: InputDecoration(
                hintText: 'Search for attractions, restaurants, landmarks...',
                prefixIcon: _loading
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFD35D3E))))
                    : const Icon(Icons.search, color: Color(0xFFD35D3E)),
                suffixIcon: _ctrl.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () { _ctrl.clear(); setState(() => _suggestions = []); })
                    : null,
                filled: true,
                fillColor: Colors.grey[100],
                contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: const BorderSide(color: Color(0xFFD35D3E), width: 1.5),
                ),
              ),
            ),
          ),

          const Divider(height: 1),

          // 结果列表
          Expanded(
            child: _suggestions.isEmpty
                ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.travel_explore, size: 64, color: Colors.grey[300]),
                    const SizedBox(height: 12),
                    Text(
                      _ctrl.text.isEmpty ? 'Enter a location name to start searching' : 'No relevant locations found',
                      style: TextStyle(color: Colors.grey[400], fontSize: 14),
                    ),
                  ]))
                : ListView.separated(
                    itemCount: _suggestions.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, indent: 56),
                    itemBuilder: (context, index) {
                      final s = _suggestions[index];
                      return ListTile(
                        leading: const CircleAvatar(
                          backgroundColor: Color(0xFFFFF3E0),
                          child: Icon(Icons.location_on, color: Color(0xFFD35D3E), size: 20),
                        ),
                        title: Text(
                          s['mainText'] ?? s['description'] ?? '',
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          s['secondaryText'] ?? '',
                          style: TextStyle(color: Colors.grey[500], fontSize: 12),
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => _onSuggestionTap(s),
                      );
                    },
                  ),
          ),
        ]),

        // 拉取详情时的遮罩
        if (_fetchingDetail)
          Container(
            color: Colors.black.withOpacity(0.25),
            child: const Center(child: CircularProgressIndicator(color: Color(0xFFD35D3E))),
          ),
      ]),
    );
  }
}

// =====================================================
// DottedBorderPainter (不变)
// =====================================================
class DottedBorderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    var paint = Paint()
      ..color = Colors.grey.shade400
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    double dashWidth = 4, dashSpace = 3;

    void drawDashedLine(Offset start, Offset end) {
      double distance = (end - start).distance;
      for (double i = 0; i < distance; i += dashWidth + dashSpace) {
        canvas.drawLine(
          start + (end - start) * (i / distance),
          start + (end - start) * ((i + dashWidth) / distance),
          paint,
        );
      }
    }

    drawDashedLine(const Offset(0, 0), Offset(size.width, 0));
    drawDashedLine(Offset(size.width, 0), Offset(size.width, size.height));
    drawDashedLine(Offset(size.width, size.height), Offset(0, size.height));
    drawDashedLine(Offset(0, size.height), const Offset(0, 0));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}