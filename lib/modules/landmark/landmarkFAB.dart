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
    if (!kIsWeb) {
      _initCamera();
    }
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    final camera = cameras.first;

    _cameraController = CameraController(camera, ResolutionPreset.medium);
    await _cameraController!.initialize();

    setState(() {
      _isCameraReady = true;
    });
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    super.dispose();
  }

  // ---- 1) Camera Scan (Mobile only) ----
  Future<void> _scanWithCamera() async {
    if (kIsWeb) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Web does not support camera scanning")),
      );
      return;
    }

    if (!_isCameraReady || _cameraController == null) return;

    final file = await _cameraController!.takePicture();
    await _processAndGoToResult(file.path, isWeb: false);
  }

  // ---- 2) Gallery (Web & Mobile) ----
  Future<void> _pickImage(ImageSource source) async {
    final XFile? pickedFile = await _picker.pickImage(source: source);
    if (pickedFile == null) return;

    await _processAndGoToResult(pickedFile.path, isWeb: kIsWeb);
  }

  // ---- 3) Process + call API + go to Result ----
  Future<void> _processAndGoToResult(String path, {required bool isWeb}) async {
    setState(() {
      _loading = true;
    });

    Uint8List bytes;

    if (isWeb) {
      bytes = await XFile(path).readAsBytes();
    } else {
      bytes = await File(path).readAsBytes();
    }

    // preview
    setState(() {
      _previewBytes = bytes;
    });

    final base64Image = base64Encode(bytes);

    final response = await VisionService.detectLandmarkWithJson(base64Image);

    setState(() {
      _loading = false;
    });


    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ResultPage(
          imageBytes: bytes,
          landmark: response['landmark'] ?? "No landmark detected",
          rawJson: response['rawJson'] ?? "",

        ),
      ),
    );


  }

 @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black, // Google Lens 核心色调
      // 使用 Stack 实现全屏预览和按钮悬浮
      body: Stack(
        children: [
          // ---- 1. 全屏预览层 ----
          Positioned.fill(
            child: ClipRRect(
              child: _buildGoogleLensPreview(),
            ),
          ),

          // ---- 2. 顶部状态栏阴影/遮罩 (增加视觉层次) ----
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
                style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w500),
              ),
            ),
          ),

          // ---- 3. 扫描辅助框 (Google Lens 特色) ----
          Center(
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white.withOpacity(0.5), width: 1),
                borderRadius: BorderRadius.circular(32),
              ),
              child: Stack(
                children: _buildCornerIndicators(), // 四角的白线
              ),
            ),
          ),

          // ---- 4. 底部悬浮控制台 ----
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
                
                // 按钮容器
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
                      // 主拍照按钮 (快门风格)
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
                        icon: Icons.flash_on_rounded, // 示意功能
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
           SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(left: 12, top: 12),
              child: CircleAvatar(
                backgroundColor: Colors.white.withOpacity(0.9),
                child: IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.black),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 预览逻辑
  Widget _buildGoogleLensPreview() {
    if (kIsWeb) {
      return _previewBytes == null
          ? const Center(child: Icon(Icons.image, color: Colors.white24, size: 80))
          : Image.memory(_previewBytes!, fit: BoxFit.cover);
    } else {
      if (_isCameraReady && _cameraController != null) {
        return CameraPreview(_cameraController!);
      }
      return const Center(child: CircularProgressIndicator(color: Colors.white));
    }
  }

  // 小功能按钮
  Widget _lensActionButton({required IconData icon, required VoidCallback onTap}) {
    return IconButton(
      icon: Icon(icon, color: Colors.white, size: 28),
      onPressed: onTap,
    );
  }

  // 扫描框四角的装饰
  List<Widget> _buildCornerIndicators() {
    const double length = 20.0;
    const double thickness = 4.0;
    const Color color = Colors.white;

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