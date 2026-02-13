import 'package:flutter/material.dart';

class BarSwap extends StatefulWidget {
  final Function(int)? onTabChanged; // 可选的回调函数，返回选中的索引
  
  const BarSwap({super.key, this.onTabChanged});

  @override
  State<BarSwap> createState() => _BarSwapState();
}

class _BarSwapState extends State<BarSwap> {
  int _selectedIndex = 0; // 0 = Post, 1 = History

  void _switchTab(int index) {
    if (_selectedIndex != index) {
      setState(() {
        _selectedIndex = index;
      });
      widget.onTabChanged?.call(index); // 触发回调
    }
  }

  @override
  Widget build(BuildContext context) {
    var width = MediaQuery.of(context).size.width;
    var tabWidth = (width - 90) / 2; // 减去左右padding和间距

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 25),
      child: Container(
        height: 55,
        decoration: BoxDecoration(
          color: Colors.grey.shade300,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Stack(
          children: [
            // 动画滑块
            AnimatedAlign(
              alignment: _selectedIndex == 0 
                  ? Alignment.centerLeft 
                  : Alignment.centerRight,
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeInOut,
              child: Container(
                margin: const EdgeInsets.all(7.5),
                height: 50,
                width: tabWidth,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(15),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
              ),
            ),

            // 可点击的文字区域
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => _switchTab(0),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      alignment: Alignment.center,
                      child: Text(
                        'Post',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: _selectedIndex == 0 
                              ? FontWeight.w600 
                              : FontWeight.normal,
                          color: _selectedIndex == 0 
                              ? Colors.black 
                              : Colors.grey.shade600,
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: GestureDetector(
                    onTap: () => _switchTab(1),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      alignment: Alignment.center,
                      child: Text(
                        'History',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: _selectedIndex == 1 
                              ? FontWeight.w600 
                              : FontWeight.normal,
                          color: _selectedIndex == 1 
                              ? Colors.black 
                              : Colors.grey.shade600,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}