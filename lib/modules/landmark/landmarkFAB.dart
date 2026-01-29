import 'dart:convert';
import 'dart:io' show File;

import 'package:flutter/foundation.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'vision_service.dart';
import 'landmarkResult.dart';

class LandmarkFAB extends StatefulWidget {
  const LandmarkFAB({super.key});

  @override
  State<LandmarkFAB> createState() => _LandmarkFABState();
}

class _LandmarkFABState extends State<LandmarkFAB> {
  bool _loading = false;
  final ImagePicker _picker = ImagePicker();

  CameraController? _cameraController;
  bool _isCameraReady = false;

  Uint8List? _previewBytes;

  @override
  void initState() {
    super.initState();
    _previewBytes = null; // 页面打开就清空上次照片
    if (!kIsWeb) {
      _initCamera();
    }
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    final camera = cameras.first;

    _cameraController = CameraController(
      camera,
      ResolutionPreset.max,
      enableAudio: false,
    );

    await _cameraController!.initialize();

    if (mounted) {
      setState(() {
        _isCameraReady = true;
      });
    }
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    super.dispose();
  }

  // ---- 1) Camera Scan (Mobile only) ----
  Future<void> _scanWithCamera() async {
    if (kIsWeb) return;
    if (!_isCameraReady || _cameraController == null) return;

    // 1️⃣ 开始新一次扫描：先清空旧照片
    setState(() {
      _previewBytes = null;
      _loading = true;
    });

    final file = await _cameraController!.takePicture();
    final bytes = await File(file.path).readAsBytes();

    setState(() {
      _previewBytes = bytes; // 显示当前拍的照片
    });

    // 2️⃣ Vision API
    final base64Image = base64Encode(bytes);
    final response = await VisionService.detectLandmarkWithJson(base64Image);

    setState(() {
      _loading = false;
    });

    if (!mounted) return;

    // 3️⃣ 进入 ResultPage，并等待返回结果
    final shouldClear = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ResultPage(
          imageBytes: bytes,
          landmark: response['landmark'] ?? "No landmark detected",
          rawJson: response['rawJson'] ?? "",
        ),
      ),
    );

    // 4️⃣ 从 ResultPage 返回 → 清空照片（关键）
    if (shouldClear == true && mounted) {
      setState(() {
        _previewBytes = null;
      });
    }
  }

  // ---- 2) Gallery (Web & Mobile) ----
  Future<void> _pickImage(ImageSource source) async {
    final XFile? pickedFile = await _picker.pickImage(
      source: source,
      imageQuality: 100,
    );
    if (pickedFile == null) return;

    // 1️⃣ 新一次识别，先清掉旧照片
    setState(() {
      _previewBytes = null;
      _loading = true;
    });

    final bytes = kIsWeb
        ? await pickedFile.readAsBytes()
        : await File(pickedFile.path).readAsBytes();

    setState(() {
      _previewBytes = bytes;
    });

    // 2️⃣ Vision API
    final base64Image = base64Encode(bytes);
    final response = await VisionService.detectLandmarkWithJson(base64Image);

    setState(() {
      _loading = false;
    });

    if (!mounted) return;

    // 3️⃣ 进入 ResultPage，等待返回
    final shouldClear = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ResultPage(
          imageBytes: bytes,
          landmark: response['landmark'] ?? "No landmark detected",
          rawJson: response['rawJson'] ?? "",
        ),
      ),
    );

    // 4️⃣ 返回 LandmarkFAB → 清空旧照片
    if (shouldClear == true && mounted) {
      setState(() {
        _previewBytes = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ---- 1. 全屏预览 ----
          Positioned.fill(
            child: ClipRRect(
              child: _buildGoogleLensPreview(),
            ),
          ),

          // ---- 2. 顶部状态栏 ----
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 120,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black.withOpacity(0.7), Colors.transparent],
                ),
              ),
              padding: const EdgeInsets.only(top: 50, left: 20),
              child: const Text(
                "              Landmark Recognition",
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w500),
              ),
            ),
          ),

          // ---- 3. 扫描框 ----
          Center(
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white.withOpacity(0.5), width: 1),
                borderRadius: BorderRadius.circular(32),
              ),
              child: Stack(
                children: _buildCornerIndicators(),
              ),
            ),
          ),

          // ---- 4. 底部控制台 ----
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 20),
                    child: CircularProgressIndicator(color: Colors.white),
                  ),
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 40),
                  padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 10),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(40),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _lensActionButton(
                        icon: Icons.photo_library_outlined,
                        onTap: () => _pickImage(ImageSource.gallery),
                      ),
                      GestureDetector(
                        onTap: _scanWithCamera,
                        child: Container(
                          height: 70,
                          width: 70,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 4),
                          ),
                          child: Center(
                            child: Container(
                              height: 55,
                              width: 55,
                              decoration: const BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ),
                      ),
                      _lensActionButton(
                        icon: Icons.flash_on_rounded,
                        onTap: () {},
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  "Tap shutter to identify landmark",
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ),

          // ---- 5. 返回按钮 ----  
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(left: 12, top: 12),
              child: CircleAvatar(
                backgroundColor: Colors.white.withOpacity(0.9),
                child: IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.black),
                  onPressed: () {
                    setState(() {
                      _previewBytes = null; // 返回前清掉照片
                    });
                    Navigator.pop(context);
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---- 预览逻辑 ----
  Widget _buildGoogleLensPreview() {
    if (kIsWeb) {
      return _previewBytes == null
          ? const Center(child: Icon(Icons.image, color: Colors.white24, size: 80))
          : Image.memory(_previewBytes!, fit: BoxFit.cover);
    } else {
      if (_isCameraReady && _cameraController != null) {
        return _previewBytes != null
            ? Image.memory(_previewBytes!, fit: BoxFit.cover)
            : CameraPreview(_cameraController!);
      }
      return const Center(child: CircularProgressIndicator(color: Colors.white));
    }
  }

  Widget _lensActionButton({required IconData icon, required VoidCallback onTap}) {
    return IconButton(
      icon: Icon(icon, color: Colors.white, size: 28),
      onPressed: onTap,
    );
  }

  List<Widget> _buildCornerIndicators() {
    const double length = 20.0;
    const double thickness = 4.0;

    return [
      Positioned(top: 0, left: 0, child: _corner(top: thickness, left: thickness)),
      Positioned(top: 0, right: 0, child: _corner(top: thickness, right: thickness)),
      Positioned(bottom: 0, left: 0, child: _corner(bottom: thickness, left: thickness)),
      Positioned(bottom: 0, right: 0, child: _corner(bottom: thickness, right: thickness)),
    ];
  }

  Widget _corner({double? top, double? bottom, double? left, double? right}) {
    return Container(
      width: 25,
      height: 25,
      decoration: BoxDecoration(
        border: Border(
          top: top != null ? const BorderSide(color: Colors.white, width: 4) : BorderSide.none,
          bottom: bottom != null ? const BorderSide(color: Colors.white, width: 4) : BorderSide.none,
          left: left != null ? const BorderSide(color: Colors.white, width: 4) : BorderSide.none,
          right: right != null ? const BorderSide(color: Colors.white, width: 4) : BorderSide.none,
        ),
      ),
    );
  }
}