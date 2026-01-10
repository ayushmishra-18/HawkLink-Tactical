import 'package:flutter/material.dart';
import '../sci_fi_ui.dart';
import '../security/auth_provider.dart';
import '../main.dart'; // Import for CommanderDashboard navigation

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _passController = TextEditingController();
  final TextEditingController _confirmController = TextEditingController();
  bool _isSetupMode = false;
  bool _isLoading = true;
  String _statusMessage = "INITIALIZING SECURITY PROTOCOLS...";
  Color _statusColor = kSciFiCyan;

  @override
  void initState() {
    super.initState();
    _checkSetup();
  }

  Future<void> _checkSetup() async {
    final hasPass = await AuthProvider.isPasswordSet();
    setState(() {
      _isSetupMode = !hasPass;
      _isLoading = false;
      _statusMessage = _isSetupMode 
          ? "NO PROTOCOLS FOUND. INITIATE SETUP." 
          : "T.A.C.O.S ENCRYPTED GATEWAY LOCKED.";
      _statusColor = _isSetupMode ? kSciFiCyan : kSciFiRed;
    });
  }

  Future<void> _handleAuth() async {
    final pass = _passController.text;
    if (pass.isEmpty) return;

    setState(() {
      _isLoading = true;
      _statusMessage = "VERIFYING BIOMETRICS...";
      _statusColor = kSciFiCyan;
    });

    // Simulate "Processing" delay for effect
    await Future.delayed(const Duration(milliseconds: 800));

    if (_isSetupMode) {
      if (pass != _confirmController.text) {
        setState(() {
          _isLoading = false;
          _statusMessage = "ERROR: PASSCODE MISMATCH";
          _statusColor = Colors.red;
        });
        return;
      }
      
      await AuthProvider.setPassword(pass);
      _grantAccess();
      
    } else {
      final isValid = await AuthProvider.verifyPassword(pass);
      if (isValid) {
        _grantAccess();
      } else {
         setState(() {
          _isLoading = false;
          _statusMessage = "ACCESS DENIED. INVALID CREDENTIALS.";
          _statusColor = Colors.red;
          _passController.clear();
        });
      }
    }
  }

  void _grantAccess() {
    setState(() {
      _statusMessage = "ACCESS GRANTED. WELCOME COMMANDER.";
      _statusColor = kSciFiGreen;
    });
    
    Future.delayed(const Duration(milliseconds: 500), () {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => const CommanderDashboard()),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          const CrtOverlay(),
          Center(
            child: SciFiPanel(
              width: 400,
              height: _isSetupMode ? 500 : 400,
              title: "SECURITY GATEWAY // LEVEL 5",
              borderColor: _statusColor,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.security, size: 64, color: Colors.white24),
                  const SizedBox(height: 20),
                  Text(_statusMessage, 
                       textAlign: TextAlign.center,
                       style: TextStyle(color: _statusColor, fontFamily: 'Orbitron', letterSpacing: 1.5)),
                  
                  const SizedBox(height: 30),
                  
                  if (!_isLoading) ...[
                    _buildTextField("ENTER PASSCODE", _passController, true),
                    
                    if (_isSetupMode) ...[
                      const SizedBox(height: 16),
                      _buildTextField("CONFIRM PASSCODE", _confirmController, true),
                    ],
                    
                    const SizedBox(height: 30),
                    
                    SciFiButton(
                      label: _isSetupMode ? "INITIALIZE SYSTEM" : "UNLOCK GATEWAY",
                      icon: _isSetupMode ? Icons.save : Icons.lock_open,
                      color: _statusColor,
                      onTap: _handleAuth,
                    )
                  ] else 
                    const CircularProgressIndicator(color: kSciFiCyan),
                ],
              ),
            ),
          ),
          
          // Version footer
          Positioned(
            bottom: 20, right: 20,
            child: Text("HawkLink Secure Protocol v2.5.1", style: TextStyle(color: Colors.white24, fontSize: 10, fontFamily: 'Courier New'))
          )
        ],
      ),
    );
  }

  Widget _buildTextField(String label, TextEditingController controller, bool obscure) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: kSciFiCyan, fontSize: 10, fontFamily: 'Orbitron')),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          obscureText: obscure,
          style: const TextStyle(color: Colors.white, fontFamily: 'Courier New'),
          cursorColor: kSciFiGreen,
          decoration: InputDecoration(
            filled: true,
            fillColor: Colors.white.withOpacity(0.05),
            border: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
            focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: kSciFiGreen)),
            isDense: true,
          ),
          onSubmitted: (_) => _handleAuth(),
        ),
      ],
    );
  }
}
