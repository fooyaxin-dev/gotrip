// ===== editPost.dart =====
// 放在 lib/modules/interaction/ 目录下

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:async';
import '../../models/postModel.dart';
import '../../services/algolia_service.dart';
import '../../services/apps_Loading.dart';

class EditPostPage extends StatefulWidget {
  final Post post;
  const EditPostPage({super.key, required this.post});

  @override
  State<EditPostPage> createState() => _EditPostPageState();
}

class _EditPostPageState extends State<EditPostPage> {
  late TextEditingController _titleController;
  late TextEditingController _contentController;
  late String _selectedVisibility;
  late List<String> _selectedTags;

  bool _isSaving = false;

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

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

  @override
  void initState() {
    super.initState();
    _titleController   = TextEditingController(text: widget.post.title);
    _contentController = TextEditingController(text: widget.post.content);
    _selectedVisibility = widget.post.visibility;
    _selectedTags = List<String>.from(widget.post.tags);

    _loadPopularTags();

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
    final available = allTags.where((t) => !_selectedTags.contains(t)).toList();

    if (q.isEmpty) {
      setState(() => _filteredTagSuggestions = available.take(10).toList());
    } else {
      final matched = available.where((t) => t.toLowerCase().contains(q)).toList();
      final userTag = q.replaceAll('#', '').replaceAll(' ', '');
      final suggestions = <String>[];
      if (userTag.isNotEmpty && !_selectedTags.contains(userTag)) suggestions.add(userTag);
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
    if (cleaned.isEmpty || _selectedTags.contains(cleaned)) return;
    if (_selectedTags.length >= 10) {
      _showSnack('Maximum 10 tags allowed', isError: true);
      return;
    }
    setState(() {
      _selectedTags.add(cleaned);
      _tagController.clear();
      _filteredTagSuggestions = [];
    });
    _updateTagSuggestions('');
  }

  void _removeTag(String tag) {
    setState(() => _selectedTags.remove(tag));
    _updateTagSuggestions(_tagController.text);
  }

  // ── Save ──────────────────────────────────────────────────────────────────

  Future<void> _saveChanges() async {
    final title   = _titleController.text.trim();
    final content = _contentController.text.trim();

    if (title.isEmpty || content.isEmpty) {
      _showSnack('Title and content cannot be empty', isError: true);
      return;
    }

    setState(() => _isSaving = true);

    try {
      final updates = {
        'title':      title,
        'content':    content,
        'visibility': _selectedVisibility,
        'tags':       _selectedTags,
      };

      // ── 更新 Firestore ──
      await _firestore.collection('posts').doc(widget.post.id).update(updates);

      // ── 同步到 Algolia ──
      // 只有 public 帖子才在 Algolia 里
      if (_selectedVisibility == 'public') {
        await AlgoliaService.syncPost(widget.post.id!, {
          ...updates,
          'city':       widget.post.city     ?? '',
          'location':   widget.post.location ?? '',
          'userName':   widget.post.isAnonymous ? 'Anonymous' : widget.post.userName,
          'likes':      widget.post.likes,
          'visibility': _selectedVisibility,
          'createdAt':  DateTime.now().millisecondsSinceEpoch,
        });
      } else {
        // 改成 private/friends → 从 Algolia 删掉
        await AlgoliaService.deletePost(widget.post.id!);
      }

      if (mounted) {
        Navigator.pop(context, true); // true = 有改动
        _showSnack('Post updated successfully!');
      }
    } catch (e) {
      _showSnack('Failed to update: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: isError ? Colors.red : Colors.green,
      duration: const Duration(seconds: 2),
    ));
  }

  void _dismissKeyboard() {
    FocusScope.of(context).unfocus();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leadingWidth: 80,
        leading: TextButton(
          onPressed: _isSaving ? null : () => Navigator.pop(context, false),
          child: Text('Cancel', style: TextStyle(color: _isSaving ? Colors.grey : Colors.black54, fontSize: 16)),
        ),
        title: const Text('Edit Post', style: TextStyle(color: Colors.black, fontSize: 17, fontWeight: FontWeight.bold)),
        centerTitle: true,
        actions: [
          Center(
            child: GestureDetector(
              onTap: _isSaving ? null : _saveChanges,
              child: Container(
                margin: const EdgeInsets.only(right: 12),
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                decoration: BoxDecoration(
                  color: _isSaving ? Colors.grey : const Color(0xFF7C4DFF),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: _isSaving
                    ? const SizedBox(width: 14, height: 14, child: TravelLoadingIndicator())
                    : const Text('Save', style: TextStyle(color: Colors.white, fontSize: 14)),
              ),
            ),
          ),
        ],
      ),
      body: GestureDetector(
        onTap: _dismissKeyboard,
        behavior: HitTestBehavior.opaque,
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const SizedBox(height: 20),

            // ── Title ──
            const Text('Title', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.black54)),
            const SizedBox(height: 8),
            TextField(
              controller: _titleController,
              enabled: !_isSaving,
              decoration: InputDecoration(
                hintText: 'Enter title',
                hintStyle: TextStyle(color: Colors.grey[400]),
                filled: true,
                fillColor: Colors.grey[100],
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF7C4DFF), width: 1.5)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              ),
            ),

            const SizedBox(height: 20),

            // ── Content ──
            const Text('Content', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.black54)),
            const SizedBox(height: 8),
            TextField(
              controller: _contentController,
              enabled: !_isSaving,
              maxLines: 8,
              decoration: InputDecoration(
                hintText: 'What\'s on your mind?',
                hintStyle: TextStyle(color: Colors.grey[400]),
                filled: true,
                fillColor: Colors.grey[100],
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF7C4DFF), width: 1.5)),
                contentPadding: const EdgeInsets.all(16),
              ),
            ),

            const SizedBox(height: 20),

            // ── Visibility ──
            const Text('Visibility', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.black54)),
            const SizedBox(height: 8),
            Row(children: [
              _buildVisibilityChip('public',  Icons.public,  'Public'),
              const SizedBox(width: 8),
              _buildVisibilityChip('friends', Icons.people,  'Friends'),
              const SizedBox(width: 8),
              _buildVisibilityChip('private', Icons.lock,    'Private'),
            ]),

            const SizedBox(height: 20),

            // ── Tags ──
            Row(children: [
              const Text('Tags', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.black54)),
              const SizedBox(width: 8),
              Text('${_selectedTags.length}/10', style: TextStyle(fontSize: 12, color: Colors.grey[500])),
            ]),
            const SizedBox(height: 8),

            // 已选 tag chips
            if (_selectedTags.isNotEmpty) ...[
              Wrap(
                spacing: 8, runSpacing: 8,
                children: _selectedTags.map((tag) => Chip(
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

            // Tag 输入框
            if (_selectedTags.length < 10)
              TextField(
                controller: _tagController,
                focusNode: _tagFocus,
                enabled: !_isSaving,
                onChanged: _onTagChanged,
                onSubmitted: (value) { if (value.trim().isNotEmpty) _selectTag(value.trim()); },
                decoration: InputDecoration(
                  hintText: 'Type a tag and press Enter...',
                  hintStyle: TextStyle(color: Colors.grey[400], fontSize: 13),
                  prefixIcon: const Icon(Icons.tag, color: Color(0xFF7C4DFF), size: 18),
                  filled: true,
                  fillColor: Colors.grey[100],
                  contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: const BorderSide(color: Color(0xFF7C4DFF), width: 1.5)),
                ),
              ),

            // Tag 建议下拉
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

            const SizedBox(height: 40),

            // ── 不能改的字段说明 ──
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.grey[50],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey[200]!),
              ),
              child: Row(children: [
                Icon(Icons.info_outline, size: 16, color: Colors.grey[500]),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Location and media cannot be edited after posting.',
                    style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                  ),
                ),
              ]),
            ),

            const SizedBox(height: 40),
          ]),
        ),
      ),
    );
  }

  Widget _buildVisibilityChip(String value, IconData icon, String label) {
    final isSelected = _selectedVisibility == value;
    return GestureDetector(
      onTap: _isSaving ? null : () => setState(() => _selectedVisibility = value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF7C4DFF) : Colors.grey[100],
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: isSelected ? const Color(0xFF7C4DFF) : Colors.grey[300]!),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: isSelected ? Colors.white : Colors.grey[600]),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 13, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal, color: isSelected ? Colors.white : Colors.grey[600])),
        ]),
      ),
    );
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
          Text('#$tag', style: TextStyle(fontSize: 14, fontWeight: isUserInput ? FontWeight.w600 : FontWeight.normal, color: isUserInput ? const Color(0xFF7C4DFF) : Colors.black87)),
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

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    _tagController.dispose();
    _tagFocus.dispose();
    _tagDebounce?.cancel();
    super.dispose();
  }
}