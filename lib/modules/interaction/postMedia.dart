// widgets/post_media_widgets.dart
//
// 统一的帖子图片渲染函数：自动判断 source 是网络 URL（新帖子，
// 上传到 Firebase Storage 后存的是 https://...）还是本地文件路径
// （旧帖子，在 Storage 迁移之前发的，仍然是手机本地路径）。
//
// 这样旧帖子不会因为这次改动而全部失效 —— 在发帖者自己手机上
// 依然能正常显示（Image.file），只是别人依然看不到（这是旧数据
// 本身的限制，除非做一次性迁移脚本重新上传）。
// 新发的帖子则所有人都能看到（Image.network）。
//
// 用法：把原来所有 Image.file(File(path), ...) 的地方
// 换成 buildPostImage(path, ...)

import 'dart:io';
import 'package:flutter/material.dart';

Widget buildPostImage(
  String source, {
  double? width,
  double? height,
  BoxFit fit = BoxFit.cover,
  Widget Function(BuildContext, Object, StackTrace?)? errorBuilder,
}) {
  final isNetwork = source.startsWith('http');

  Widget fallback(BuildContext context, Object error, StackTrace? stack) {
    if (errorBuilder != null) return errorBuilder(context, error, stack);
    return Container(
      width: width,
      height: height,
      color: Colors.grey[300],
      child: const Icon(Icons.broken_image, color: Colors.grey),
    );
  }

  if (isNetwork) {
    return Image.network(
      source,
      width: width,
      height: height,
      fit: fit,
      errorBuilder: fallback,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return Container(
          width: width,
          height: height,
          color: Colors.grey[100],
          child: const Center(
            child: SizedBox(
              width: 20, height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        );
      },
    );
  }

  return Image.file(
    File(source),
    width: width,
    height: height,
    fit: fit,
    errorBuilder: fallback,
  );
}

/// 供 Post model 判断某张图是否已经是云端 URL（供 UI 显示小角标等用）
bool isNetworkMediaUrl(String source) => source.startsWith('http');