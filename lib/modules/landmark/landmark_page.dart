import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'vision_service.dart';

class LandmarkPage extends StatefulWidget {
  const LandmarkPage({super.key});

  @override
  State<LandmarkPage> createState() => _LandmarkPageState();
}

class _LandmarkPageState extends State<LandmarkPage> {
  File? _imageFile;
  String _result = 'No result yet';
  String _rawJson = '';
  bool _loading = false;

  final ImagePicker _picker = ImagePicker();

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? pickedFile = await _picker.pickImage(source: source);
      if (pickedFile == null) return;

      setState(() {
        _imageFile = File(pickedFile.path);
        _result = 'Processing...';
        _rawJson = '';
        _loading = true;
      });

      final bytes = await File(pickedFile.path).readAsBytes();
      final base64Image = base64Encode(bytes);

      final response = await VisionService.detectLandmarkWithJson(base64Image);

      setState(() {
        _loading = false;
        _rawJson = response['rawJson'] ?? '';
        _result = response['landmark'] ?? 'No landmark detected';
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _result = 'Error: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Landmark Recognition')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            if (_imageFile != null)
              Image.file(
                _imageFile!,
                width: 250,
                height: 250,
                fit: BoxFit.cover,
              ),
            const SizedBox(height: 16),
            _loading
                ? const CircularProgressIndicator()
                : Text(
                    _result,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 18),
                  ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () => _pickImage(ImageSource.camera),
              icon: const Icon(Icons.camera_alt),
              label: const Text('Take Photo'),
            ),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              onPressed: () => _pickImage(ImageSource.gallery),
              icon: const Icon(Icons.photo),
              label: const Text('Pick from Gallery'),
            ),
            const SizedBox(height: 20),
            if (_rawJson.isNotEmpty)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Raw JSON Response:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _rawJson,
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
