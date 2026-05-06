import 'dart:convert';
import 'dart:io' show File;
import 'package:flutter/foundation.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;

import '../../services/vision_service.dart';
import 'landmarkResult.dart'; // your ResultPage lives here

class LandmarkFAB extends StatefulWidget {
  const LandmarkFAB({super.key});

  @override
  State<LandmarkFAB> createState() => _LandmarkFABState();
}

class _LandmarkFABState extends State<LandmarkFAB>
    with SingleTickerProviderStateMixin {
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
    _scanController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _previewBytes = null;
    if (!kIsWeb) _initCamera();
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    _cameraController = CameraController(
      cameras.first,
      ResolutionPreset.max,
      enableAudio: false,
    );
    await _cameraController!.initialize();
    if (mounted) setState(() => _isCameraReady = true);
  }

  @override
  void dispose() {
    if (_isFlashOn) _cameraController?.setFlashMode(FlashMode.off);
    _cameraController?.dispose();
    _scanController.dispose();
    super.dispose();
  }

  // ── Core: process bytes → detect → navigate ───────────────
    Future<void> _processImage(Uint8List bytes) async {
      setState(() {
        _previewBytes = bytes;
        _loading = true;
      });

      final base64Image = base64Encode(bytes);
      debugPrint('🚀 Calling VisionService.detectLandmark...');

      final landmarkResult = await VisionService.detectLandmark(base64Image);

      debugPrint('🏛️ Result: ${landmarkResult.landmark} [${landmarkResult.method}]');
      setState(() => _loading = false);

      if (!mounted) return;

      await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => ResultPage(
            imageBytes: bytes,
            landmarkResult: landmarkResult,
          ),
        ),
      );

      if (mounted) {
        setState(() => _previewBytes = null);
      }
    }

  // ── 1. Camera ─────────────────────────────────────────────
  Future<void> _scanWithCamera() async {
    if (kIsWeb || !_isCameraReady || _cameraController == null) return;

    final file = await _cameraController!.takePicture();
    final rawBytes = await File(file.path).readAsBytes();
    final decoded = img.decodeImage(rawBytes)!;
    final fixed = img.bakeOrientation(decoded);
    final bytes = Uint8List.fromList(img.encodeJpg(fixed, quality: 90));

    await _processImage(bytes);
  }

  // ── 2. Gallery ────────────────────────────────────────────
  Future<void> _pickImage(ImageSource source) async {
    final XFile? pickedFile =
        await _picker.pickImage(source: source, imageQuality: 100);
    if (pickedFile == null) return;

    final bytes = kIsWeb
        ? await pickedFile.readAsBytes()
        : await File(pickedFile.path).readAsBytes();

    await _processImage(bytes);
  }

  Future<void> _toggleFlash() async {
    if (_cameraController == null || !_isCameraReady) return;
    final newMode = _isFlashOn ? FlashMode.off : FlashMode.torch;
    await _cameraController!.setFlashMode(newMode);
    setState(() => _isFlashOn = !_isFlashOn);
  }

  // ── Build ─────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: _buildPreview()),
          _buildTopGradient(),
          _buildScanFrame(),
          _buildBottomControls(),
          _buildCloseButton(),
        ],
      ),
    );
  }

  Widget _buildPreview() {
    if (kIsWeb) {
      return _previewBytes == null
          ? const Center(child: Icon(Icons.image, color: Colors.white24, size: 80))
          : Image.memory(_previewBytes!, fit: BoxFit.cover);
    }
    if (_isCameraReady && _cameraController != null) {
      return _previewBytes != null
          ? Image.memory(_previewBytes!, fit: BoxFit.cover)
          : CameraPreview(_cameraController!);
    }
    return const Center(child: CircularProgressIndicator(color: Colors.white));
  }

  Widget _buildTopGradient() {
    return Positioned(
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
              'Landmark Recognition',
              style: TextStyle(
                color: Colors.white.withOpacity(0.9),
                fontSize: 18,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildScanFrame() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 280,
            height: 280,
            child: Stack(
              children: [
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(color: Colors.white24, width: 1),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(30),
                    child: Stack(children: _buildCornerIndicators()),
                  ),
                ),
                if (_isCameraReady && !_loading)
                  AnimatedBuilder(
                    animation: _scanController,
                    builder: (_, __) => Positioned(
                      top: _scanController.value * 280,
                      left: 0, right: 0,
                      child: Container(
                        height: 2,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(colors: [
                            Colors.transparent,
                            Colors.blueAccent.withOpacity(0.5),
                            Colors.transparent,
                          ]),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black38,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              _loading ? 'Analyzing landmark...' : 'Position the landmark in the middle',
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomControls() {
    return Positioned(
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
              IconButton(
                icon: const Icon(Icons.photo_library, color: Colors.white, size: 28),
                onPressed: () => _pickImage(ImageSource.gallery),
              ),
              GestureDetector(
                onTap: _loading ? null : _scanWithCamera,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(
                    color: Colors.white30, shape: BoxShape.circle,
                  ),
                  child: Container(
                    height: 60, width: 60,
                    decoration: const BoxDecoration(
                      color: Colors.white, shape: BoxShape.circle,
                    ),
                    child: _loading
                        ? const Padding(
                            padding: EdgeInsets.all(15),
                            child: CircularProgressIndicator(strokeWidth: 3),
                          )
                        : const Icon(Icons.camera_alt, color: Colors.black, size: 30),
                  ),
                ),
              ),
              IconButton(
                icon: Icon(
                  _isFlashOn ? Icons.flash_on : Icons.flash_off,
                  color: Colors.white, size: 28,
                ),
                onPressed: kIsWeb ? null : _toggleFlash,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCloseButton() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: IconButton(
          icon: const Icon(Icons.close, color: Colors.white, size: 30),
          onPressed: () => Navigator.pop(context),
        ),
      ),
    );
  }

  List<Widget> _buildCornerIndicators() {
    return [
      Positioned(top: 0, left: 0, child: _corner(showTop: true, showLeft: true)),
      Positioned(top: 0, right: 0, child: _corner(showTop: true, showRight: true)),
      Positioned(bottom: 0, left: 0, child: _corner(showBottom: true, showLeft: true)),
      Positioned(bottom: 0, right: 0, child: _corner(showBottom: true, showRight: true)),
    ];
  }

  Widget _corner({
    bool showTop = false, bool showBottom = false,
    bool showLeft = false, bool showRight = false,
  }) {
    return Container(
      width: 25, height: 25,
      decoration: BoxDecoration(
        border: Border(
          top:    showTop    ? const BorderSide(color: Colors.white, width: 4) : BorderSide.none,
          bottom: showBottom ? const BorderSide(color: Colors.white, width: 4) : BorderSide.none,
          left:   showLeft   ? const BorderSide(color: Colors.white, width: 4) : BorderSide.none,
          right:  showRight  ? const BorderSide(color: Colors.white, width: 4) : BorderSide.none,
        ),
      ),
    );
  }
}