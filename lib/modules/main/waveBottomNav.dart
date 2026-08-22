import 'package:flutter/material.dart';

class NavItemData {
  final IconData icon;
  final String label;
  const NavItemData(this.icon, this.label);
}

class WaveBottomNav extends StatelessWidget {
  final int currentIndex;          // 0..items.length-1
  final List<NavItemData> items;
  final ValueChanged<int> onTap;
  final Color activeColor;
  final Color inactiveColor;

  const WaveBottomNav({
    super.key,
    required this.currentIndex,
    required this.items,
    required this.onTap,
    this.activeColor = const Color(0xFF6366F1),
    this.inactiveColor = const Color(0xFFB0B8C1),
  });

  static const double _barHeight = 64;
  static const double _dipDepth  = 26;
  static const double _bubbleSize = 54;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width     = constraints.maxWidth;
        final itemWidth = width / items.length;

        return SizedBox(
          height: _barHeight + 30, // 多留一点高度让 bubble 浮出去
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.bottomCenter,
            children: [
              // ── 波浪底 ──
              TweenAnimationBuilder<double>(
                tween: Tween<double>(
                  begin: itemWidth * currentIndex + itemWidth / 2,
                  end:   itemWidth * currentIndex + itemWidth / 2,
                ),
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeOutCubic,
                builder: (context, dipX, _) {
                  return CustomPaint(
                    size: Size(width, _barHeight),
                    painter: _WavePainter(
                      dipX: dipX,
                      dipHalfWidth: itemWidth * 0.42,
                      dipDepth: _dipDepth,
                    ),
                  );
                },
              ),

              // ── 未选中图标（沉在波浪下方）──
              Positioned(
                bottom: 0, left: 0, right: 0,
                height: _barHeight,
                child: Row(
                  children: List.generate(items.length, (i) {
                    final selected = i == currentIndex;
                    return Expanded(
                      child: InkWell(
                        onTap: () => onTap(i),
                        splashColor: activeColor.withOpacity(0.08),
                        highlightColor: activeColor.withOpacity(0.05),
                        child: selected
                            ? const SizedBox.shrink() // 选中的交给浮动 bubble 显示
                            : Padding(
                                padding: const EdgeInsets.only(top: 18),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(items[i].icon, size: 22, color: inactiveColor),
                                    const SizedBox(height: 3),
                                    Text(items[i].label,
                                        style: TextStyle(fontSize: 10, color: inactiveColor)),
                                  ],
                                ),
                              ),
                      ),
                    );
                  }),
                ),
              ),

              // ── 浮动气泡（选中项）──
              AnimatedPositioned(
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeOutCubic,
                left: itemWidth * currentIndex + itemWidth / 2 - _bubbleSize / 2,
                bottom: _barHeight - _dipDepth - 6,
                child: GestureDetector(
                  onTap: () => onTap(currentIndex),
                  child: Column(
                    children: [
                      Container(
                        width: _bubbleSize, height: _bubbleSize,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            colors: [activeColor, activeColor.withOpacity(0.8)],
                            begin: Alignment.topLeft, end: Alignment.bottomRight,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: activeColor.withOpacity(0.4),
                              blurRadius: 14, offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: Icon(items[currentIndex].icon, color: Colors.white, size: 26),
                      ),
                      const SizedBox(height: 4),
                      Text(items[currentIndex].label,
                          style: TextStyle(
                              fontSize: 10, fontWeight: FontWeight.w700, color: activeColor)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _WavePainter extends CustomPainter {
  final double dipX;
  final double dipHalfWidth;
  final double dipDepth;

  _WavePainter({required this.dipX, required this.dipHalfWidth, required this.dipDepth});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final path = Path()
      ..moveTo(0, 14)
      ..quadraticBezierTo(0, 0, 14, 0)
      ..lineTo(dipX - dipHalfWidth, 0)
      ..cubicTo(
        dipX - dipHalfWidth * 0.5, 0,
        dipX - dipHalfWidth * 0.5, dipDepth,
        dipX, dipDepth,
      )
      ..cubicTo(
        dipX + dipHalfWidth * 0.5, dipDepth,
        dipX + dipHalfWidth * 0.5, 0,
        dipX + dipHalfWidth, 0,
      )
      ..lineTo(w - 14, 0)
      ..quadraticBezierTo(w, 0, w, 14)
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();

    canvas.drawShadow(path, Colors.black.withOpacity(0.15), 6, false);
    canvas.drawPath(path, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) =>
      old.dipX != dipX || old.dipHalfWidth != dipHalfWidth || old.dipDepth != dipDepth;
}