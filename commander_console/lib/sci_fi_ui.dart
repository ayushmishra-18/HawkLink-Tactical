import 'dart:math';
import 'package:flutter/material.dart';

// --- PALETTE ---
const Color kSciFiBlack = Color(0xFF020408);
const Color kSciFiDarkBlue = Color(0xFF0A1122);
const Color kSciFiCyan = Color(0xFF00E5FF);
const Color kSciFiGreen = Color(0xFF00FF9D);
const Color kSciFiRed = Color(0xFFFF2A4D);
const Color kSciFiGlass = Color(0xCC081018); // ~80% Opacity Dark Blue

// --- 1. ANGLED PANEL (The "Sci-Fi" Container) ---
class SciFiPanel extends StatelessWidget {
  final Widget child;
  final Color borderColor;
  final String? title;
  final bool showBg;
  final double? width;
  final double? height;

  const SciFiPanel({
    super.key,
    required this.child,
    this.borderColor = kSciFiCyan,
    this.title,
    this.showBg = true,
    this.width,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    Widget content;
    if (title != null) {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title!, style: TextStyle(color: borderColor, fontFamily: 'Orbitron', fontWeight: FontWeight.bold, fontSize: 12)),
          Divider(color: borderColor.withOpacity(0.3)),
          Flexible(child: child),
        ],
      );
    } else {
      content = child;
    }

    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(
        painter: _SciFiBorderPainter(color: borderColor),
        child: Container(
          padding: const EdgeInsets.all(8), // REDUCED PADDING (Was 12)
          color: showBg ? kSciFiGlass : null,
          child: content,
        ),
      ),
    );
  }
}

class _SciFiBorderPainter extends CustomPainter {
  final Color color;
  _SciFiBorderPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    final path = Path();
    path.moveTo(15, 0);
    path.lineTo(size.width, 0);
    path.lineTo(size.width, size.height);
    path.lineTo(15, size.height);
    path.lineTo(0, size.height - 15);
    path.lineTo(0, 0);
    path.close();

    canvas.drawPath(path, paint);

    // Decorative lines
    if (size.width > 25) {
      canvas.drawLine(Offset(size.width - 20, 5), Offset(size.width - 5, 5), paint..strokeWidth=3);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// --- 2. HEADER FRAME ---
class SciFiHeader extends StatelessWidget {
  final String label;
  const SciFiHeader({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 60,
      width: double.infinity,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        gradient: LinearGradient(colors: [Colors.transparent, kSciFiDarkBlue, Colors.transparent]),
        border: Border(bottom: BorderSide(color: kSciFiCyan, width: 2)),
      ),
      child: Text(label, style: const TextStyle(color: kSciFiCyan, fontSize: 24, fontFamily: 'Orbitron', letterSpacing: 3, shadows: [Shadow(color: kSciFiCyan, blurRadius: 10)])),
    );
  }
}

// --- 3. SCIFI BUTTON (Improved Visibility & Compactness) ---
class SciFiButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color color;
  final VoidCallback onTap;

  const SciFiButton({super.key, required this.label, this.icon, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 50,
        margin: const EdgeInsets.symmetric(horizontal: 2), // REDUCED MARGIN (Was 4)
        padding: const EdgeInsets.symmetric(horizontal: 8), // REDUCED PADDING (Was 12)
        decoration: BoxDecoration(
          color: color.withOpacity(0.2),
          border: Border.all(color: color.withOpacity(0.8), width: 1.5),
          borderRadius: const BorderRadius.only(topLeft: Radius.circular(10), bottomRight: Radius.circular(10)),
          boxShadow: [BoxShadow(color: color.withOpacity(0.1), blurRadius: 6, spreadRadius: 1)],
        ),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) Icon(icon, color: color, size: 20),
              if (icon != null) const SizedBox(width: 6), // REDUCED SPACING (Was 8)
              Flexible(child: Text(label, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontFamily: 'Orbitron', fontSize: 12))),
            ],
          ),
        ),
      ),
    );
  }
}

// --- 4. EXTRAS ---
class CrtOverlay extends StatelessWidget {
  const CrtOverlay({super.key});
  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black12, Colors.transparent],
            stops: [0.0, 0.5, 1.0], tileMode: TileMode.repeated,
          ),
        ),
      ),
    );
  }
}

class BlinkingText extends StatefulWidget {
  final String text; final Color color;
  const BlinkingText(this.text, {super.key, required this.color});
  @override State<BlinkingText> createState() => _BlinkingTextState();
}

class _BlinkingTextState extends State<BlinkingText> with SingleTickerProviderStateMixin {
  late AnimationController _c;
  @override void initState() { super.initState(); _c = AnimationController(vsync: this, duration: const Duration(seconds: 1))..repeat(reverse: true); }
  @override void dispose() { _c.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => FadeTransition(opacity: _c, child: Text(widget.text, style: TextStyle(color: widget.color, fontWeight: FontWeight.bold, fontSize: 10)));
}

class TacticalGridPainter extends CustomPainter {
  @override void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final paint = Paint()..color = kSciFiGreen.withOpacity(0.05)..strokeWidth = 1;
    for (double x = 0; x < size.width; x += 100) canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    for (double y = 0; y < size.height; y += 100) canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
  }
  @override bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}