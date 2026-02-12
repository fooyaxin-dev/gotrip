import 'dart:ui';

import 'package:flutter/material.dart';
import 'barSwap.dart';
import 'postWidget.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {

  bool showProfile = true;

  void zoomProfile(){
    setState(() {
      showProfile = !showProfile;
    });
  }


  @override
  Widget build(BuildContext context) {

    var height = MediaQuery.of(context).size.height;

    return SafeArea(
      child: Scaffold(
        body: showProfile ?  Stack(
          children: [
            
            //1
            Image.asset('assets/images/profile.jpg', fit: BoxFit.cover, height:200,),
            Container(
              decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.transparent, Colors.white],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0, .2]
                  )
              ),
            ),
            
            //2
            Center(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                
                    SizedBox(height: height * 0.13),
                
                    CircleAvatar(
                      backgroundColor: Colors.orange,
                      radius: 47,
                      child: CircleAvatar(
                        backgroundColor: Colors.white,
                        radius: 45,
                        child: InkWell(
                          onTap: zoomProfile ,
                          child: const CircleAvatar(
                            radius: 43,
                            backgroundImage: AssetImage('asset/images/profile.jpg'),
                                          
                          ),
                        ),
                      ),
                    ),
                
                    SizedBox(height: height * 0.02),
                
                    const Text('YAXIN', 
                      style: TextStyle(
                      fontSize: 23,
                      fontWeight: FontWeight.bold,
                      ),
                    ),
                
                    const Text('@YAxin', 
                      style: TextStyle(
                      fontSize: 16,
                      color: Colors.grey,
                      ),
                    ),
                
                    Padding(
                      padding: const EdgeInsets.only(left: 30.0, right: 30.0, top:10),
                      child: Text('Bio', 
                        style: TextStyle(
                        fontSize: 15,
                        color: Colors.grey.shade400,
                        ),
                      ),
                    ),
                
                    SizedBox(height: height * 0.05),
                
                    _totalPostwithHistory(),
                
                    SizedBox(height: height * 0.03),
                    barSwap(),
                
                    SizedBox(height: height * 0.02),
                    postWidget(),
                
                
                
                  ],
                ),
              )
            )
          ], 
        )  ////NEXT

        : InkWell(
          onTap: zoomProfile,
          child: Stack(
            children: [
              
              //1
              Image.asset('asset/images/profile.jpg', fit: BoxFit.cover, height:200,),
              Container(
                decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Colors.transparent, Colors.white],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: [0, .2]
                    )
                ),
              ),
              
              //2
              Center(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                  
                      SizedBox(height: height * 0.13),
                  
                      const CircleAvatar(
                        backgroundColor: Colors.orange,
                        radius: 47,
                        child: CircleAvatar(
                          backgroundColor: Colors.white,
                          radius: 45,
                          child: CircleAvatar(
                            radius: 43,
                            backgroundImage: AssetImage('asset/images/profile.jpg'),
                  
                          ),
                        ),
                      ),
                  
                      SizedBox(height: height * 0.02),
                  
                      const Text('YAXIN', 
                        style: TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.bold,
                        ),
                      ),
                  
                      const Text('@YAxin', 
                        style: TextStyle(
                        fontSize: 16,
                        color: Colors.grey,
                        ),
                      ),
                  
                      Padding(
                        padding: const EdgeInsets.only(left: 30.0, right: 30.0, top:10),
                        child: Text('Bio', 
                          style: TextStyle(
                          fontSize: 15,
                          color: Colors.grey.shade400,
                          ),
                        ),
                      ),
                  
                      SizedBox(height: height * 0.05),
                  
                      _totalPostwithHistory(),
                  
                      SizedBox(height: height * 0.03),
                      barSwap(),
                  
                      SizedBox(height: height * 0.02),
                      postWidget(),
                    ],
                  ),
                )
              ),
          
              BackdropFilter(

                filter: ImageFilter.blur(
                  sigmaX:10,
                  sigmaY:10
                ),

                child: Container(
                  height:height,
                  color: Colors.white.withOpacity(0.3),
                  child: const Center(
                    child: CircleAvatar(
                      radius: 120,
                      backgroundImage: AssetImage('asset/images/profile,jpg',  ),
                    ),
                  ),
                ),
              )
          
          
          
          
          
            ],
          ),
        )
      ),
    );
  }
}

  Widget _totalPostwithHistory() {

    return const Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        Column(
          children: [
            Text('Post' , style: TextStyle(
              fontSize: 15,
              color: Colors.grey,
              ),
            ),

              Padding(
                padding: EdgeInsets.only(top: 6.0),
                child: Text('5' , style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
                ),
               ),
              ),
          ],
        ),

        Column(
          children: [
            Text('Favourite' , style: TextStyle(
              fontSize: 15,
              color: Colors.grey,
              ),
            ),

              Padding(
                padding: EdgeInsets.only(top: 6.0),
                child: Text('5' , style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
                ),
               ),
              ),
          ],
        ),

        Column(
          children: [
            Text('Route' , style: TextStyle(
              fontSize: 15,
              color: Colors.grey,
              ),
            ),

              Padding(
                padding: EdgeInsets.only(top: 6.0),
                child: Text('5' , style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
                ),
               ),
              ),
          ],
        )
      ],
    );
  }

