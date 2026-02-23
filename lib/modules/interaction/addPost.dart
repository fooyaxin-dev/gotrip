import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart'; // 直接用 FirebaseAuth
import 'dart:io';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';

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
  
  // 图片和视频
  List<File> selectedImages = [];
  final ImagePicker _picker = ImagePicker();
  
  // 文本控制器
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _contentController = TextEditingController();
  
  // 新增功能数据
  String? selectedLocation;
  List<String> selectedTags = [];
  List<String> mentionedFriends = [];
  String? selectedTopic;
  String selectedVisibility = "公开";
  
  // Firebase 实例
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance; // 直接使用 FirebaseAuth
  
  // 可选的标签列表
  final List<String> availableTags = [
    '美食', '旅行', '摄影', '日常', 'Vlog', 
    '穿搭', '健身', '美妆', '学习', '工作'
  ];
  
  // 可选的话题
  final List<String> hotTopics = [
    '#马来西亚旅行', '#KLCC打卡', '#槟城美食', 
    '#吉隆坡生活', '#周末去哪儿'
  ];

  // ===== 方案1: 保存图片到本地，只存路径到 Firestore =====
  Future<List<String>> _saveImagesToLocal(List<File> images) async {
    List<String> imagePaths = [];
    
    try {
      // 获取应用文档目录
      final directory = await getApplicationDocumentsDirectory();
      final postsDir = Directory('${directory.path}/posts');
      
      // 创建 posts 目录（如果不存在）
      if (!await postsDir.exists()) {
        await postsDir.create(recursive: true);
      }
      
      for (int i = 0; i < images.length; i++) {
        // 生成唯一文件名
        String fileName = '${DateTime.now().millisecondsSinceEpoch}_$i.jpg';
        String filePath = '${postsDir.path}/$fileName';
        
        // 复制图片到本地存储
        await images[i].copy(filePath);
        imagePaths.add(filePath);
      }
      
      return imagePaths;
    } catch (e) {
      throw Exception('保存图片失败: $e');
    }
  }

  // ===== 方案2: 将图片转为 Base64 存储到 Firestore (适合小图片) =====
  Future<List<String>> _convertImagesToBase64(List<File> images) async {
    List<String> base64Images = [];
    
    try {
      for (var image in images) {
        // 读取图片字节
        List<int> imageBytes = await image.readAsBytes();
        
        // 转换为 Base64
        String base64Image = base64Encode(imageBytes);
        base64Images.add(base64Image);
      }
      
      return base64Images;
    } catch (e) {
      throw Exception('图片转换失败: $e');
    }
  }

  // ===== 保存帖子到 Firestore (使用本地路径) =====
  Future<void> _savePostToFirestore(List<String> imagePaths) async {
    try {
      // 获取当前登录的用户
      User? currentUser = _auth.currentUser;
      
      if (currentUser == null) {
        throw Exception('用户未登录');
      }
      
      // 获取用户信息
      String userId = currentUser.uid;
      String userName = currentUser.displayName ?? 
                       currentUser.email?.split('@')[0] ?? 
                       'User_${userId.substring(0, 8)}';
      
      // 创建帖子数据
      Map<String, dynamic> postData = {
        'title': _titleController.text,
        'content': _contentController.text,
        'imagePaths': imagePaths,
        'rating': rating,
        'isAnonymous': isAnonymous,
        'allowComments': allowComments,
        'allowShare': allowShare,
        'location': selectedLocation,
        'tags': selectedTags,
        'mentionedFriends': mentionedFriends,
        'topic': selectedTopic,
        'visibility': selectedVisibility,
        'createdAt': FieldValue.serverTimestamp(),
        'userId': userId, // 真实用户 ID
        'userName': userName, // 用户名
        'userEmail': currentUser.email, // 邮箱 (可选)
        'userPhoto': currentUser.photoURL, // 头像 (可选)
        'likes': 0,
        'comments': 0,
        'shares': 0,
      };
      
      // 保存到 Firestore
      await _firestore.collection('posts').add(postData);
      
    } catch (e) {
      throw Exception('保存帖子失败: $e');
    }
  }

  // ===== 图片相关功能 =====
  Future<void> _pickImageFromGallery() async {
    try {
      final List<XFile>? images = await _picker.pickMultiImage();
      if (images != null && images.isNotEmpty) {
        setState(() {
          for (var image in images) {
            if (selectedImages.length < 9) {
              selectedImages.add(File(image.path));
            }
          }
        });
      }
    } catch (e) {
      _showErrorDialog('选择图片失败: $e');
    }
  }

  Future<void> _takePhoto() async {
    try {
      final XFile? photo = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 80,
      );
      if (photo != null) {
        setState(() {
          selectedImages.add(File(photo.path));
        });
      }
    } catch (e) {
      _showErrorDialog('拍照失败: $e');
    }
  }

  Future<void> _pickVideo() async {
    try {
      final XFile? video = await _picker.pickVideo(
        source: ImageSource.gallery,
        maxDuration: const Duration(minutes: 5),
      );
      if (video != null) {
        _showSuccessDialog('视频已选择');
      }
    } catch (e) {
      _showErrorDialog('选择视频失败: $e');
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
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(20),
              topRight: Radius.circular(20),
            ),
          ),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 20),
                const Text('选择上传方式', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 20),
                ListTile(
                  leading: const Icon(Icons.camera_alt, color: Color(0xFFD35D3E)),
                  title: const Text('拍照'),
                  onTap: () {
                    Navigator.pop(context);
                    _takePhoto();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.photo_library, color: Color(0xFFD35D3E)),
                  title: const Text('从相册选择'),
                  onTap: () {
                    Navigator.pop(context);
                    _pickImageFromGallery();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.videocam, color: Color(0xFFD35D3E)),
                  title: const Text('选择视频'),
                  onTap: () {
                    Navigator.pop(context);
                    _pickVideo();
                  },
                ),
                const SizedBox(height: 10),
                ListTile(
                  title: const Center(child: Text('取消', style: TextStyle(color: Colors.grey))),
                  onTap: () => Navigator.pop(context),
                ),
                const SizedBox(height: 10),
              ],
            ),
          ),
        );
      },
    );
  }

  void _removeImage(int index) {
    setState(() {
      selectedImages.removeAt(index);
    });
  }

  // ===== 添加地点 =====
  void _showLocationPicker() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.7,
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(20),
              topRight: Radius.circular(20),
            ),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('选择地点', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  decoration: InputDecoration(
                    hintText: '搜索地点',
                    prefixIcon: const Icon(Icons.search),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: ListView(
                  children: [
                    _buildLocationItem('📍 当前位置', 'Ipoh, Perak'),
                    _buildLocationItem('🏢 KLCC', 'Kuala Lumpur City Centre'),
                    _buildLocationItem('🏰 Batu Caves', 'Batu Caves, Selangor'),
                    _buildLocationItem('🏛️ Central Market', 'Jalan Hang Kasturi'),
                    _buildLocationItem('🌳 KLCC Park', 'Kuala Lumpur'),
                    _buildLocationItem('🎡 Sunway Lagoon', 'Petaling Jaya'),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildLocationItem(String name, String address) {
    return ListTile(
      leading: const CircleAvatar(
        backgroundColor: Color(0xFFFFF3E0),
        child: Icon(Icons.location_on, color: Color(0xFFD35D3E), size: 20),
      ),
      title: Text(name),
      subtitle: Text(address, style: const TextStyle(fontSize: 12)),
      onTap: () {
        setState(() {
          selectedLocation = name;
        });
        Navigator.pop(context);
        _showSuccessDialog('已添加地点');
      },
    );
  }

  // ===== 添加标签 =====
  void _showTagPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              height: 400,
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(20),
                  topRight: Radius.circular(20),
                ),
              ),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('添加标签', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('完成'),
                        ),
                      ],
                    ),
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
                                  if (selectedTags.length < 5) {
                                    selectedTags.add(tag);
                                  }
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
                              child: Text(
                                tag,
                                style: TextStyle(
                                  color: isSelected ? Colors.white : Colors.black,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ===== 添加话题 =====
  void _showTopicPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          height: 350,
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(20),
              topRight: Radius.circular(20),
            ),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('选择话题', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  children: hotTopics.map((topic) {
                    return ListTile(
                      leading: const Icon(Icons.tag, color: Color(0xFFD35D3E)),
                      title: Text(topic),
                      trailing: selectedTopic == topic 
                        ? const Icon(Icons.check, color: Color(0xFFD35D3E))
                        : null,
                      onTap: () {
                        setState(() {
                          selectedTopic = topic;
                        });
                        Navigator.pop(context);
                        _showSuccessDialog('已添加话题');
                      },
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ===== @好友 =====
  void _showMentionFriends() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.7,
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(20),
              topRight: Radius.circular(20),
            ),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('@ 好友', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  decoration: InputDecoration(
                    hintText: '搜索好友',
                    prefixIcon: const Icon(Icons.search),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: ListView(
                  children: [
                    _buildFriendItem('小明', '@xiaoming'),
                    _buildFriendItem('小红', '@xiaohong'),
                    _buildFriendItem('Traveler01', '@traveler01'),
                    _buildFriendItem('GoTrip User', '@gotripuser'),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

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
            if (value == true) {
              mentionedFriends.add(username);
            } else {
              mentionedFriends.remove(username);
            }
          });
        },
      ),
    );
  }

  // ===== 可见范围设置 =====
  void _showVisibilitySettings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(20),
              topRight: Radius.circular(20),
            ),
          ),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 20),
                const Text('谁可以看', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 20),
                _buildVisibilityOption('公开', '所有人可见', Icons.public),
                _buildVisibilityOption('仅好友', '只有好友可见', Icons.people),
                _buildVisibilityOption('私密', '仅自己可见', Icons.lock),
                const SizedBox(height: 20),
              ],
            ),
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
        setState(() {
          selectedVisibility = title;
        });
        Navigator.pop(context);
      },
    );
  }

  // ===== 发布功能 =====
  Future<void> _publishPost() async {
    if (_titleController.text.isEmpty || _contentController.text.isEmpty) {
      _showErrorDialog('请填写标题和内容');
      return;
    }
    
    if (selectedImages.isEmpty) {
      _showErrorDialog('请至少上传一张图片');
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: CircularProgressIndicator(color: Color(0xFFD35D3E)),
      ),
    );

    setState(() {
      isUploading = true;
    });

    try {
      // 保存图片到本地 (选择其中一种方案)
      List<String> imagePaths = await _saveImagesToLocal(selectedImages);
      
      // 如果要用 Base64，取消上面的注释，用下面这行
      // List<String> imagePaths = await _convertImagesToBase64(selectedImages);
      
      // 保存到 Firestore
      await _savePostToFirestore(imagePaths);
      
      Navigator.pop(context);
      _showSuccessDialog('发布成功!');
      
      await Future.delayed(const Duration(seconds: 1));
      Navigator.pop(context);
      
    } catch (e) {
      Navigator.pop(context);
      _showErrorDialog('发布失败: $e');
    } finally {
      setState(() {
        isUploading = false;
      });
    }
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('提示'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _showSuccessDialog(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leadingWidth: 70,
        leading: TextButton(
          onPressed: isUploading ? null : () => Navigator.pop(context),
          child: Text(
            "取消", 
            style: TextStyle(
              color: isUploading ? Colors.grey : Colors.black54, 
              fontSize: 16
            ),
          ),
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("发笔记", style: TextStyle(color: Colors.black, fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(width: 4),
            Icon(Icons.help_outline, size: 16, color: Colors.grey[600]),
          ],
        ),
        centerTitle: true,
        actions: [
          Center(
            child: GestureDetector(
              onTap: isUploading ? null : () => _showSuccessDialog('草稿已保存'),
              child: Text(
                "保存", 
                style: TextStyle(
                  color: isUploading ? Colors.grey : Colors.grey[700], 
                  fontSize: 15
                ),
              ),
            ),
          ),
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
                child: const Text("发布", style: TextStyle(color: Colors.white, fontSize: 14)),
              ),
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 20),
                
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    ...selectedImages.asMap().entries.map((entry) {
                      int index = entry.key;
                      File image = entry.value;
                      return Stack(
                        children: [
                          Container(
                            width: 100,
                            height: 100,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              image: DecorationImage(
                                image: FileImage(image),
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                          Positioned(
                            top: 2,
                            right: 2,
                            child: GestureDetector(
                              onTap: () => _removeImage(index),
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.6),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.close, color: Colors.white, size: 16),
                              ),
                            ),
                          ),
                        ],
                      );
                    }),
                    
                    if (selectedImages.length < 9)
                      GestureDetector(
                        onTap: _showImageSourceDialog,
                        child: CustomPaint(
                          painter: DottedBorderPainter(),
                          child: Container(
                            width: 100,
                            height: 100,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.camera_alt_outlined, color: Colors.grey[700], size: 30),
                                const SizedBox(height: 4),
                                Text("上传视频/照片", style: TextStyle(color: Colors.grey[500], fontSize: 10)),
                              ],
                            ),
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
                    hintText: "填写标题更容易上首页哦~",
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
                    hintText: "今天也是元气满满的一天，我要赶紧用笔记记录下来",
                    hintStyle: TextStyle(color: Colors.grey, fontSize: 14),
                    border: InputBorder.none,
                  ),
                ),
                
                const SizedBox(height: 20),

                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.grey[50],
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      _buildFeatureButton(
                        icon: Icons.location_on_outlined,
                        label: selectedLocation ?? '添加地点',
                        onTap: _showLocationPicker,
                        hasValue: selectedLocation != null,
                      ),
                      const Divider(height: 20),
                      
                      _buildFeatureButton(
                        icon: Icons.tag,
                        label: selectedTopic ?? '添加话题',
                        onTap: _showTopicPicker,
                        hasValue: selectedTopic != null,
                      ),
                      const Divider(height: 20),
                      
                      _buildFeatureButton(
                        icon: Icons.sell_outlined,
                        label: selectedTags.isEmpty 
                          ? '添加标签' 
                          : selectedTags.join(', '),
                        onTap: _showTagPicker,
                        hasValue: selectedTags.isNotEmpty,
                      ),
                      const Divider(height: 20),
                      
                      _buildFeatureButton(
                        icon: Icons.alternate_email,
                        label: mentionedFriends.isEmpty 
                          ? '@ 好友' 
                          : '已选择 ${mentionedFriends.length} 位好友',
                        onTap: _showMentionFriends,
                        hasValue: mentionedFriends.isNotEmpty,
                      ),
                      const Divider(height: 20),
                      
                      _buildFeatureButton(
                        icon: Icons.visibility_outlined,
                        label: '可见范围: $selectedVisibility',
                        onTap: _showVisibilitySettings,
                        hasValue: true,
                      ),
                    ],
                  ),
                ),
                
                const SizedBox(height: 30),

                Row(
                  children: [
                    const Text("描述相符", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(width: 15),
                    ...List.generate(5, (index) => GestureDetector(
                      onTap: isUploading ? null : () => setState(() => rating = index + 1),
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Icon(
                          Icons.star_rounded,
                          size: 32,
                          color: index < rating ? Colors.orange : Colors.grey[300],
                        ),
                      ),
                    )),
                  ],
                ),
                
                const SizedBox(height: 25),

                _buildSwitchOption(
                  '匿名',
                  '匿名会隐藏头像和昵称',
                  isAnonymous,
                  (value) => setState(() => isAnonymous = value),
                ),
                const SizedBox(height: 15),
                _buildSwitchOption(
                  '允许评论',
                  '其他用户可以在你的帖子下评论',
                  allowComments,
                  (value) => setState(() => allowComments = value),
                ),
                const SizedBox(height: 15),
                _buildSwitchOption(
                  '允许转发',
                  '其他用户可以转发你的帖子',
                  allowShare,
                  (value) => setState(() => allowShare = value),
                ),

                const SizedBox(height: 150),
              ],
            ),
          ),

          if (!isUploading)
            Positioned(
              right: 20,
              bottom: 30,
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
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFD35D3E).withOpacity(0.3),
                          blurRadius: 15,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.send_rounded, color: Colors.white, size: 20),
                        SizedBox(width: 10),
                        Text("发布", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFeatureButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required bool hasValue,
  }) {
    return InkWell(
      onTap: isUploading ? null : onTap,
      child: Row(
        children: [
          Icon(icon, color: hasValue ? const Color(0xFFD35D3E) : Colors.grey[600], size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 15,
                color: hasValue ? Colors.black : Colors.grey[600],
                fontWeight: hasValue ? FontWeight.w500 : FontWeight.normal,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Icon(Icons.chevron_right, color: Colors.grey[400]),
        ],
      ),
    );
  }

  Widget _buildSwitchOption(String title, String subtitle, bool value, Function(bool) onChanged) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text(subtitle, style: TextStyle(color: Colors.grey[500], fontSize: 12)),
            ],
          ),
        ),
        Switch(
          value: value,
          activeColor: const Color(0xFFD35D3E),
          onChanged: isUploading ? null : onChanged,
        ),
      ],
    );
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }
}

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