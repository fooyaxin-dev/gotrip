import 'package:flutter/material.dart';

class GuidePage extends StatelessWidget {
  const GuidePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Smart Guide')),
      body: const Center(
        child: Text(
          'Real-time Location & Nearby Places',
          style: TextStyle(fontSize: 18),
        ),
      ),
    );
  }
}
