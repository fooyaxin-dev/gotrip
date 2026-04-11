import 'dart:convert';
import 'dart:io' show File;
import 'package:flutter/foundation.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;

import '../../services/vision_service.dart';
import 'landmarkResult.dart';

class LandmarkFAB extends StatefulWidget {
  const LandmarkFAB({super.key});

  @override
  State<LandmarkFAB> createState() => _LandmarkFABState();
}

class _LandmarkFABState extends State<LandmarkFAB> with SingleTickerProviderStateMixin {
  
  late AnimationController _scanController;
  bool _loading = false;
  bool _isFlashOn = false;
  final ImagePicker _picker = ImagePicker();

  CameraController? _cameraController;
  bool _isCameraReady = false;

  Uint8List? _previewBytes;

  @override
  void initState() {
    super.initState();
    // 扫描线动画：2秒一个来回
    _scanController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
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
    if (_isFlashOn && _cameraController != null) {
      _cameraController!.setFlashMode(FlashMode.off);
    }
    _cameraController?.dispose();
    _scanController.dispose();
    super.dispose();
  }

  // ---- 1) Camera Scan (Mobile only) ----
  Future<void> _scanWithCamera() async {
    if (kIsWeb) return;
    if (!_isCameraReady || _cameraController == null) return;

    setState(() {
      _previewBytes = null;
      _loading = true;
    });

    final file = await _cameraController!.takePicture();
    final rawBytes = await File(file.path).readAsBytes();

    print('📷 RAW image size: ${rawBytes.length} bytes (${(rawBytes.length / 1024 / 1024).toStringAsFixed(2)} MB)');

    final decoded = img.decodeImage(rawBytes);
    print('📐 Decoded size: ${decoded?.width}x${decoded?.height}');

    final fixed = img.bakeOrientation(decoded!);
    print('🔄 After bakeOrientation: ${fixed.width}x${fixed.height}');

    final bytes = Uint8List.fromList(img.encodeJpg(fixed, quality: 90));
    print('📦 Final encoded size: ${bytes.length} bytes (${(bytes.length / 1024 / 1024).toStringAsFixed(2)} MB)');

    // ✅ 拍完马上显示照片，不等 API
    setState(() {
      _previewBytes = bytes;
    });

    final base64Image = base64Encode(bytes);
    print('📤 Base64 length: ${base64Image.length}');

    print('🚀 Calling VisionService...');
    final response = await VisionService.detectLandmarkWithJson(base64Image);
    print('✅ Response: $response');
    print('🏛️ Landmark: ${response['landmark']}');
    print('📋 rawJson: ${response['rawJson']}');

    // ✅ API 回来后只更新 loading 状态
    setState(() {
      _loading = false;
    });

    if (!mounted) return;

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

  Future<void> _toggleFlash() async {
    if (_cameraController == null || !_isCameraReady) return;

    final newMode = _isFlashOn ? FlashMode.off : FlashMode.torch;
    await _cameraController!.setFlashMode(newMode);

    setState(() {
      _isFlashOn = !_isFlashOn;
    });
  }

@override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. 全屏预览
          Positioned.fill(child: _buildGoogleLensPreview()),

          // 2. 顶部渐变标题栏
          Positioned(
            top: 0, left: 0, right: 0,
            child: Container(
              height: 150,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black.withOpacity(0.8), Colors.transparent],
                ),
              ),
              child: SafeArea(
                child: Center(
                  child: Text(
                    "Landmark Recognition",
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.9),
                      fontSize: 18,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
          ),

          // 3. 扫描框 (带动态扫描线)
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: 280,
                      height: 280,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(color: Colors.white24, width: 1),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(30),
                        child: Stack(
                          children: [
                            ..._buildCornerIndicators(),
                            // 动态扫描线
                            if (_isCameraReady && !_loading)
                              AnimatedBuilder(
                                animation: _scanController,
                                builder: (context, child) {
                                  return Positioned(
                                    top: _scanController.value * 280,
                                    left: 0, right: 0,
                                    child: Container(
                                      height: 2,
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          colors: [Colors.transparent, Colors.blueAccent.withOpacity(0.5), Colors.transparent],
                                        ),
                                        boxShadow: [
                                          BoxShadow(color: Colors.blueAccent.withOpacity(0.4), blurRadius: 10, spreadRadius: 2)
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                // 提示文字背景
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black38,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _loading ? "Analyzing landmark..." : "Position the landmark in the middle",
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),

          // 4. 底部控制台 (玻璃拟态设计)
          Positioned(
            bottom: 50, left: 30, right: 30,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(40),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 15),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.1),
                  border: Border.all(color: Colors.white24),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _lensActionButton(icon: Icons.photo_library, onTap: () => _pickImage(ImageSource.gallery)),
                    // 拍照大按钮
                    GestureDetector(
                      onTap: _scanWithCamera,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(color: Colors.white30, shape: BoxShape.circle),
                        child: Container(
                          height: 60, width: 60,
                          decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                          child: _loading 
                            ? const Padding(padding: EdgeInsets.all(15), child: CircularProgressIndicator(strokeWidth: 3))
                            : const Icon(Icons.camera_alt, color: Colors.black, size: 30),
                        ),
                      ),
                    ),
                    _lensActionButton(
                      icon: _isFlashOn ? Icons.flash_on : Icons.flash_off,
                      onTap: kIsWeb ? () {} : _toggleFlash,  // Web 没有闪光灯，直接 no-op
                    ),
                  ],
                ),
              ),
            ),
          ),

          // 5. 返回按钮 (左上角)
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 30),
                onPressed: () => Navigator.pop(context),
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