import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'login.dart';
import '../main/homepage.dart';

class SignupPage extends StatefulWidget {
  const SignupPage({super.key});

  @override
  State<SignupPage> createState() => _SignupPageState();
}

class _SignupPageState extends State<SignupPage> {
  final _formKey = GlobalKey<FormState>();

  final TextEditingController usernameController = TextEditingController();
  final TextEditingController emailController = TextEditingController();
  final TextEditingController pwdController = TextEditingController();
  final TextEditingController repwdController = TextEditingController();

  bool isLoading = false;

  @override
  void dispose() {
    usernameController.dispose();
    emailController.dispose();
    pwdController.dispose();
    repwdController.dispose();
    super.dispose();
  }

  // ================= Username check =================
  Future<bool> isUsernameTaken(String username) async {
    final query = await FirebaseFirestore.instance
        .collection('users')
        .where('username', isEqualTo: username)
        .get();

    return query.docs.isNotEmpty;
  }

  // ================= Signup Logic (全部在这里) =================
  Future<void> createUserWithEmailAndPassword() async {
    if (!_formKey.currentState!.validate()) return;

    final username = usernameController.text.trim();
    final email = emailController.text.trim();
    final password = pwdController.text.trim();

    setState(() => isLoading = true);

    // check username
    if (await isUsernameTaken(username)) {
      _showError('Username already taken');
      setState(() => isLoading = false);
      return;
    }

    try {
      UserCredential userCredential =
          await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      final uid = userCredential.user!.uid;

      // save user info in Firestore
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'email': email,
        'username': username,
      });

      /// ✅ 直接跳 HomePage
      if (mounted) {
        Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const HomePage()),
        );
      }
    } on FirebaseAuthException catch (e) {
      String message;

      switch (e.code) {
        case 'email-already-in-use':
          message = 'This email is already registered';
          break;
        case 'invalid-email':
          message = 'Invalid email format';
          break;
        case 'weak-password':
          message = 'Password is too weak';
          break;
        case 'network-request-failed':
          message = 'Network error. Please try again';
          break;
        default:
          message = 'Signup failed. Please try again';
      }

      _showError(message);
    } catch (_) {
      _showError('Something went wrong');
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.indigoAccent,
      ),
    );
  }

  // ================= UI =================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SingleChildScrollView(
        child: SafeArea(
          child: Form(
            key: _formKey,
            child: Column(
              children: [
                // ===== Header =====
                Container(
                  height: 250,
                  width: double.infinity,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Color(0xFF5E35B1), Color(0xFF7C4DFF)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.only(
                      bottomLeft: Radius.circular(35),
                      bottomRight: Radius.circular(35),
                    ),
                  ),
                  child: const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircleAvatar(
                          radius: 40,
                          backgroundColor: Colors.white,
                          child: Icon(
                            Icons.person_add,
                            size: 40,
                            color: Color(0xFF7C4DFF),
                          ),
                        ),
                        SizedBox(height: 15),
                        Text(
                          'Create Account',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 5),
                        Text(
                          'Join us and start exploring',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 25),

                // ===== Username =====
                _inputField(
                  controller: usernameController,
                  icon: Icons.person,
                  hint: 'Enter your username',
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Username is required';
                    }
                    if (value.contains('@')) {
                      return 'Username cannot contain @';
                    }
                    if (value.length < 3) {
                      return 'Username must be at least 3 characters';
                    }
                    return null;
                  },
                ),

                const SizedBox(height: 15),

                // ===== Email =====
                _inputField(
                  controller: emailController,
                  icon: Icons.email,
                  hint: 'Enter your email',
                  keyboardType: TextInputType.emailAddress,
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Email is required';
                    }
                    if (!value.contains('@')) {
                      return 'Invalid email';
                    }
                    return null;
                  },
                ),

                const SizedBox(height: 15),

                // ===== Password =====
                _inputField(
                  controller: pwdController,
                  icon: Icons.lock,
                  hint: 'Enter your password',
                  obscure: true,
                  validator: (value) {
                    if (value == null || value.length < 6) {
                      return 'Password must be at least 6 characters';
                    }
                    return null;
                  },
                ),

                const SizedBox(height: 15),

                // ===== Re-password =====
                _inputField(
                  controller: repwdController,
                  icon: Icons.lock_outline,
                  hint: 'Re-enter your password',
                  obscure: true,
                  validator: (value) {
                    if (value != pwdController.text) {
                      return 'Passwords do not match';
                    }
                    return null;
                  },
                ),

                const SizedBox(height: 20),

                // ===== Sign Up Button =====
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 25),
                  child: SizedBox(
                    height: 55,
                    child: ElevatedButton(
                      onPressed:
                          isLoading ? null : createUserWithEmailAndPassword,
                     style: ElevatedButton.styleFrom(
                        padding: EdgeInsets.zero,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 10,
                        shadowColor: Colors.purple.withOpacity(0.4),
                        backgroundColor: Colors.transparent,
                      ),
                      child: Ink(
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF5E35B1), Color(0xFF7C4DFF)],
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Container(
                          alignment: Alignment.center,
                          child: isLoading
                              ? const SizedBox(
                                  height: 22,
                                  width: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text(
                                  'Sign Up',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 40),

                // ===== Go to Login =====
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('Already have an account? '),
                    GestureDetector(
                      onTap: () {
                        Navigator.pushReplacement(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const LoginPage(),
                          ),
                        );
                      },
                      child: const Text(
                        'Login',
                        style: TextStyle(
                          color: Color(0xFF7C4DFF),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 30),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ================= Reusable Widgets =================
  Widget _inputField({
    required TextEditingController controller,
    required IconData icon,
    required String hint,
    bool obscure = false,
    TextInputType keyboardType = TextInputType.text,
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 25),
      child: Container(
        padding: const EdgeInsets.only(left: 15),
        decoration: _inputDecoration(),
        child: TextFormField(
          controller: controller,
          obscureText: obscure,
          keyboardType: keyboardType,
          validator: validator,
          decoration: InputDecoration(
            icon: Icon(icon),
            hintText: hint,
            border: InputBorder.none,
          ),
        ),
      ),
    );
  }

  BoxDecoration _inputDecoration() {
    return BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      boxShadow: [
        BoxShadow(
          color: Colors.grey.withOpacity(0.25),
          blurRadius: 8,
          offset: const Offset(0, 4),
        ),
      ],
    );
  }
}