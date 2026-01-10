import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'heatmap_engine.dart';

class HeatmapLayer extends StatefulWidget {
  final HeatmapEngine engine;

  const HeatmapLayer({super.key, required this.engine});

  @override
  State<HeatmapLayer> createState() => _HeatmapLayerState();
}

class _HeatmapLayerState extends State<HeatmapLayer> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  
  @override
  void initState() {
    super.initState();
    // Smooth animation for decay visual updates
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000))
      ..repeat(); 
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final points = widget.engine.points;
        if (points.isEmpty) return const SizedBox.shrink();

        return MobileLayerTransformer(
          child: CustomPaint(
            painter: _HeatmapPainter(
              points: points, 
              camera: MapCamera.of(context),
            ),
          ),
        );
      },
    );
  }
}

class _HeatmapPainter extends CustomPainter {
  final List<HeatPoint> points;
  final MapCamera camera;

  _HeatmapPainter({required this.points, required this.camera});

  @override
  void paint(Canvas canvas, Size size) {
    for (var point in points) {
      // 1. Convert LatLng to Screen Point
      final offset = camera.getOffsetFromOrigin(point.location);
      
      // relative to current widget origin (which is usually aligned with map origin in simple setup, 
      // but CustomPaint inside FlutterMap might need offset adjustment).
      // However, typical flutter_map Overlay usage requires converting relative to camera.
      // Re-calculating proper screen coords:
      
      final screenPoint = camera.latLngToScreenPoint(point.location);
      
      // 2. Draw Radial Gradient
      final radius = 60.0 * point.intensity; // Grows with intensity
      
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.red.withOpacity(0.6 * point.intensity),
            Colors.yellow.withOpacity(0.3 * point.intensity),
            Colors.transparent
          ],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(Rect.fromCircle(center: Offset(screenPoint.x, screenPoint.y), radius: radius));

      canvas.drawCircle(Offset(screenPoint.x, screenPoint.y), radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _HeatmapPainter oldDelegate) => true; 
}
