import 'package:flutter/material.dart';

import '../theme/wrenflow_theme.dart';

/// Settings card matching Swift WrenflowStyle — title + content, surface bg, corner 8, border 1pt.
class SettingsCard extends StatelessWidget {
  const SettingsCard({
    super.key,
    required this.title,
    required this.child,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(
            title,
            style: WrenflowStyle.caption(13),
          ),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: WrenflowStyle.settingsCardDecoration,
          child: child,
        ),
      ],
    );
  }
}
