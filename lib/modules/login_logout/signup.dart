import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'login.dart';
import '../../services/apps_Loading.dart';
import '../../services/connectivity_service.dart';

class SignupPage extends StatefulWidget {
  const SignupPage({super.key});

  @override
  State<SignupPage> createState() => _SignupPageState();
}

class _SignupPageState extends State<SignupPage> {
  final _formKey = GlobalKey<FormState>();

  final TextEditingController usernameController = TextEditingController();
  final TextEditingController emailController    = TextEditingController();
  final TextEditingController pwdController      = TextEditingController();
  final TextEditingController repwdController    = TextEditingController();

  bool isLoading     = false;
  bool _pwdVisible   = false;
  bool _repwdVisible = false;

  // ── password rule states ──────────────────────────────────────────────────
  bool _hasMinLength  = false;
  bool _hasUppercase  = false;
  bool _hasLowercase  = false;
  bool _hasDigit      = false;
  bool _hasSpecial    = false;
  bool _showChecklist = false; // only show once user starts typing

  @override
  void initState() {
    super.initState();
    pwdController.addListener(_onPasswordChanged);
  }

  void _onPasswordChanged() {
    final v = pwdController.text;
    setState(() {
      _showChecklist = v.isNotEmpty;
      _hasMinLength  = v.length >= 8;
      _hasUppercase  = v.contains(RegExp(r'[A-Z]'));
      _hasLowercase  = v.contains(RegExp(r'[a-z]'));
      _hasDigit      = v.contains(RegExp(r'[0-9]'));
      _hasSpecial    = v.contains(RegExp(r'[!@#\$&*~%^()\-_=+]'));
    });
  }

  bool get _passwordValid =>
      _hasMinLength && _hasUppercase && _hasLowercase && _hasDigit && _hasSpecial;

  @override
  void dispose() {
    usernameController.dispose();
    emailController.dispose();
    pwdController.dispose();
    repwdController.dispose();
    super.dispose();
  }

  // ── username uniqueness ───────────────────────────────────────────────────
  Future<bool> isUsernameTaken(String username) async {
    final query = await FirebaseFirestore.instance
        .collection('users')
        .where('username', isEqualTo: username)
        .get();
    return query.docs.isNotEmpty;
  }

  // ── signup logic ──────────────────────────────────────────────────────────
  Future<void> createUserWithEmailAndPassword() async {
    if (!_formKey.currentState!.validate()) return;
    if (!_passwordValid) {
      _showError('Please meet all password requirements');
      return;
    }

      // 🆕 注册前先确认有网，没网直接提示，不让转圈卡住
  final online = await ConnectivityService.instance.ensureConnected(
    context,
    onRetry: createUserWithEmailAndPassword,
  );
  if (!online) return;
  

    final username = usernameController.text.trim();
    final email    = emailController.text.trim();
    final password = pwdController.text.trim();

    setState(() => isLoading = true);

    if (await isUsernameTaken(username)) {
      _showError('Username already taken');
      setState(() => isLoading = false);
      return;
    }

    try {
      final userCredential = await FirebaseAuth.instance
          .createUserWithEmailAndPassword(email: email, password: password);

      final uid = userCredential.user!.uid;

      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'email':              email,
        'username':           username,
        'bio':                'Hello! I\'m new here 👋',
        'profileImageUrl':    '',
        'backgroundImageUrl': '',
        'postCount':          0,
        'favouriteCount':     0,
        'routeCount':         0,
        'onboardingDone':     false,
        'preferences': {
          'categories': [],
          'cuisines':   [],
          'travelMode': 'walk',
        },
      });

      // Send email verification
      await userCredential.user!.sendEmailVerification();

      if (mounted) {
        // Show verification notice before navigating
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Row(
              children: [
                Icon(Icons.mark_email_unread_outlined, color: Colors.white),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'A verification email has been sent. Please verify before logging in.',
                  ),
                ),
              ],
            ),
            backgroundColor: Color(0xFF7C4DFF),
            duration: Duration(seconds: 4),
          ),
        );

        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const LoginPage()),
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
      SnackBar(content: Text(message), backgroundColor: Colors.indigoAccent),
    );
  }

  // ── form validator (kept for Form.validate() pass) ────────────────────────
  String? _validatePassword(String? value) {
    if (value == null || value.isEmpty) return 'Password is required';
    // detailed checks are shown in the checklist; just block submit if invalid
    if (!_passwordValid) return 'Please meet all password requirements';
    return null;
  }

  // ── UI ────────────────────────────────────────────────────────────────────
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
                // ── header ──────────────────────────────────────────────────
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
                      bottomLeft:  Radius.circular(35),
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
                          child: Icon(Icons.person_add, size: 40, color: Color(0xFF7C4DFF)),
                        ),
                        SizedBox(height: 15),
                        Text('Create Account',
                            style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                        SizedBox(height: 5),
                        Text('Join us and start exploring',
                            style: TextStyle(color: Colors.white70, fontSize: 14)),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 25),

                // ── username ─────────────────────────────────────────────────
                _inputField(
                  controller: usernameController,
                  icon: Icons.person,
                  hint: 'Enter your username',
                  validator: (value) {
                    if (value == null || value.isEmpty) return 'Username is required';
                    if (value.contains('@'))  return 'Username cannot contain @';
                    if (value.length < 3)     return 'Username must be at least 3 characters';
                    return null;
                  },
                ),

                const SizedBox(height: 15),

                // ── email ────────────────────────────────────────────────────
                _inputField(
                  controller: emailController,
                  icon: Icons.email,
                  hint: 'Enter your email',
                  keyboardType: TextInputType.emailAddress,
                  validator: (value) {
                    if (value == null || value.isEmpty) return 'Email is required';
                    final emailRegex = RegExp(r'^[\w\.-]+@[\w\.-]+\.\w{2,}$');
                    if (!emailRegex.hasMatch(value.trim())) return 'Please enter a valid email';
                    return null;
                  },
                ),

                const SizedBox(height: 15),

                // ── password + live checklist ─────────────────────────────
                _inputField(
                  controller: pwdController,
                  icon: Icons.lock,
                  hint: 'Enter your password',
                  obscure: !_pwdVisible,
                  suffixIcon: IconButton(
                    icon: Icon(_pwdVisible ? Icons.visibility_off : Icons.visibility,
                        color: Colors.grey),
                    onPressed: () => setState(() => _pwdVisible = !_pwdVisible),
                  ),
                  validator: _validatePassword,
                ),

                // ── animated checklist ───────────────────────────────────
                AnimatedCrossFade(
                  duration: const Duration(milliseconds: 200),
                  crossFadeState: _showChecklist
                      ? CrossFadeState.showFirst
                      : CrossFadeState.showSecond,
                  firstChild: _buildPasswordChecklist(),
                  secondChild: const SizedBox.shrink(),
                ),

                const SizedBox(height: 15),

                // ── confirm password ──────────────────────────────────────
                _inputField(
                  controller: repwdController,
                  icon: Icons.lock_outline,
                  hint: 'Re-enter your password',
                  obscure: !_repwdVisible,
                  suffixIcon: IconButton(
                    icon: Icon(_repwdVisible ? Icons.visibility_off : Icons.visibility,
                        color: Colors.grey),
                    onPressed: () => setState(() => _repwdVisible = !_repwdVisible),
                  ),
                  validator: (value) {
                    if (value != pwdController.text) return 'Passwords do not match';
                    return null;
                  },
                ),

                const SizedBox(height: 28),

                // ── sign up button ────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 25),
                  child: SizedBox(
                    height: 55,
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: isLoading ? null : createUserWithEmailAndPassword,
                      style: ElevatedButton.styleFrom(
                        padding: EdgeInsets.zero,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        elevation: 10,
                        shadowColor: Colors.purple.withOpacity(0.4),
                        backgroundColor: Colors.transparent,
                      ),
                      child: Ink(
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                              colors: [Color(0xFF5E35B1), Color(0xFF7C4DFF)]),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Container(
                          alignment: Alignment.center,
                          child: isLoading
                              ? const SizedBox(
                                  height: 22, width: 22,
                                  child: TravelLoadingIndicator(),
                                )
                              : const Text('Sign Up',
                                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 40),

                // ── go to login ───────────────────────────────────────────
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('Already have an account? '),
                    GestureDetector(
                      onTap: () => Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(builder: (_) => const LoginPage()),
                      ),
                      child: const Text('Login',
                          style: TextStyle(color: Color(0xFF7C4DFF), fontWeight: FontWeight.bold)),
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

  // ── password checklist widget ─────────────────────────────────────────────
  Widget _buildPasswordChecklist() {
    return Container(
      margin: const EdgeInsets.fromLTRB(25, 10, 25, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF2C2C3E),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _checkRow(_hasMinLength, 'At least 8 characters'),
          const SizedBox(height: 6),
          _checkRow(_hasDigit,     'At least one digit (0–9)'),
          const SizedBox(height: 6),
          _checkRow(_hasLowercase, 'At least one lower case character'),
          const SizedBox(height: 6),
          _checkRow(_hasUppercase, 'At least one upper case character'),
          const SizedBox(height: 6),
          _checkRow(_hasSpecial,   'At least one special character (i.e: ! \$ # % ...)'),
        ],
      ),
    );
  }

  Widget _checkRow(bool passed, String label) {
    return Row(
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: Icon(
            passed ? Icons.check_circle : Icons.radio_button_unchecked,
            key: ValueKey(passed),
            size: 18,
            color: passed ? const Color(0xFF4CAF50) : Colors.grey.shade500,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: passed ? const Color(0xFF4CAF50) : Colors.grey.shade400,
          ),
        ),
      ],
    );
  }

  // ── reusable input field ──────────────────────────────────────────────────
  Widget _inputField({
    required TextEditingController controller,
    required IconData icon,
    required String hint,
    bool obscure = false,
    TextInputType keyboardType = TextInputType.text,
    String? Function(String?)? validator,
    Widget? suffixIcon,
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
            suffixIcon: suffixIcon,
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
        BoxShadow(color: Colors.grey.withOpacity(0.25), blurRadius: 8, offset: const Offset(0, 4)),
      ],
    );
  }
}