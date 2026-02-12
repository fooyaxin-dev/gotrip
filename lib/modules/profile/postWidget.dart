import 'package:flutter/material.dart';

class postWidget extends StatefulWidget {
  const postWidget({super.key});

  @override
  State<postWidget> createState() => _postWidgetState();
}

class _postWidgetState extends State<postWidget> {

    List<String> imgs = [
      "assets/images/image1.jpg",
      "assets/images/image2.jpg"
    ];


  @override


  Widget build(BuildContext context) {
    return SizedBox(
      height: 300,
      child: GridView.builder(

        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, ),

        itemBuilder: (context, index) {
          return Padding(
            padding: const EdgeInsets.all(8.0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Image.asset(imgs[index] , fit: BoxFit.cover,)
            ),
          );
        },

        itemCount: imgs.length,

      )
    );
  }
}