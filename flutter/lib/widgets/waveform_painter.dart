import 'dart:math' as math;

import 'package:flutter/material.dart';

/// CustomPainter that draws animated audio waveform bars.
///
/// Each bar's height is driven by a combination of the current [audioLevel]
/// (0.0 to 1.0) and a per-bar random-ish offset so the bars don't all move
/// in lockstep. The [animationValue] (0.0 to 1.0, looping) adds gentle idle
/// motion so the waveform never looks completely frozen.
class WaveformPainter extends CustomPainter {
  WaveformPainter({
    required this.audioLevel,
    required this.animationValue,
    this.barCount = 5,
    this.barColor = Colors.white,
    this.barWidth = 4.0,
    this.barSpacing = 3.0,
    this.minBarHeightFraction = 0.15,
  });

  /// Current audio level from 0.0 (silence) to 1.0 (peak).
  final double audioLevel;

  /// Continuously cycling value in [0, 1) used for idle animation.
  final double animationValue;

  /// Number of vertical bars to draw.
  final int barCount;

  /// Fill colour of each bar.
  final Color barColor;

  /// Width of each bar in logical pixels.
  final double barWidth;

  /// Horizontal gap between adjacent bars.
  final double barSpacing;

  /// Minimum bar height expressed as a fraction of the available height.
  /// Ensures bars are always visible even when audio level is zero.
  final double minBarHeightFraction;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = barColor
      ..style = PaintingStyle.fill;

    final totalBarsWidth =
        barCount * barWidth + (barCount - 1) * barSpacing;
    final startX = (size.width - totalBarsWidth) / 2;

    for (int i = 0; i < barCount; i++) {
      // Per-bar phase offset so each bar oscillates independently.
      final phase = (i / barCount) * 2 * math.pi;
      final idleWave =
          (math.sin(animationValue * 2 * math.pi + phase) + 1) / 2;

      // Blend between idle motion and audio-driven height.
      // When audioLevel is low the idle wave dominates; when high the
      // audio level dominates.
      final blendedLevel =
          audioLevel * 0.85 + idleWave * 0.15 * (1.0 - audioLevel * 0.5);

      final heightFraction =
          minBarHeightFraction +
          (1.0 - minBarHeightFraction) * blendedLevel.clamp(0.0, 1.0);
      final barHeight = size.height * heightFraction;

      final x = startX + i * (barWidth + barSpacing);
      final y = (size.height - barHeight) / 2;

      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, barWidth, barHeight),
        Radius.circular(barWidth / 2),
      );
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(WaveformPainter oldDelegate) {
    return oldDelegate.audioLevel != audioLevel ||
        oldDelegate.animationValue != animationValue ||
        oldDelegate.barCount != barCount ||
        oldDelegate.barColor != barColor;
  }
}
