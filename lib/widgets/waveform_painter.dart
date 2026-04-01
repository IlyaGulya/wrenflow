import 'dart:math' as math;

import 'package:flutter/material.dart';

/// CustomPainter that draws animated audio waveform bars.
///
/// 9 bars, 3pt wide, 2.5pt spacing, min 2pt max 20pt height.
/// Color: text.opacity(0.6). Symmetric amplitude multipliers.
class WaveformPainter extends CustomPainter {
  WaveformPainter({
    required this.audioLevel,
    required this.animationValue,
    this.barColor = const Color.fromRGBO(38, 38, 38, 0.6),
  });

  final double audioLevel;
  final double animationValue;
  final Color barColor;

  static const int _barCount = 9;
  static const double _barWidth = 3.0;
  static const double _barSpacing = 2.5;
  static const double _minHeight = 2.0;
  static const double _maxHeight = 20.0;

  static const _amplitudeMultipliers = [
    0.35, 0.55, 0.75, 0.9, 1.0, 0.9, 0.75, 0.55, 0.35,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = barColor
      ..style = PaintingStyle.fill;

    final totalWidth =
        _barCount * _barWidth + (_barCount - 1) * _barSpacing;
    final startX = (size.width - totalWidth) / 2;
    final centerY = size.height / 2;

    for (int i = 0; i < _barCount; i++) {
      final phase = (i / _barCount) * 2 * math.pi;
      final idleWave =
          (math.sin(animationValue * 2 * math.pi + phase) + 1) / 2;

      final blendedLevel =
          audioLevel * 0.85 + idleWave * 0.15 * (1.0 - audioLevel * 0.5);

      final barHeight = (_minHeight +
              (_maxHeight - _minHeight) *
                  blendedLevel.clamp(0.0, 1.0) *
                  _amplitudeMultipliers[i])
          .clamp(_minHeight, _maxHeight);

      final x = startX + i * (_barWidth + _barSpacing);
      final y = centerY - barHeight / 2;

      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, _barWidth, barHeight),
        Radius.circular(_barWidth / 2),
      );
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(WaveformPainter oldDelegate) {
    return oldDelegate.audioLevel != audioLevel ||
        oldDelegate.animationValue != animationValue ||
        oldDelegate.barColor != barColor;
  }
}
