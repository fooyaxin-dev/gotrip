import 'package:flutter/material.dart';

class BasePage extends StatelessWidget {
  final Widget child;
  final bool hasScroll;

  const BasePage({
    super.key,
    required this.child,
    this.hasScroll = true,
  });

  @override
  Widget build(BuildContext context) {

    const double bottomPadding = 90;

    if (hasScroll) {
      return SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.only(bottom: bottomPadding),
          child: child,
        ),
      );
    } else {
      return SafeArea(
        bottom: false,
        child: child,
      );
    }
  }
}
