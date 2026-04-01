import 'package:flutter/material.dart';

import '../theme/wrenflow_theme.dart';

/// Three cycling dots animation — active dot 0.7 opacity, others 0.15, 0.4s easeInOut.
class InitializingDots extends StatefulWidget {
  const InitializingDots({super.key});

  @override
  State<InitializingDots> createState() => _InitializingDotsState();
}

class _InitializingDotsState extends State<InitializingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
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
      builder: (context, _) {
        // Cycle through 3 dots: each dot is active for 1/3 of the cycle.
        final activeIndex = (_controller.value * 3).floor() % 3;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            return Padding(
              padding: EdgeInsets.only(left: i > 0 ? 5 : 0),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeInOut,
                width: 4.5,
                height: 4.5,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: WrenflowStyle.text.withValues(
                    alpha: i == activeIndex ? 0.7 : 0.15,
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
