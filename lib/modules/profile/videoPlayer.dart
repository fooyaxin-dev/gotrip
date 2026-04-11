// video_player_widget.dart
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'dart:io';

class LocalVideoPlayer extends StatefulWidget {
  final String path;
  final bool autoPlay;

  const LocalVideoPlayer({
    super.key,
    required this.path,
    this.autoPlay = false,
  });

  @override
  State<LocalVideoPlayer> createState() => _LocalVideoPlayerState();
}

class _LocalVideoPlayerState extends State<LocalVideoPlayer> {
  late VideoPlayerController _controller;
  bool _initialized = false;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.path))
      ..initialize().then((_) {
        if (mounted) {
          setState(() => _initialized = true);
          if (widget.autoPlay) {
            _controller.play();
            _isPlaying = true;
          }
        }
      });

    _controller.addListener(() {
      if (mounted) setState(() => _isPlaying = _controller.value.isPlaying);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return Container(
        color: Colors.grey[900],
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white70),
        ),
      );
    }

    return GestureDetector(
      onTap: () {
        setState(() {
          if (_controller.value.isPlaying) {
            _controller.pause();
          } else {
            _controller.play();
          }
        });
      },
      child: Stack(fit: StackFit.expand, children: [
        FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: _controller.value.size.width,
            height: _controller.value.size.height,
            child: VideoPlayer(_controller),
          ),
        ),
        // 暂停时显示播放按钮
        if (!_isPlaying)
          Container(
            color: Colors.black.withOpacity(0.3),
            child: const Center(
              child: Icon(Icons.play_circle_fill,
                  color: Colors.white70, size: 56),
            ),
          ),
        // 进度条
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: VideoProgressIndicator(
            _controller,
            allowScrubbing: true,
            colors: const VideoProgressColors(
              playedColor: Color(0xFFD35D3E),
              bufferedColor: Colors.white38,
              backgroundColor: Colors.white12,
            ),
          ),
        ),
      ]),
    );
  }
}