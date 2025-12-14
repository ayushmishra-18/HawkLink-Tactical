import 'package:flutter/material.dart';

// --- PALETTE ---
const Color kSciFiBlack = Color(0xFF050505);
const Color kSciFiDarkBlue = Color(0xFF081018);
const Color kSciFiCyan = Color(0xFF00E5FF);
const Color kSciFiGreen = Color(0xFF00FF41);
const Color kSciFiRed = Color(0xFFFF2A4D);
const Color kSciFiGlass = Color(0xCC050505);

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
    this.borderColor = kSciFiGreen,
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
          Text(title!, style: TextStyle(color: borderColor, fontFamily: 'Courier', fontWeight: FontWeight.bold, fontSize: 12, letterSpacing: 2)),
          Divider(color: borderColor.withOpacity(0.3), height: 8),
          child,
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
          padding: const EdgeInsets.all(16),
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
      ..strokeWidth = 2.0;

    final path = Path();
    double cut = 15.0;

    // Angled Corners
    path.moveTo(cut, 0);
    path.lineTo(size.width - cut, 0);
    path.lineTo(size.width, cut);
    path.lineTo(size.width, size.height - cut);
    path.lineTo(size.width - cut, size.height);
    path.lineTo(cut, size.height);
    path.lineTo(0, size.height - cut);
    path.lineTo(0, cut);
    path.close();

    canvas.drawPath(path, paint);

    // Tech Details (Corners)
    final thickPaint = Paint()..color = color..strokeWidth = 4..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(0, cut), Offset(0, cut + 10), thickPaint);
    canvas.drawLine(Offset(size.width, size.height - cut), Offset(size.width, size.height - cut - 10), thickPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// --- 2. SCIFI BUTTON ---
class SciFiButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color color;
  final VoidCallback onTap;

  const SciFiButton({super.key, required this.label, this.icon, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 45,
          decoration: BoxDecoration(
            color: color.withOpacity(0.15),
            border: Border.all(color: color.withOpacity(0.8), width: 1.5),
            borderRadius: BorderRadius.circular(4), // Slight round for mobile touch
          ),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) Icon(icon, color: color, size: 18),
                if (icon != null) const SizedBox(width: 8),
                Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontFamily: 'Courier', fontSize: 14)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// --- 3. EXTRAS ---
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

class CrosshairOverlay extends StatelessWidget {
  final Color color;
  const CrosshairOverlay({super.key, required this.color});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: IgnorePointer(
        child: Opacity(
          opacity: 0.3,
          child: SizedBox(
            width: 100, height: 100,
            child: CustomPaint(painter: _CrosshairPainter(color)),
          ),
        ),
      ),
    );
  }
}

class _CrosshairPainter extends CustomPainter {
  final Color color;
  _CrosshairPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color..strokeWidth = 1..style = PaintingStyle.stroke;
    double cx = size.width/2; double cy = size.height/2;
    canvas.drawCircle(Offset(cx, cy), 20, p);
    canvas.drawLine(Offset(cx - 30, cy), Offset(cx + 30, cy), p);
    canvas.drawLine(Offset(cx, cy - 30), Offset(cx, cy + 30), p);
  }
  @override bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}