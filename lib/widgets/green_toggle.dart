import 'package:flutter/material.dart';

import '../theme/wrenflow_theme.dart';

/// Custom toggle matching Swift WrenflowStyle — 36×20 capsule, 16pt white thumb.
class GreenToggle extends StatelessWidget {
  const GreenToggle({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeInOut,
        width: 36,
        height: 20,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: value ? WrenflowStyle.green : WrenflowStyle.textOp15,
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeInOut,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 16,
            height: 16,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}
