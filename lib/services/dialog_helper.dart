import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

/// 项目里统一风格的弹窗集合。
/// 圆角 Dialog + 图标 + 左对齐标题,配色跟随主色 0xFF7C4DFF。
class AppDialogs {
  AppDialogs._();

  /// 通用的"图标 + 标题 + 说明 + Cancel/Action"弹窗骨架。
  static Future<void> _show({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String message,
    required String actionLabel,
    required VoidCallback onAction,
    bool barrierDismissible = true,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (dialogContext) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 32),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48, height: 48,
                decoration: BoxDecoration(
                  color: const Color(0xFF7C4DFF).withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: const Color(0xFF7C4DFF)),
              ),
              const SizedBox(height: 16),
              Text(title,
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(
                message,
                style: TextStyle(
                    fontSize: 14, color: Colors.grey[600], height: 1.4),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: Text('Cancel',
                        style: TextStyle(color: Colors.grey[500])),
                  ),
                  const SizedBox(width: 4),
                  TextButton(
                    onPressed: () {
                      Navigator.pop(dialogContext);
                      onAction();
                    },
                    child: Text(actionLabel,
                        style: const TextStyle(
                            color: Color(0xFF7C4DFF),
                            fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 系统定位服务关闭时用——固定跳系统定位设置。
  static Future<void> showLocationServiceDisabled(BuildContext context) {
    return _show(
      context: context,
      icon: Icons.location_off_rounded,
      title: 'Location Disabled',
      message: 'Please enable location services to see nearby places.',
      actionLabel: 'Open Settings',
      onAction: () => Geolocator.openLocationSettings(),
    );
  }

  /// 定位服务开着,但 App 没拿到权限,或者拿不到坐标时用——
  /// 会自动判断该跳系统定位设置还是 App 权限设置。
  static Future<void> showLocationUnavailable(BuildContext context) async {
    return _show(
      context: context,
      icon: Icons.location_off_rounded,
      title: 'Location Disabled',
      message: 'Please enable location services to see nearby places.',
      actionLabel: 'Open Settings',
      onAction: () async {
        final serviceEnabled = await Geolocator.isLocationServiceEnabled();
        if (!serviceEnabled) {
          await Geolocator.openLocationSettings();
        } else {
          await Geolocator.openAppSettings();
        }
      },
    );
  }
}