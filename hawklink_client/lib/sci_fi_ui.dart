import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';

// --- PALETTE ---
const Color kSciFiBlack = Color(0xFF000000);
const Color kSciFiDarkBlue = Color(0xFF050A14);
const Color kSciFiCyan = Color(0xFF00F0FF);
const Color kSciFiGreen = Color(0xFF00FF41); // Matrix Green
const Color kSciFiRed = Color(0xFFFF2A2A);
const Color kSciFiAmber = Color(0xFFFFAE00);

// --- 1. GLASS CONTAINER ---
class SciFiGlass extends StatelessWidget {
  final Widget child;
  final double opacity;
  final BorderRadius? borderRadius;
  final Border? border;

  const SciFiGlass({
    super.key,
    required this.child,
    this.opacity = 0.15,
    this.borderRadius,
    this.border,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.zero,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10.0, sigmaY: 10.0),
        child: Container(
          decoration: BoxDecoration(
            color: kSciFiDarkBlue.withOpacity(opacity),
            borderRadius: borderRadius,
            border: border,
          ),
          child: child,
        ),
      ),
    );
  }
}

// --- 2. ANGLED PANEL ---
class SciFiPanel extends StatelessWidget {
  final Widget child;
  final Color borderColor;
  final String? title;
  final bool showBg;
  final double? width;
  final double? height;
  final VoidCallback? onTap;

  const SciFiPanel({
    super.key,
    required this.child,
    this.borderColor = kSciFiCyan,
    this.title,
    this.showBg = true,
    this.width,
    this.height,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    Widget content = child;

    if (title != null) {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Container(width: 3, height: 12, color: borderColor),
                const SizedBox(width: 4),
                Text(title!, style: TextStyle(color: borderColor, fontFamily: 'Courier', fontWeight: FontWeight.bold, fontSize: 10, letterSpacing: 2)),
                const Spacer(),
                Row(children: List.generate(3, (i) => Container(margin: const EdgeInsets.only(left: 2), width: 4, height: 4, color: borderColor.withOpacity(0.5)))),
              ],
            ),
          ),
          Container(height: 1, color: borderColor.withOpacity(0.3), margin: const EdgeInsets.only(bottom: 6)),
          Flexible(child: child),
        ],
      );
    }

    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: width,
        height: height,
        child: CustomPaint(
          painter: _SciFiBorderPainter(color: borderColor, glow: showBg),
          child: showBg
              ? SciFiGlass(
            opacity: 0.6,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: content,
            ),
          )
              : Padding(
            padding: const EdgeInsets.all(12),
            child: content,
          ),
        ),
      ),
    );
  }
}

class _SciFiBorderPainter extends CustomPainter {
  final Color color;
  final bool glow;
  _SciFiBorderPainter({required this.color, required this.glow});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    if (glow) {
      paint.maskFilter = const MaskFilter.blur(BlurStyle.outer, 4.0);
    }

    final path = Path();
    double cut = 15.0;

    path.moveTo(0, cut);
    path.lineTo(0, size.height);
    path.lineTo(size.width - cut, size.height);
    path.lineTo(size.width, size.height - cut);
    path.lineTo(size.width, 0);
    path.lineTo(cut, 0);
    path.close();

    canvas.drawPath(path, paint);

    final accentPaint = Paint()..color = color..strokeWidth = 2.0..style = PaintingStyle.stroke;
    canvas.drawPath(Path()..moveTo(0, cut)..lineTo(cut, 0), accentPaint);
    canvas.drawPath(Path()..moveTo(size.width - cut, size.height)..lineTo(size.width, size.height - cut), accentPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// --- 3. TACTICAL BUTTON ---
class SciFiButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color color;
  final VoidCallback onTap;
  final bool isCompact;

  const SciFiButton({
    super.key,
    required this.label,
    this.icon,
    required this.color,
    required this.onTap,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        splashColor: color.withOpacity(0.5),
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: isCompact ? 8 : 12, vertical: isCompact ? 8 : 12),
          decoration: BoxDecoration(
            border: Border.all(color: color.withOpacity(0.6)),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [color.withOpacity(0.1), Colors.transparent],
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) Icon(icon, color: color, size: isCompact ? 18 : 22),
              if (icon != null && label.isNotEmpty) const SizedBox(height: 4),
              if (label.isNotEmpty) Text(label, style: TextStyle(color: color, fontFamily: 'Orbitron', fontSize: isCompact ? 9 : 11, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ),
    );
  }
}

// --- 4. TACTICAL COMPASS ---
class SciFiCompass extends StatelessWidget {
  final VoidCallback onRecenterLocation;
  final VoidCallback onResetNorth;
  final Function(double) onRotate;
  final Color color;

  const SciFiCompass({
    super.key,
    required this.onRecenterLocation,
    required this.onResetNorth,
    required this.onRotate,
    required this.color
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 140,
      height: 140,
      child: Stack(
        alignment: Alignment.center,
        children: [
          IgnorePointer(
            child: CustomPaint(
              size: const Size(120, 120),
              painter: _CompassPainter(color: color),
            ),
          ),
          Positioned(top: 0, child: _DirBtn("N", () => onRotate(0))),
          Positioned(right: 0, child: _DirBtn("E", () => onRotate(90))),
          Positioned(bottom: 0, child: _DirBtn("S", () => onRotate(180))),
          Positioned(left: 0, child: _DirBtn("W", () => onRotate(270))),

          // Split Center Buttons - POSITIONED MUCH HIGHER
          Positioned(
            top: 20,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: onRecenterLocation,
                  child: Container(
                    width: 36, height: 36,
                    margin: const EdgeInsets.only(right: 4),
                    decoration: BoxDecoration(
                        color: color.withOpacity(0.1),
                        border: Border.all(color: color),
                        shape: BoxShape.circle,
                        boxShadow: [BoxShadow(color: color.withOpacity(0.2), blurRadius: 10)]
                    ),
                    child: Icon(Icons.my_location, color: color, size: 18),
                  ),
                ),
                GestureDetector(
                  onTap: onResetNorth,
                  child: Container(
                    width: 36, height: 36,
                    margin: const EdgeInsets.only(left: 4),
                    decoration: BoxDecoration(
                        color: color.withOpacity(0.1),
                        border: Border.all(color: color),
                        shape: BoxShape.circle,
                        boxShadow: [BoxShadow(color: color.withOpacity(0.2), blurRadius: 10)]
                    ),
                    child: Icon(Icons.navigation, color: color, size: 18),
                  ),
                ),
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _DirBtn(String label, VoidCallback tap) {
    return GestureDetector(
      onTap: tap,
      child: Container(
        width: 30, height: 30,
        color: Colors.transparent, // Hitbox
        alignment: Alignment.center,
        child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 10)),
      ),
    );
  }
}

class _CompassPainter extends CustomPainter {
  final Color color;
  _CompassPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color.withOpacity(0.3)..style = PaintingStyle.stroke..strokeWidth = 1;
    final center = Offset(size.width/2, size.height/2);
    final radius = size.width/2 - 5;

    canvas.drawCircle(center, radius, paint);
    canvas.drawCircle(center, radius * 0.7, paint..strokeWidth=0.5);

    for(int i=0; i<360; i+=45) {
      double angle = i * pi / 180;
      double r1 = radius;
      double r2 = radius - (i % 90 == 0 ? 10 : 5);
      canvas.drawLine(
          Offset(center.dx + r1 * cos(angle), center.dy + r1 * sin(angle)),
          Offset(center.dx + r2 * cos(angle), center.dy + r2 * sin(angle)),
          Paint()..color = color..strokeWidth = (i%90==0 ? 2 : 1)
      );
    }
  }
  @override bool shouldRepaint(old) => false;
}

// --- 5. EXTRAS ---
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
    double len = 20;

    canvas.drawLine(Offset(cx-len, cy), Offset(cx+len, cy), p);
    canvas.drawLine(Offset(cx, cy-len), Offset(cx, cy+len), p);

    double gap = 30;
    double clen = 10;
    canvas.drawLine(Offset(cx-gap, cy-gap+clen), Offset(cx-gap, cy-gap), p);
    canvas.drawLine(Offset(cx-gap, cy-gap), Offset(cx-gap+clen, cy-gap), p);
    canvas.drawLine(Offset(cx+gap, cy-gap+clen), Offset(cx+gap, cy-gap), p);
    canvas.drawLine(Offset(cx+gap, cy-gap), Offset(cx+gap-clen, cy-gap), p);
    canvas.drawLine(Offset(cx-gap, cy+gap-clen), Offset(cx-gap, cy+gap), p);
    canvas.drawLine(Offset(cx-gap, cy+gap), Offset(cx-gap+clen, cy+gap), p);
    canvas.drawLine(Offset(cx+gap, cy+gap-clen), Offset(cx+gap, cy+gap), p);
    canvas.drawLine(Offset(cx+gap, cy+gap), Offset(cx+gap-clen, cy+gap), p);
  }
  @override bool shouldRepaint(old) => false;
}