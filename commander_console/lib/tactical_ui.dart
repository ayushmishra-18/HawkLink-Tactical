import 'dart:math';
import 'package:flutter/material.dart';

// --- TACTICAL COLORS ---
const Color kTacGreen = Color(0xFF00FF41);
const Color kTacCyan = Color(0xFF00F0FF);
const Color kTacRed = Color(0xFFFF2A6D);
const Color kTacBg = Color(0xFF0A0A0A);
const Color kTacPanel = Color(0xFF111111);

// --- 1. TACTICAL CONTAINER (Corner Brackets) ---
class TacticalContainer extends StatelessWidget {
  final Widget child;
  final Color color;
  final double padding;
  final bool showBg;
  final double? width; // Fixed: Added width
  final double? height; // Fixed: Added height

  const TacticalContainer({
    super.key,
    required this.child,
    this.color = kTacGreen,
    this.padding = 16.0,
    this.showBg = true,
    this.width,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(
        painter: _BracketPainter(color: color),
        child: Container(
          padding: EdgeInsets.all(padding),
          decoration: showBg ? BoxDecoration(
            color: color.withOpacity(0.05),
            border: Border.all(color: color.withOpacity(0.1), width: 1),
          ) : null,
          child: child,
        ),
      ),
    );
  }
}

class _BracketPainter extends CustomPainter {
  final Color color;
  _BracketPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    double len = 15.0;

    canvas.drawPath(Path()..moveTo(0, len)..lineTo(0, 0)..lineTo(len, 0), paint); // Top Left
    canvas.drawPath(Path()..moveTo(size.width - len, 0)..lineTo(size.width, 0)..lineTo(size.width, len), paint); // Top Right
    canvas.drawPath(Path()..moveTo(size.width, size.height - len)..lineTo(size.width, size.height)..lineTo(size.width - len, size.height), paint); // Bottom Right
    canvas.drawPath(Path()..moveTo(len, size.height)..lineTo(0, size.height)..lineTo(0, size.height - len), paint); // Bottom Left
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// --- 2. CRT SCANLINE OVERLAY ---
class CrtOverlay extends StatelessWidget {
  const CrtOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black12, Colors.transparent],
            stops: [0.0, 0.5, 1.0],
            tileMode: TileMode.repeated,
          ),
        ),
      ),
    );
  }
}

// --- 3. BLINKING TEXT ---
class BlinkingText extends StatefulWidget {
  final String text;
  final Color color;
  const BlinkingText(this.text, {super.key, required this.color});

  @override
  State<BlinkingText> createState() => _BlinkingTextState();
}

class _BlinkingTextState extends State<BlinkingText> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(seconds: 1))..repeat(reverse: true);
  }
  @override
  void dispose() { _controller.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return FadeTransition(opacity: _controller, child: Text(widget.text, style: TextStyle(color: widget.color, fontWeight: FontWeight.bold, fontFamily: 'Courier', fontSize: 10)));
  }
}

// --- 4. TACTICAL BUTTON ---
class TacticalButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const TacticalButton({super.key, required this.icon, required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(border: Border.all(color: color.withOpacity(0.6)), color: color.withOpacity(0.1)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(icon, color: color, size: 24), const SizedBox(height: 4), Text(label, style: TextStyle(color: color, fontSize: 10, fontFamily: 'Courier', fontWeight: FontWeight.bold))]),
      ),
    );
  }
}

// --- 5. GRID PAINTER ---
class TacticalGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = kTacGreen.withOpacity(0.05)..strokeWidth = 1;
    for (double x = 0; x < size.width; x += 100) canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    for (double y = 0; y < size.height; y += 100) canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
  }
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}