import 'dart:convert';
import 'dart:io' show File;
import 'package:flutter/foundation.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import '../../services/apps_Loading.dart';

import '../../services/vision_service.dart';
import 'landmarkResult.dart'; // your ResultPage lives here

// ── Top-level functions for isolate processing ─────────────
// Must be top-level (or static) so `compute()` can send them to another isolate.

// Fixes EXIF orientation, downsizes to a sane max dimension for recognition,
// and re-encodes as JPEG. Keeps the payload small for both decoding speed
// and network upload size.
Uint8List _fixOrientationAndEncode(Uint8List rawBytes) {
  final decoded = img.decodeImage(rawBytes)!;
  var fixed = img.bakeOrientation(decoded);
  if (fixed.width > 1600) {
    fixed = img.copyResize(fixed, width: 1600);
  }
  return Uint8List.fromList(img.encodeJpg(fixed, quality: 85));
}

// base64 encoding of a multi-MB image is a synchronous CPU-bound op;
// push it off the UI isolate too.
String _encodeBase64(Uint8List bytes) => base64Encode(bytes);

class LandmarkFAB extends StatefulWidget {
  const LandmarkFAB({super.key});

  @override
  State<LandmarkFAB> createState() => _LandmarkFABState();
}

class _LandmarkFABState extends State<LandmarkFAB>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late AnimationController _scanController;
  bool _loading = false;
  bool _isFlashOn = false;
  final ImagePicker _picker = ImagePicker();

  CameraController? _cameraController;
  bool _isCameraReady = false;
  bool _cameraError = false;
  Uint8List? _previewBytes;

  // Staged status text shown under the scan frame while _loading is true.
  String _statusText = 'Analyzing landmark...';

  // Monotonically increasing id for each capture/pick attempt. Any async
  // work that completes for a *stale* request (because the user backed out,
  // or fired a new request meanwhile) is discarded instead of touching state
  // or navigating — this is our lightweight substitute for a true network
  // cancellation token.
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scanController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _previewBytes = null;
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw CameraException('no_camera', 'No camera available on this device');
      }

      final controller = CameraController(
        cameras.first,
        ResolutionPreset.high, // 'max' is overkill for landmark recognition and slows down every downstream step
        enableAudio: false,
      );
      await controller.initialize();

      // Widget may have been disposed while awaiting initialize().
      if (!mounted) {
        await controller.dispose();
        return;
      }

      _cameraController = controller;
      setState(() {
        _isCameraReady = true;
        _cameraError = false;
      });
    } catch (e) {
      debugPrint('⚠️ Camera init failed: $e');
      if (mounted) {
        setState(() {
          _cameraError = true;
          _isCameraReady = false;
        });
      }
    }
  }

  // ── App lifecycle: release/reacquire the camera around backgrounding ──
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;

    if (
        state == AppLifecycleState.paused) {
      _isFlashOn = false;
      controller.dispose();
      _cameraController = null;
      if (mounted) setState(() => _isCameraReady = false);
   } else if (state == AppLifecycleState.resumed) {
  if (_cameraController == null) _initCamera();
}
  }

  @override
  void dispose() {
    // Bump the request id so any in-flight work discards its result instead
    // of calling setState/Navigator after this State is gone.
    _requestId++;
    WidgetsBinding.instance.removeObserver(this);
    if (_isFlashOn) _cameraController?.setFlashMode(FlashMode.off);
    _cameraController?.dispose();
    _scanController.dispose();
    super.dispose();
  }

  // ── Core: process bytes → detect → navigate ───────────────
  Future<void> _processImage(Uint8List bytes, int myRequestId) async {
    setState(() {
      _previewBytes = bytes;
      _loading = true;
      _statusText = 'Processing image...';
    });

    // Heavy, synchronous CPU work — keep off the UI isolate.
    final base64Image = await compute(_encodeBase64, bytes);

    // A newer request superseded this one (user retriggered, or left the
    // page) — drop the result silently.
    if (myRequestId != _requestId || !mounted) return;

    setState(() => _statusText = 'Identifying landmark...');
    debugPrint('🚀 Calling VisionService.detectLandmark...');

    try {
      final landmarkResult =
          await VisionService.detectLandmark(base64Image);

      // Check again — the network call may have outlived the request's
      // relevance (user navigated away, fired another capture, etc).
      if (myRequestId != _requestId || !mounted) return;

      debugPrint(
          '🏛️ Result: ${landmarkResult.landmark} [${landmarkResult.method}]');

      setState(() => _loading = false);

      await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => ResultPage(
            imageBytes: bytes,
            landmarkResult: landmarkResult,
          ),
        ),
      );

      if (mounted && myRequestId == _requestId) {
        setState(() => _previewBytes = null);
      }
    } catch (e) {
      debugPrint('⚠️ detectLandmark failed: $e');
      if (myRequestId != _requestId || !mounted) return;
      setState(() {
        _loading = false;
        _previewBytes = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Recognition failed, please try again')),
      );
    }
  }

  // ── 1. Camera ─────────────────────────────────────────────
  Future<void> _scanWithCamera() async {
    // Debounce: ignore taps while a request is already in flight.
    if (_loading || !_isCameraReady || _cameraController == null) return;

    // Immediate feedback the instant the shutter is tapped, rather than
    // waiting for takePicture() + decode to finish before anything visibly
    // changes.
    final myRequestId = ++_requestId;
    setState(() {
      _loading = true;
      _statusText = 'Capturing...';
    });

    try {
      final file = await _cameraController!.takePicture();
if (myRequestId != _requestId || !mounted) return;

final rawBytes = await File(file.path).readAsBytes();

// 立刻冻结画面，不等 orientation-fix
if (myRequestId == _requestId && mounted) {
  setState(() {
    _previewBytes = rawBytes;
    _loading = true;
    _statusText = 'Processing image...';
  });
}

final bytes = await compute(_fixOrientationAndEncode, rawBytes);
if (myRequestId != _requestId || !mounted) return;

await _processImage(bytes, myRequestId);
    } catch (e) {
      debugPrint('⚠️ takePicture failed: $e');
      if (myRequestId != _requestId || !mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to take picture, please try again')),
      );
    }
  }

  // ── 2. Gallery ────────────────────────────────────────────
  Future<void> _pickImage(ImageSource source) async {
    // Debounce: ignore taps while a request is already in flight.
    if (_loading) return;

    final myRequestId = ++_requestId;

    try {
      final XFile? pickedFile =
          await _picker.pickImage(source: source, imageQuality: 100);
      if (pickedFile == null) return;

      if (myRequestId != _requestId || !mounted) return;
      setState(() {
        _loading = true;
        _statusText = 'Processing image...';
      });

      final rawBytes = await File(pickedFile.path).readAsBytes();

      if (myRequestId != _requestId || !mounted) return;
      setState(() {
        _previewBytes = rawBytes;      // 立刻冻结画面
        _loading = true;
        _statusText = 'Processing image...';
      });

      final bytes = await compute(_fixOrientationAndEncode, rawBytes);
      if (myRequestId != _requestId || !mounted) return;

      await _processImage(bytes, myRequestId);

    } catch (e) {
      debugPrint('⚠️ pickImage failed: $e');
      if (myRequestId != _requestId || !mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to pick image, please try again')),
      );
    }
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
    if (_cameraError) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '无法访问相机，请检查权限设置后重试',
            style: TextStyle(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_isCameraReady && _cameraController != null) {
      return _previewBytes != null
          // cacheWidth avoids decoding the full-resolution image just to
          // display it in a small preview frame — big memory/CPU win.
          ? Image.memory(_previewBytes!, fit: BoxFit.cover, cacheWidth: 800)
          : CameraPreview(_cameraController!);
    }
    return const Center(child: TravelLoadingIndicator());
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
              _loading ? _statusText : 'Position the landmark in the middle',
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
                onPressed: _loading ? null : () => _pickImage(ImageSource.gallery),
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
                          child: TravelLoadingIndicator(size: 22, color: Colors.black),
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
                onPressed: _loading ? null : _toggleFlash,
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