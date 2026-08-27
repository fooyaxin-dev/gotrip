import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_cropper/image_cropper.dart';
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import '../../services/post_service.dart';
import '../../services/placesAPI_service.dart';
import '../../services/userPreference_service.dart';
import '../../services/algolia_service.dart';
import '../../services/sentiment_service.dart';
import '../../services/achievement_service.dart';
import '../../services/apps_Loading.dart';
import '../../services/storage_service.dart';
import '../../services/connectivity_service.dart';


class MediaItem {
  final File file;
  final bool isVideo;
  const MediaItem({required this.file, required this.isVideo});
}

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

  List<MediaItem> selectedMedia = [];
  final int _maxMedia = 9;
  final ImagePicker _picker = ImagePicker();

  final TextEditingController _titleController   = TextEditingController();
  final TextEditingController _contentController = TextEditingController();
  final FocusNode _titleFocus   = FocusNode();
  final FocusNode _contentFocus = FocusNode();



  // ── Location ──
  String? selectedCity;
  String? selectedLocation;
  String? selectedPlaceId;              // Google Place ID（没选地点时为 null）
  List<String> selectedPlaceTypes = []; // 该地点的 Google types
  double? selectedLat;   // 🆕
  double? selectedLng; 

  List<String> selectedTags = [];
  List<String> mentionedFriends = [];
  String selectedVisibility = "public";

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;


  // ── Top badge for current user ──
  AchievementTier? _topBadge;

  // ── Tag ──
  final TextEditingController _tagController = TextEditingController();
  final FocusNode _tagFocus = FocusNode();
  bool _showTagSuggestions = false;
  List<String> _filteredTagSuggestions = [];
  Timer? _tagDebounce;
  List<String> _popularTags = [];

  static const List<String> _defaultSuggestedTags = [
    'food', 'travel', 'photography', 'fitness',
    'nature', 'shopping', 'daily', 'vlog', 'fashion', 'beauty',
  ];


  Future<void> _loadTopBadge() async {
    final tier = await AchievementService.instance.fetchTopBadge();
    if (mounted) setState(() => _topBadge = tier);
  }

  @override
  void initState() {
    super.initState();
    _loadPopularTags();
    _loadTopBadge();
    _tagFocus.addListener(() {
      if (_tagFocus.hasFocus) {
        _updateTagSuggestions(_tagController.text);
        setState(() => _showTagSuggestions = true);
      } else {
        Future.delayed(const Duration(milliseconds: 150), () {
          if (mounted) setState(() => _showTagSuggestions = false);
        });
      }
    });
  }

  Future<void> _loadPopularTags() async {
    try {
      final snapshot = await _firestore
          .collection('tags')
          .orderBy('count', descending: true)
          .limit(50)
          .get();
      final tags = snapshot.docs.map((doc) => doc.id).toList();
      if (mounted) setState(() => _popularTags = tags);
    } catch (e) {
      print('Load popular tags failed: $e');
    }
  }

  void _updateTagSuggestions(String query) {
    final q = query.trim().toLowerCase();
    final allTags = <String>{..._popularTags, ..._defaultSuggestedTags}.toList();
    final available = allTags.where((t) => !selectedTags.contains(t)).toList();

    if (q.isEmpty) {
      setState(() => _filteredTagSuggestions = available.take(10).toList());
    } else {
      final matched = available.where((t) => t.toLowerCase().contains(q)).toList();
      final userTag = q.replaceAll('#', '').replaceAll(' ', '');
      final suggestions = <String>[];
      if (userTag.isNotEmpty && !selectedTags.contains(userTag)) {
        suggestions.add(userTag);
      }
      for (final t in matched) {
        if (t != userTag && suggestions.length < 8) suggestions.add(t);
      }
      setState(() => _filteredTagSuggestions = suggestions);
    }
  }

  void _onTagChanged(String query) {
    _tagDebounce?.cancel();
    _tagDebounce = Timer(const Duration(milliseconds: 200), () => _updateTagSuggestions(query));
  }

  void _selectTag(String tag) {
    final cleaned = tag.replaceAll('#', '').trim().toLowerCase();
    if (cleaned.isEmpty || selectedTags.contains(cleaned)) return;
    if (selectedTags.length >= 10) { _showErrorDialog('Maximum 10 tags allowed'); return; }
    setState(() {
      selectedTags.add(cleaned);
      _tagController.clear();
      _filteredTagSuggestions = [];
    });
    _updateTagSuggestions('');
  }

  void _removeTag(String tag) {
    setState(() => selectedTags.remove(tag));
    _updateTagSuggestions(_tagController.text);
  }

  void _dismissKeyboard() {
    _titleFocus.unfocus();
    _contentFocus.unfocus();
    _tagFocus.unfocus();
  }

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

  Future<Map<String, List<String>>> _uploadMediaToCloud(
    List<MediaItem> media,
  ) async {
    if (media.isEmpty) {
      return {'imagePaths': [], 'videoPaths': []};
    }
    final items = media
        .map((m) => (file: m.file, isVideo: m.isVideo))
        .toList();

    final result = await StorageService.uploadPostMediaBatch(items);

    if (result.imageUrls.isEmpty &&
        result.videoUrls.isEmpty &&
        media.isNotEmpty) {
      // 全部上传失败 —— 明确告诉用户，而不是静默发一个没有媒体的帖子
      throw Exception('Failed to upload media. Please check your connection and try again.');
    }

    return {
      'imagePaths': result.imageUrls,
      'videoPaths': result.videoUrls,
    };
  }
  
  /// 保存帖子到 Firestore，返回新建文档的 ID
  /// （用于发布后触发后台 sentiment 分析）
  Future<String> _savePostToFirestore({
    required List<String> imagePaths,
    required List<String> videoPaths,
  }) async {
    try {
      User? currentUser = _auth.currentUser;
      if (currentUser == null) throw Exception('User not logged in');

      String userId = currentUser.uid;
      DocumentSnapshot userDoc =
          await _firestore.collection('users').doc(userId).get();

      String userName = 'Unknown User';
      String? userPhoto;

      if (userDoc.exists) {
        Map<String, dynamic> userData =
            userDoc.data() as Map<String, dynamic>;
        userName = userData['username'] ??
            currentUser.displayName ??
            currentUser.email?.split('@')[0] ??
            'User_${userId.substring(0, 8)}';
        userPhoto = userData['profileImageUrl'];
      }

      final String postType =
          (imagePaths.isEmpty && videoPaths.isEmpty) ? 'text' : 'media';

      Map<String, dynamic> postData = {
        'title': _titleController.text.trim(),
        'content': _contentController.text.trim(),
        'imagePaths': imagePaths,
        'videoPaths': videoPaths,
        'postType': postType,
        'locationLat': selectedLat,   // 🆕
        'locationLng': selectedLng, 
        'rating': rating,
        'isAnonymous': isAnonymous,
        'allowComments': allowComments,
        'allowShare': allowShare,
        'city': selectedCity,
        'location': selectedLocation,
        'placeId': selectedPlaceId,
        'placeTypes': selectedPlaceTypes,
        'tags': selectedTags,
        'mentionedFriends': mentionedFriends,
        'visibility': selectedVisibility,
        'createdAt': FieldValue.serverTimestamp(),
        'userId': userId,
        'userName': userName,
        'userPhoto': userPhoto,
        'userEmail': isAnonymous ? null : currentUser.email,
        'likes': 0,
        'comments': 0,
        'shares': 0,
        // sentiment 字段暂时不写 —— 发布瞬间还没分析，
        // 分析完成后用 .update() 单独补上
      };

      final docRef = _firestore.collection('posts').doc();

final batch = _firestore.batch();

batch.set(docRef, postData);

batch.update(
  _firestore.collection('users').doc(userId),
  {
    'postCount': FieldValue.increment(1),
  },
);

await batch.commit();

// Algolia 保持原本逻辑，不动
if (selectedVisibility == 'public') {
  await AlgoliaService.syncPost(docRef.id, postData);
}

return docRef.id;
    } catch (e) {
      throw Exception('Save post failed: $e');
    }
  }

  /// Fire-and-forget：不阻塞用户发帖流程，在背景跑 sentiment 分析，
  /// 完成后直接 .update() 该 post document。Firestore 的 StreamBuilder
  /// （InteractionPage / postWidget）会自动因为这次 update 而刷新。
  ///
  /// 如果这篇帖子挂了真实地点（placeTypes 非空），分析完成后还会调用
  /// UserPreferenceService.updateFromPost() 反哺推荐算法 —— 只有
  /// sentiment 为 positive 时才会真正被学习进偏好（取代旧的用 likes
  /// 判断的逻辑，因为 likes 高不代表体验正面）。
  void _runSentimentAnalysisInBackground(
    String postId,
    String content, {
    required List<String> placeTypes,
    required int postRating,
    required List<String> postTags,    // 🆕
    String? postTopic,                  // 🆕
  }) {
    if (content.trim().isEmpty) return;

    LexiconSentimentAnalyzer.instance.analyze(content).then((result) async {
      try {
        await _firestore.collection('posts').doc(postId).update({
          'sentimentScore': result.score,
          'sentimentLabel': result.label.toJson(),
          'sentimentMatchedTokens': result.matchedTokenCount,
          'sentimentAnalyzedAt': FieldValue.serverTimestamp(),
        });
        debugPrint('🧠 Sentiment analyzed for $postId: $result');

        if (placeTypes.isNotEmpty || postTags.isNotEmpty || postTopic != null) {
          await UserPreferenceService.instance.updateFromPost(
            placeTypes: placeTypes,
            postTags:   postTags,      // 🆕
            postTopic:  postTopic,     // 🆕
            sentimentLabel: result.label,
            sentimentMatchedTokens: result.matchedTokenCount,
            postRating: postRating,
          );
        }
      } catch (e) {
        debugPrint('⚠️ Sentiment update failed for $postId: $e');
      }
    });
  }
  
  Future<void> _pickImagesFromGallery() async {
    try {
      if (_maxMedia - selectedMedia.length <= 0) {
        _showErrorDialog('Maximum $_maxMedia media items reached');
        return;
      }
      final List<XFile>? images = await _picker.pickMultiImage(imageQuality: 85);
      if (images == null || images.isEmpty) return;

      for (var img in images) {
        if (selectedMedia.length >= _maxMedia) break;
        final cropped = await _cropToSquare(File(img.path));
        if (cropped == null) continue;
        setState(() => selectedMedia.add(MediaItem(file: cropped, isVideo: false)));
      }
    } catch (e) {
      _showErrorDialog('Select images failed: $e');
    }
  }

  Future<void> _takePhoto() async {
    try {
      final XFile? photo = await _picker.pickImage(source: ImageSource.camera, imageQuality: 80);
      if (photo == null || selectedMedia.length >= _maxMedia) return;

      final cropped = await _cropToSquare(File(photo.path));
      if (cropped == null) return;
      setState(() => selectedMedia.add(MediaItem(file: cropped, isVideo: false)));
    } catch (e) {
      _showErrorDialog('Take photo failed: $e');
    }
  }

  Future<void> _pickVideo() async {
    try {
      if (selectedMedia.length >= _maxMedia) { _showErrorDialog('Maximum $_maxMedia media items reached'); return; }
      final XFile? video = await _picker.pickVideo(source: ImageSource.gallery, maxDuration: const Duration(minutes: 5));
      if (video != null) { setState(() => selectedMedia.add(MediaItem(file: File(video.path), isVideo: true))); _showSuccessSnack('Video added'); }
    } catch (e) { _showErrorDialog('Select video failed: $e'); }
  }

  Future<void> _recordVideo() async {
    try {
      if (selectedMedia.length >= _maxMedia) { _showErrorDialog('Maximum $_maxMedia media items reached'); return; }
      final XFile? video = await _picker.pickVideo(source: ImageSource.camera, maxDuration: const Duration(minutes: 5));
      if (video != null) { setState(() => selectedMedia.add(MediaItem(file: File(video.path), isVideo: true))); _showSuccessSnack('Video recorded'); }
    } catch (e) { _showErrorDialog('Record video failed: $e'); }
  }

  
  Future<File?> _cropToSquare(File imageFile) async {
    final cropped = await ImageCropper().cropImage(
      sourcePath: imageFile.path,
      aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
      compressQuality: 85,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Crop Photo',
          toolbarColor: const Color(0xFF7C4DFF),
          toolbarWidgetColor: Colors.white,
          activeControlsWidgetColor: const Color(0xFF7C4DFF),
          lockAspectRatio: true,
        ),
        IOSUiSettings(
          title: 'Crop Photo',
          aspectRatioLockEnabled: true,
          resetAspectRatioEnabled: false,
          aspectRatioPickerButtonHidden: true,
        ),
      ],
    );
    return cropped != null ? File(cropped.path) : null;
  }

  void _removeMedia(int index) => setState(() => selectedMedia.removeAt(index));

  void _showMediaSourceDialog() {
    _dismissKeyboard();
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
              const Text('Add Media', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text('${selectedMedia.length}/$_maxMedia items', style: TextStyle(color: Colors.grey[500], fontSize: 13)),
              const SizedBox(height: 12),
              ListTile(leading: const Icon(Icons.camera_alt, color: Color(0xFF7C4DFF)), title: const Text('Take Photo'), onTap: () { Navigator.pop(context); _takePhoto(); }),
              ListTile(leading: const Icon(Icons.photo_library, color: Color(0xFF7C4DFF)), title: const Text('Choose Photos from Gallery'), onTap: () { Navigator.pop(context); _pickImagesFromGallery(); }),
              ListTile(leading: const Icon(Icons.videocam, color: Color(0xFF7C4DFF)), title: const Text('Record Video'), onTap: () { Navigator.pop(context); _recordVideo(); }),
              ListTile(leading: const Icon(Icons.video_library, color: Color(0xFF7C4DFF)), title: const Text('Choose Video from Gallery'), onTap: () { Navigator.pop(context); _pickVideo(); }),
              const SizedBox(height: 10),
              ListTile(title: const Center(child: Text('Cancel', style: TextStyle(color: Colors.grey))), onTap: () => Navigator.pop(context)),
              const SizedBox(height: 10),
            ]),
          ),
        );
      },
    );
  }

  // ── Location picker ──
  void _showLocationPicker() {
    _dismissKeyboard();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _LocationPickerSheet(
        onPlaceSelected: (String placeName, String address, String? placeId,
            List<String> types, double? lat, double? lng) {
          final city = _extractCityFromAddress(address);
          setState(() {
            selectedLocation = placeName;
            selectedCity = city;
            selectedPlaceId = placeId;
            selectedPlaceTypes = types;
            selectedLat = lat;   // 🆕
            selectedLng = lng;   // 🆕
          });
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Location: $placeName${city.isNotEmpty ? ' · $city' : ''}'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 1),
          ));
        },
      ),
    );
}

 

  Widget _buildBadgePill(AchievementTier tier) {
    const tierColors = {
      'bronze': Color(0xFFCD7F32),
      'silver': Color(0xFFA8A9AD),
      'gold':   Color(0xFFFFD700),
    };
    final color = tierColors[tier.level] ?? const Color(0xFF7C4DFF);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.4), width: 1),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(tier.emoji, style: const TextStyle(fontSize: 11)),
        const SizedBox(width: 3),
        Text(tier.label,
            style: TextStyle(
                fontSize: 9, fontWeight: FontWeight.bold, color: color)),
      ]),
    );
  }


  Future<void> _publishPost() async {
    _dismissKeyboard();

    if (_contentController.text.trim().isEmpty) {
      _showErrorDialog('Please write something to share');
      return;
    }

    // 🆕 发帖前先确认有网，没网直接提示，不让用户卡在转圈
    final online = await ConnectivityService.instance.ensureConnected(
      context,
      onRetry: _publishPost,
    );
    if (!online) return;


    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: TravelLoadingIndicator()),
    );
    setState(() => isUploading = true);

    try {
      Map<String, List<String>> savedPaths = {'imagePaths': [], 'videoPaths': []};

      if (selectedMedia.isNotEmpty) {
        savedPaths = await _uploadMediaToCloud(selectedMedia);
      }

      final newPostId = await _savePostToFirestore(
        imagePaths: savedPaths['imagePaths']!,
        videoPaths: savedPaths['videoPaths']!,
      );

      // 触发后台 sentiment 分析 —— 不 await，不拖慢发布反馈
      // 触发后台 sentiment 分析 —— 不 await，不拖慢发布反馈
     _runSentimentAnalysisInBackground(
        newPostId,
        _contentController.text.trim(),
        placeTypes: selectedPlaceTypes,
        postRating: rating,
        postTags:   selectedTags,   // 🆕
        postTopic:  null,           // 🆕 这个发帖页面目前没有 topic 选择器，先传 null
      );

      Navigator.pop(context);
      _showSuccessSnack('Post published successfully!');
      await Future.delayed(const Duration(milliseconds: 800));
      if (mounted) Navigator.pop(context, true); 
      
    } catch (e) {
      Navigator.pop(context);
      _showErrorDialog('Failed to publish post: $e');
    } finally {
      if (mounted) setState(() => isUploading = false);
    }
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Error'), content: Text(message),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
  }

  void _showSuccessSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(message), backgroundColor: Colors.green, duration: const Duration(seconds: 1)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white, elevation: 0, leadingWidth: 80,
        leading: TextButton(
          onPressed: isUploading ? null : () => Navigator.pop(context),
          child: Text('Cancel', style: TextStyle(color: isUploading ? Colors.grey : Colors.black54, fontSize: 16)),
        ),
        title: const Text('Post', style: TextStyle(color: Colors.black, fontSize: 17, fontWeight: FontWeight.bold)),
        centerTitle: true,
        actions: [
          Center(
            child: GestureDetector(
              onTap: isUploading ? null : _publishPost,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                decoration: BoxDecoration(
                  color: isUploading ? Colors.grey : const Color(0xFF7C4DFF),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text('Post', style: TextStyle(color: Colors.white, fontSize: 14)),
              ),
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: GestureDetector(
        onTap: _dismissKeyboard,
        behavior: HitTestBehavior.opaque,
        child: Stack(children: [
          SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const SizedBox(height: 12),
              // ── Author info row (Weibo-style badge) ──
              FutureBuilder<DocumentSnapshot>(
                future: _firestore.collection('users').doc(_auth.currentUser?.uid).get(),
                builder: (_, snap) {
                  String userName = 'Me';
                  String? photoUrl;
                  if (snap.hasData && snap.data!.exists) {
                    final d = snap.data!.data() as Map<String, dynamic>;
                    userName = d['username'] as String? ?? 'Me';
                    photoUrl = d['profileImageUrl'] as String?;
                  }
                  return Row(children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: const Color(0xFF7C4DFF).withOpacity(0.2),
                      backgroundImage: photoUrl != null && photoUrl.isNotEmpty
                          ? (photoUrl.startsWith('data:image')
                              ? MemoryImage(base64Decode(photoUrl.split(',')[1])) as ImageProvider
                              : NetworkImage(photoUrl))
                          : null,
                      child: (photoUrl == null || photoUrl.isEmpty)
                          ? Text(userName.isNotEmpty ? userName[0].toUpperCase() : '?',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))
                          : null,
                    ),
                    const SizedBox(width: 10),
                    Text(isAnonymous ? 'Anonymous' : userName,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    if (!isAnonymous && _topBadge != null) ...[
                      const SizedBox(width: 6),
                      _buildBadgePill(_topBadge!),
                    ],
                  ]);
                },
              ),
              const SizedBox(height: 16),
              _buildMediaGrid(),
              const SizedBox(height: 30),
              TextField(
                controller: _titleController, focusNode: _titleFocus, enabled: !isUploading,
                decoration: const InputDecoration(hintText: 'Add a title (optional)~', hintStyle: TextStyle(color: Colors.grey, fontSize: 16), border: InputBorder.none),
              ),
              Divider(color: Colors.grey[200], thickness: 1),
              TextField(
                controller: _contentController, focusNode: _contentFocus, enabled: !isUploading, maxLines: 8,
                decoration: const InputDecoration(
                  hintText: "What's on your mind? Share your travel experience, tips, or stories!",
                  hintStyle: TextStyle(color: Colors.grey, fontSize: 14), border: InputBorder.none,
                ),
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: Colors.grey[50], borderRadius: BorderRadius.circular(12)),
                child: Column(children: [
                  _buildFeatureButton(
                    icon: Icons.location_on_outlined,
                    label: selectedLocation != null
                        ? '$selectedLocation${selectedCity != null && selectedCity!.isNotEmpty ? ' · $selectedCity' : ''}'
                        : 'Add Location',
                    onTap: _showLocationPicker,
                    hasValue: selectedLocation != null,
                  ),
                  const Divider(height: 20),
      
                 
                ]),
              ),
              const SizedBox(height: 24),
              _buildTagSection(),
              const SizedBox(height: 30),
              Row(children: [
                const Text('Rating', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(width: 15),
                ...List.generate(5, (index) => GestureDetector(
                  onTap: isUploading ? null : () { _dismissKeyboard(); setState(() => rating = index + 1); },
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Icon(Icons.star_rounded, size: 32, color: index < rating ? Colors.orange : Colors.grey[300]),
                  ),
                )),
              ]),
              const SizedBox(height: 25),
              _buildSwitchOption('Anonymous', 'Anonymous will hide your avatar and nickname', isAnonymous,
                  (v) { _dismissKeyboard(); setState(() => isAnonymous = v); }),
              const SizedBox(height: 150),
            ]),
          ),
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
                      color: const Color(0xFF7C4DFF).withOpacity(0.9),
                      borderRadius: BorderRadius.circular(40),
                      boxShadow: [BoxShadow(color: const Color(0xFF7C4DFF).withOpacity(0.3), blurRadius: 15, offset: const Offset(0, 5))],
                    ),
                    child: const Row(children: [
                      Icon(Icons.send_rounded, color: Colors.white, size: 20),
                      SizedBox(width: 10),
                      Text('Post', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                    ]),
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _buildTagSection() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(Icons.sell_outlined, size: 18, color: Color(0xFF7C4DFF)),
        const SizedBox(width: 8),
        const Text('Tags', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        const SizedBox(width: 8),
        Text('${selectedTags.length}/10', style: TextStyle(fontSize: 12, color: Colors.grey[500])),
      ]),
      const SizedBox(height: 10),
      if (selectedTags.isNotEmpty) ...[
        Wrap(
          spacing: 8, runSpacing: 8,
          children: selectedTags.map((tag) => Chip(
            label: Text('#$tag', style: const TextStyle(color: Colors.white, fontSize: 12)),
            backgroundColor: const Color(0xFF7C4DFF),
            deleteIconColor: Colors.white70,
            onDeleted: () => _removeTag(tag),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsets.symmetric(horizontal: 4),
          )).toList(),
        ),
        const SizedBox(height: 10),
      ],
      if (selectedTags.length < 10)
        TextField(
          controller: _tagController, focusNode: _tagFocus, enabled: !isUploading,
          onChanged: _onTagChanged,
          onSubmitted: (value) { if (value.trim().isNotEmpty) _selectTag(value.trim()); },
          decoration: InputDecoration(
            hintText: 'Type a tag and press Enter...',
            hintStyle: TextStyle(color: Colors.grey[400], fontSize: 13),
            prefixIcon: const Icon(Icons.tag, color: Color(0xFF7C4DFF), size: 18),
            filled: true, fillColor: Colors.grey[100],
            contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: const BorderSide(color: Color(0xFF7C4DFF), width: 1.5)),
          ),
        ),
      if (_showTagSuggestions && _filteredTagSuggestions.isNotEmpty)
        Container(
          margin: const EdgeInsets.only(top: 6),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 12, offset: const Offset(0, 4))],
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (_tagController.text.trim().isNotEmpty) ...[
              _buildTagSuggestionTile(tag: _filteredTagSuggestions.first, isUserInput: true),
              if (_filteredTagSuggestions.length > 1) const Divider(height: 1, indent: 16),
            ],
            if (_filteredTagSuggestions.length > 1 || _tagController.text.trim().isEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text('POPULAR TAGS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey[500], letterSpacing: 0.8)),
              ),
              ...(_tagController.text.trim().isEmpty ? _filteredTagSuggestions : _filteredTagSuggestions.skip(1).toList())
                  .map((tag) => _buildTagSuggestionTile(tag: tag, isUserInput: false)),
            ],
            const SizedBox(height: 6),
          ]),
        ),
    ]);
  }

  Widget _buildTagSuggestionTile({required String tag, required bool isUserInput}) {
    return InkWell(
      onTap: () => _selectTag(tag),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(children: [
          Icon(isUserInput ? Icons.add_circle_outline : Icons.local_offer_outlined,
              size: 16, color: isUserInput ? const Color(0xFF7C4DFF) : Colors.grey[500]),
          const SizedBox(width: 10),
          Text('#$tag', style: TextStyle(fontSize: 14, fontWeight: isUserInput ? FontWeight.w600 : FontWeight.normal,
              color: isUserInput ? const Color(0xFF7C4DFF) : Colors.black87)),
          if (isUserInput) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: const Color(0xFF7C4DFF).withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
              child: const Text('Add', style: TextStyle(fontSize: 10, color: Color(0xFF7C4DFF))),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _buildMediaGrid() {
    return Wrap(
      spacing: 10, runSpacing: 10,
      children: [
        ...selectedMedia.asMap().entries.map((entry) {
          final index = entry.key;
          final item  = entry.value;
          return Stack(children: [
            Container(
              width: 100, height: 100,
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), color: Colors.grey[200]),
              child: item.isVideo
                  ? ClipRRect(borderRadius: BorderRadius.circular(8), child: Container(color: Colors.grey[800], child: const Icon(Icons.play_circle_fill, color: Colors.white70, size: 40)))
                  : ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.file(item.file, fit: BoxFit.cover, width: 100, height: 100)),
            ),
            Positioned(top: 2, right: 2,
              child: GestureDetector(
                onTap: () => _removeMedia(index),
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), shape: BoxShape.circle),
                  child: const Icon(Icons.close, color: Colors.white, size: 16),
                ),
              ),
            ),
            if (item.isVideo)
              Positioned(bottom: 6, left: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), borderRadius: BorderRadius.circular(4)),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.videocam, color: Colors.white, size: 12),
                    SizedBox(width: 3),
                    Text('VIDEO', style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                  ]),
                ),
              ),
          ]);
        }),
        if (selectedMedia.length < _maxMedia)
          GestureDetector(
            onTap: _showMediaSourceDialog,
            child: CustomPaint(
              painter: DottedBorderPainter(),
              child: SizedBox(
                width: 100, height: 100,
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.add_photo_alternate_outlined, color: Colors.grey[700], size: 30),
                  const SizedBox(height: 4),
                  Text(selectedMedia.isEmpty ? 'Add Photo/Video' : '${selectedMedia.length}/$_maxMedia',
                      style: TextStyle(color: Colors.grey[500], fontSize: 10), textAlign: TextAlign.center),
                ]),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildFeatureButton({required IconData icon, required String label, required VoidCallback onTap, required bool hasValue}) {
    return InkWell(
      onTap: isUploading ? null : onTap,
      child: Row(children: [
        Icon(icon, color: hasValue ? const Color(0xFF7C4DFF) : Colors.grey[600], size: 22),
        const SizedBox(width: 12),
        Expanded(child: Text(label, style: TextStyle(fontSize: 15, color: hasValue ? Colors.black : Colors.grey[600], fontWeight: hasValue ? FontWeight.w500 : FontWeight.normal), maxLines: 1, overflow: TextOverflow.ellipsis)),
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
      Switch(value: value, activeColor: const Color(0xFF7C4DFF), onChanged: isUploading ? null : onChanged),
    ]);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    _tagController.dispose();
    _titleFocus.dispose();
    _contentFocus.dispose();
    _tagFocus.dispose();
    _tagDebounce?.cancel();
    super.dispose();
  }
}

// =====================================================
// Location Picker Sheet — placeId + types 版本
// =====================================================
class _LocationPickerSheet extends StatefulWidget {
  final void Function(
    String placeName,
    String address,
    String? placeId,
    List<String> types,
    double? lat,
    double? lng,
  ) onPlaceSelected;
  const _LocationPickerSheet({required this.onPlaceSelected});

  @override
  State<_LocationPickerSheet> createState() => _LocationPickerSheetState();
}

class _LocationPickerSheetState extends State<_LocationPickerSheet> {
  final TextEditingController _ctrl = TextEditingController();
  List<Map<String, dynamic>> _suggestions = [];
  bool _loading = false;
  bool _fetchingDetail = false;

  int _autocompleteRequestId = 0;

  Future<void> _onChanged(
  String input,
) async {
  final query = input.trim();

  // Every input change invalidates any older
  // autocomplete request.
  final requestId =
      ++_autocompleteRequestId;

  if (query.length < 2) {
    if (!mounted) return;

    setState(() {
      _suggestions = [];
      _loading = false;
    });

    return;
  }

  if (!mounted) return;

  setState(() {
    _loading = true;
  });

  try {
    final results =
        await PlacesApiService.autocomplete(
      input: query,
    );

    // Ignore results belonging to an older query,
    // or a sheet that has already been closed.
    if (!mounted ||
        requestId !=
            _autocompleteRequestId ||
        _ctrl.text.trim() != query) {
      return;
    }

    setState(() {
      _suggestions = results;
    });
  } catch (e) {
    if (!mounted ||
        requestId !=
            _autocompleteRequestId) {
      return;
    }

    debugPrint(
      '⚠️ Location autocomplete failed: $e',
    );

    setState(() {
      _suggestions = [];
    });
  } finally {
    // An old request must not turn off the loading
    // indicator of a newer request.
    if (mounted &&
        requestId ==
            _autocompleteRequestId) {
      setState(() {
        _loading = false;
      });
    }
  }
}

  Future<void> _onSuggestionTap(Map<String, dynamic> suggestion) async {
    final placeId = suggestion['placeId'] as String;
    final placeName = suggestion['mainText'] as String? ??
        suggestion['description'] as String? ??
        '';

    setState(() => _fetchingDetail = true);
    try {
      final detail = await PlacesApiService.getPlaceLatLng(placeId);
      final address = detail?['address'] as String? ??
          suggestion['secondaryText'] as String? ??
          '';
      final types = (detail?['types'] as List?)?.cast<String>() ?? <String>[];
      final lat = (detail?['lat'] as num?)?.toDouble();
      final lng = (detail?['lng'] as num?)?.toDouble();

      Navigator.pop(context);
      widget.onPlaceSelected(placeName, address, placeId, types, lat, lng);
    } catch (_) {
      final address = suggestion['secondaryText'] as String? ?? '';
      Navigator.pop(context);
      widget.onPlaceSelected(placeName, address, placeId, <String>[], null, null);
    } finally {
      if (mounted) setState(() => _fetchingDetail = false);
    }
  }
  
  @override
  void dispose() {
    // Invalidate autocomplete still in flight.
    _autocompleteRequestId++;

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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const Text('Select Location', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _ctrl, autofocus: true, onChanged: _onChanged,
              decoration: InputDecoration(
                hintText: 'Search for attractions, restaurants, landmarks...',
                prefixIcon: _loading
                    ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 20, height: 20, child: TravelLoadingIndicator()))
                    : const Icon(Icons.search, color: Color(0xFF7C4DFF)),
                suffixIcon: _ctrl.text.isNotEmpty
                    ? IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () { _ctrl.clear(); setState(() => _suggestions = []); })
                    : null,
                filled: true, fillColor: Colors.grey[100],
                contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: const BorderSide(color: Color(0xFF7C4DFF), width: 1.5)),
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _suggestions.isEmpty
                ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.travel_explore, size: 64, color: Colors.grey[300]),
                    const SizedBox(height: 12),
                    Text(_ctrl.text.isEmpty ? 'Enter a location name to start searching' : 'No relevant locations found',
                        style: TextStyle(color: Colors.grey[400], fontSize: 14)),
                  ]))
                : ListView.separated(
                    itemCount: _suggestions.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, indent: 56),
                    itemBuilder: (context, index) {
                      final s = _suggestions[index];
                      return ListTile(
                        leading: const CircleAvatar(backgroundColor: Color(0xFFFFF3E0), child: Icon(Icons.location_on, color: Color(0xFF7C4DFF), size: 20)),
                        title: Text(s['mainText'] ?? s['description'] ?? '', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(s['secondaryText'] ?? '', style: TextStyle(color: Colors.grey[500], fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () => _onSuggestionTap(s),
                      );
                    },
                  ),
          ),
        ]),
        if (_fetchingDetail)
          Container(color: Colors.black.withOpacity(0.25), child: const Center(child: TravelLoadingIndicator())),
      ]),
    );
  }
}

class DottedBorderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    var paint = Paint()..color = Colors.grey.shade400..strokeWidth = 1..style = PaintingStyle.stroke;
    double dashWidth = 4, dashSpace = 3;
    void drawDashedLine(Offset start, Offset end) {
      double distance = (end - start).distance;
      for (double i = 0; i < distance; i += dashWidth + dashSpace) {
        canvas.drawLine(start + (end - start) * (i / distance), start + (end - start) * ((i + dashWidth) / distance), paint);
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