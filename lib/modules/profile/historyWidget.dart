// historyWidget.dart
import 'package:flutter/material.dart';

class historyWidget extends StatelessWidget {
  const historyWidget({super.key});

  @override
  Widget build(BuildContext context) {
    // Hardcode 数据
    final List<Map<String, String>> travelData = [
      {
        "name": "Moraine Lake",
        "date": "Tuesday 16",
        "desc": "One of the many wonderful turquoise lakes in Alberta.",
      },
      {
        "name": "Niagara Falls",
        "date": "Wednesday 17",
        "desc": "Probably the most popular natural landmark in Canada.",
      },
      {
        "name": "Baffin Island",
        "date": "Thursday 18",
        "desc": "Canada's largest island (5th in the world) is located in Nunavut.",
      },
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 25.0),
      child: Column(
        children: travelData.map((data) {
          bool isLast = travelData.indexOf(data) == travelData.length - 1;
          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 左侧时间轴
                Column(
                  children: [
                    Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        border: Border.all(color: const Color(0xFF4DB6AC), width: 3.5),
                        shape: BoxShape.circle,
                        color: Colors.white,
                      ),
                    ),
                    if (!isLast)
                      Expanded(
                        child: Container(
                          width: 2,
                          color: const Color(0xFF4DB6AC).withOpacity(0.3),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 15),
                // 右侧文字内容
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 30.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(data['name']!, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        Text(data['date']!, style: const TextStyle(color: Colors.grey, fontSize: 13)),
                        const SizedBox(height: 6),
                        Text(data['desc']!, style: const TextStyle(color: Colors.black54, height: 1.3)),
                      ],
                    ),
                  ),
                ),
                // 右侧图片占位
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    width: 70,
                    height: 70,
                    color: Colors.grey.shade200,
                    child: const Icon(Icons.image, color: Colors.grey),
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}