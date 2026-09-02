import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:geolocator/geolocator.dart';
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

enum LandmarkCameraState {
  initializing,
  ready,
  permissionDenied,
  permissionPermanentlyDenied,
  noCamera,
  initializationFailed,
}

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
  LandmarkCameraState _cameraState = LandmarkCameraState.initializing;
  bool _waitingForCameraSettingsReturn = false;
  Uint8List? _previewBytes;

  // ── Tap-to-Focus state ──
  Offset? _focusPoint;
  bool _showFocusIndicator = false;
  Timer? _focusTimer;

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
    if (!mounted) return;
    setState(() => _cameraState = LandmarkCameraState.initializing);
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (!mounted) return;
        setState(() {
          _cameraState = LandmarkCameraState.noCamera;
          _isCameraReady = false;
        });
        return;
      }

      final camera = cameras.first;
      CameraController controller = CameraController(
        camera,
        ResolutionPreset.veryHigh,
        enableAudio: false,
      );

      try {
        await controller.initialize();
      } catch (initErr) {
        if (initErr is CameraException &&
            (initErr.code == 'CameraAccessDenied' ||
                initErr.code == 'CameraAccessDeniedWithoutPrompt' ||
                initErr.code == 'CameraAccessRestricted')) {
          rethrow;
        }

        // Retry with high resolution if veryHigh is unsupported
        debugPrint(
            '⚠️ veryHigh resolution failed ($initErr), retrying with high...');
        await controller.dispose();

        if (!mounted) return;

        controller = CameraController(
          camera,
          ResolutionPreset.high,
          enableAudio: false,
        );
        await controller.initialize();
      }

      // Widget may have been disposed while awaiting initialize().
      if (!mounted) {
        await controller.dispose();
        return;
      }

      // Configure autofocus and auto exposure safely where supported
      try {
        await controller.setFocusMode(FocusMode.auto);
      } catch (_) {}

      try {
        await controller.setExposureMode(ExposureMode.auto);
      } catch (_) {}

      _cameraController = controller;
      setState(() {
        _isCameraReady = true;
        _cameraState = LandmarkCameraState.ready;
      });
    } catch (e) {
      debugPrint('⚠️ Camera init failed: $e');
      if (!mounted) return;

      LandmarkCameraState mappedState =
          LandmarkCameraState.initializationFailed;
      if (e is CameraException) {
        if (e.code == 'CameraAccessDenied') {
          mappedState = LandmarkCameraState.permissionDenied;
        } else if (e.code == 'CameraAccessDeniedWithoutPrompt' ||
            e.code == 'CameraAccessRestricted') {
          mappedState = LandmarkCameraState.permissionPermanentlyDenied;
        } else if (e.code == 'no_camera') {
          mappedState = LandmarkCameraState.noCamera;
        }
      }

      setState(() {
        _cameraState = mappedState;
        _isCameraReady = false;
      });
    }
  }

  // ── App lifecycle: release/reacquire the camera around backgrounding ──
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _cameraController;
    if (state == AppLifecycleState.paused) {
      _isFlashOn = false;
      controller?.dispose();
      _cameraController = null;
      if (mounted) setState(() => _isCameraReady = false);
    } else if (state == AppLifecycleState.resumed) {
      if (!mounted) return;
      if (_waitingForCameraSettingsReturn) {
        _waitingForCameraSettingsReturn = false;
        _initCamera();
      } else if (_cameraState == LandmarkCameraState.ready &&
          _cameraController == null) {
        _initCamera();
      }
    }
  }

  @override
  void dispose() {
    // Bump the request id so any in-flight work discards its result instead
    // of calling setState/Navigator after this State is gone.
    _requestId++;
    _focusTimer?.cancel();
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
      final landmarkResult = await VisionService.detectLandmark(base64Image);

      // Check again — the network call may have outlived the request's
      // relevance (user navigated away, fired another capture, etc).
      if (myRequestId != _requestId || !mounted) return;

      if (!landmarkResult.isDetected) {
        debugPrint(
            'ℹ️ No landmark detected — suppressing ResultPage navigation.');
        setState(() {
          _loading = false;
          _previewBytes = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'No recognizable landmark detected. Keep the landmark clearly visible and try again.',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

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
        const SnackBar(
            content: Text('Failed to take picture, please try again')),
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
        _previewBytes = rawBytes; // 立刻冻结画面
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

  Future<void> _onTapToFocus(
    TapDownDetails details,
    BoxConstraints constraints,
  ) async {
    if (_loading || !_isCameraReady || _cameraController == null) return;
    final controller = _cameraController!;

    final viewportWidth = constraints.maxWidth;
    final viewportHeight = constraints.maxHeight;
    if (viewportWidth <= 0 || viewportHeight <= 0) return;

    var cameraAspectRatio = controller.value.aspectRatio;
    if (cameraAspectRatio <= 0) return;
    if (cameraAspectRatio > 1) {
      cameraAspectRatio = 1 / cameraAspectRatio;
    }

    final sourceWidth = viewportWidth;
    final sourceHeight = viewportWidth / cameraAspectRatio;
    if (sourceHeight <= 0) return;

    final scale = math.max(
      viewportWidth / sourceWidth,
      viewportHeight / sourceHeight,
    );

    final renderedWidth = sourceWidth * scale;
    final renderedHeight = sourceHeight * scale;

    final offsetX = (viewportWidth - renderedWidth) / 2.0;
    final offsetY = (viewportHeight - renderedHeight) / 2.0;

    final localPos = details.localPosition;
    final normalizedX =
        ((localPos.dx - offsetX) / renderedWidth).clamp(0.0, 1.0);
    final normalizedY =
        ((localPos.dy - offsetY) / renderedHeight).clamp(0.0, 1.0);

    setState(() {
      _focusPoint = localPos;
      _showFocusIndicator = true;
    });

    _focusTimer?.cancel();
    _focusTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) {
        setState(() => _showFocusIndicator = false);
      }
    });

    try {
      await controller.setFocusPoint(Offset(normalizedX, normalizedY));
    } catch (_) {}

    try {
      await controller.setExposurePoint(Offset(normalizedX, normalizedY));
    } catch (_) {}
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
    if (_cameraState == LandmarkCameraState.ready &&
        _cameraController != null) {
      if (_previewBytes != null) {
        final mediaQuery = MediaQuery.of(context);
        final targetCacheWidth =
            (mediaQuery.size.width * mediaQuery.devicePixelRatio)
                .round()
                .clamp(800, 2400);

        return Image.memory(
          _previewBytes!,
          fit: BoxFit.cover,
          cacheWidth: targetCacheWidth,
        );
      }

      final controller = _cameraController!;
      final size = MediaQuery.sizeOf(context);
      var cameraAspectRatio = controller.value.aspectRatio;
      if (cameraAspectRatio > 1) {
        cameraAspectRatio = 1 / cameraAspectRatio;
      }

      return LayoutBuilder(
        builder: (context, constraints) {
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) => _onTapToFocus(details, constraints),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRect(
                  child: SizedBox.expand(
                    child: FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox(
                        width: size.width,
                        height: size.width / cameraAspectRatio,
                        child: CameraPreview(controller),
                      ),
                    ),
                  ),
                ),
                if (_showFocusIndicator && _focusPoint != null)
                  Positioned(
                    left: _focusPoint!.dx - 30,
                    top: _focusPoint!.dy - 30,
                    child: IgnorePointer(
                      child: Container(
                        width: 60,
                        height: 60,
                        decoration: BoxDecoration(
                          shape: BoxShape.rectangle,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Colors.amberAccent.withOpacity(0.9),
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      );
    }

    if (_cameraState == LandmarkCameraState.noCamera) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.no_photography_outlined,
                    color: Colors.white70, size: 32),
              ),
              const SizedBox(height: 18),
              const Text(
                'No Camera Available',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'No camera sensor was detected on this device. You can recognise landmarks by choosing an image from your gallery.',
                style:
                    TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () => _pickImage(ImageSource.gallery),
                icon: const Icon(Icons.photo_library,
                    size: 16, color: Colors.white),
                label: const Text('Choose from Gallery',
                    style: TextStyle(color: Colors.white)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF7C4DFF),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_cameraState == LandmarkCameraState.permissionPermanentlyDenied) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.camera_alt_outlined,
                    color: Colors.white70, size: 32),
              ),
              const SizedBox(height: 18),
              const Text(
                'Camera Permission Denied',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'Camera permission is permanently denied. Please enable camera access in App Settings, or select a photo from your gallery.',
                style:
                    TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _pickImage(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library,
                        size: 16, color: Colors.white),
                    label: const Text('Gallery',
                        style: TextStyle(color: Colors.white)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.white38),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    onPressed: () async {
                      _waitingForCameraSettingsReturn = true;
                      await Geolocator.openAppSettings();
                    },
                    icon: const Icon(Icons.settings,
                        size: 16, color: Colors.white),
                    label: const Text('Open Settings',
                        style: TextStyle(color: Colors.white)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF7C4DFF),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    if (_cameraState == LandmarkCameraState.permissionDenied ||
        _cameraState == LandmarkCameraState.initializationFailed) {
      final isDenied = _cameraState == LandmarkCameraState.permissionDenied;
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isDenied
                      ? Icons.camera_alt_outlined
                      : Icons.error_outline_rounded,
                  color: Colors.white70,
                  size: 32,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                isDenied ? 'Camera Access Required' : 'Camera Unavailable',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                isDenied
                    ? 'Camera access is needed to photograph landmarks. You can try again or choose from your gallery.'
                    : 'The camera could not be started. Please try again or select a photo from your gallery.',
                style: const TextStyle(
                    color: Colors.white70, fontSize: 13, height: 1.4),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _pickImage(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library,
                        size: 16, color: Colors.white),
                    label: const Text('Gallery',
                        style: TextStyle(color: Colors.white)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.white38),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    onPressed: () {
                      _initCamera();
                    },
                    icon: const Icon(Icons.refresh_rounded,
                        size: 16, color: Colors.white),
                    label: const Text('Try Again',
                        style: TextStyle(color: Colors.white)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF7C4DFF),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return const Center(child: TravelLoadingIndicator());
  }

  Widget _buildTopGradient() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
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
                      left: 0,
                      right: 0,
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
      bottom: 50,
      left: 30,
      right: 30,
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
                icon: const Icon(Icons.photo_library,
                    color: Colors.white, size: 28),
                onPressed:
                    _loading ? null : () => _pickImage(ImageSource.gallery),
              ),
              GestureDetector(
                onTap: _loading ? null : _scanWithCamera,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(
                    color: Colors.white30,
                    shape: BoxShape.circle,
                  ),
                  child: Container(
                    height: 60,
                    width: 60,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                    child: _loading
                        ? const Padding(
                            padding: EdgeInsets.all(15),
                            child: TravelLoadingIndicator(
                                size: 22, color: Colors.black),
                          )
                        : const Icon(Icons.camera_alt,
                            color: Colors.black, size: 30),
                  ),
                ),
              ),
              IconButton(
                icon: Icon(
                  _isFlashOn ? Icons.flash_on : Icons.flash_off,
                  color: Colors.white,
                  size: 28,
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
      Positioned(
          top: 0, left: 0, child: _corner(showTop: true, showLeft: true)),
      Positioned(
          top: 0, right: 0, child: _corner(showTop: true, showRight: true)),
      Positioned(
          bottom: 0, left: 0, child: _corner(showBottom: true, showLeft: true)),
      Positioned(
          bottom: 0,
          right: 0,
          child: _corner(showBottom: true, showRight: true)),
    ];
  }

  Widget _corner({
    bool showTop = false,
    bool showBottom = false,
    bool showLeft = false,
    bool showRight = false,
  }) {
    return Container(
      width: 25,
      height: 25,
      decoration: BoxDecoration(
        border: Border(
          top: showTop
              ? const BorderSide(color: Colors.white, width: 4)
              : BorderSide.none,
          bottom: showBottom
              ? const BorderSide(color: Colors.white, width: 4)
              : BorderSide.none,
          left: showLeft
              ? const BorderSide(color: Colors.white, width: 4)
              : BorderSide.none,
          right: showRight
              ? const BorderSide(color: Colors.white, width: 4)
              : BorderSide.none,
        ),
      ),
    );
  }
}
