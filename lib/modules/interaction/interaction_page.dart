import 'package:flutter/material.dart';

class InteractionPage extends StatelessWidget {
  const InteractionPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('User Interaction')),
      body: const Center(
        child: Text(
          'User Posts / Reviews',
          style: TextStyle(fontSize: 18),
        ),
      ),
    );
  }
}
