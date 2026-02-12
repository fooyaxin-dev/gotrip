import 'package:flutter/material.dart';

class barSwap extends StatefulWidget {
  const barSwap({super.key});

  @override
  State<barSwap> createState() => _barSwapdState();
}

class _barSwapdState extends State<barSwap> {

  Alignment _alignment = Alignment.centerLeft;

  void _moveContainer(){
    setState(() {
      _alignment = Alignment.centerRight;
    });
  }

  void _moveContainer1(){
    setState(() {
      _alignment = Alignment.centerLeft;
    });
  }


  @override
  Widget build(BuildContext context) {
    var width = MediaQuery.of(context).size.width;
    return Padding(
      padding: const EdgeInsets.only(left:25, right:25),
      child: Stack(
        alignment: _alignment,
        children: [
          InkWell(
            onTap: _moveContainer1,
            child: Container(
              margin: EdgeInsets.only(left: 10),
              height: 65,
              width: width,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),

          InkWell(
            onTap: _moveContainer,
            child: Padding(
              padding: const EdgeInsets.only(right:5.0),
              child: Container(
                margin: EdgeInsets.only(left:5),
                height: 50,
                width: width / 2 -20,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            ),
          ),

          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [

              Padding(
                padding: EdgeInsets.only(right:25),
                child: Text('Post', style: TextStyle(fontSize: 17,),),
              ),

              Padding(
                padding: EdgeInsets.only(left:25),
                child: Text('History', style: TextStyle(fontSize: 17,),),
              ),


            ],
            

          ),

          
        ],
         
      ),
    );
  }
}