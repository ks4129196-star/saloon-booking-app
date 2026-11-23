import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../models/salon.dart';

Color chairStatusColor(ChairStatus status) => switch (status) {
  ChairStatus.free => AppColors.success,
  ChairStatus.busy => AppColors.warning,
  ChairStatus.onBreak => AppColors.textSecondary,
};

IconData chairStatusIcon(ChairStatus status) => switch (status) {
  ChairStatus.free => Icons.event_seat_rounded,
  ChairStatus.busy => Icons.content_cut_rounded,
  ChairStatus.onBreak => Icons.coffee_rounded,
};

/// "for 12 min", "for 1 h 5 min" since [since].
String fmtFor(DateTime since, DateTime now) {
  final minutes = now.difference(since).inMinutes.clamp(0, 99 * 60);
  if (minutes < 1) return 'just now';
  if (minutes < 60) return 'for $minutes min';
  final h = minutes ~/ 60, m = minutes % 60;
  return m == 0 ? 'for $h h' : 'for $h h $m min';
}

/// "2 of 4 chairs free" in the colour of the best chair state.
class ChairSummary extends StatelessWidget {
  const ChairSummary({super.key, required this.salon, this.fontSize = 12.5});

  final Salon salon;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final total = salon.chairs.length;
    final free = salon.freeChairs;
    final (text, color) = salon.allChairsOnBreak
        ? ('All chairs on break', AppColors.textSecondary)
        : free > 0
        ? (
            '$free of $total ${total == 1 ? 'chair' : 'chairs'} free',
            AppColors.success,
          )
        : (
            'All $total ${total == 1 ? 'chair' : 'chairs'} busy',
            AppColors.warning,
          );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.event_seat_rounded, size: fontSize + 2, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

/// Every chair with its live status, for customers.
class ChairAvailability extends StatelessWidget {
  const ChairAvailability({super.key, required this.chairs});

  final List<Chair> chairs;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.s,
      runSpacing: AppSpacing.s,
      children: [
        for (final chair in chairs)
          Semantics(
            label: '${chair.name}: ${chair.status.label}',
            child: ExcludeSemantics(
              child: Container(
                width: 104,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.s + 2,
                  vertical: AppSpacing.s,
                ),
                decoration: BoxDecoration(
                  color: chairStatusColor(chair.status).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.button),
                  border: Border.all(
                    color: chairStatusColor(chair.status)
                        .withValues(alpha: 0.45),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          chairStatusIcon(chair.status),
                          size: 15,
                          color: chairStatusColor(chair.status),
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            chair.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      chair.status.label,
                      style: TextStyle(
                        color: chairStatusColor(chair.status),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Free / Busy / Break switch for one chair, for staff.
class ChairStatusSwitch extends StatelessWidget {
  const ChairStatusSwitch({
    super.key,
    required this.status,
    required this.onChanged,
  });

  final ChairStatus status;
  final ValueChanged<ChairStatus>? onChanged;

  @override
  Widget build(BuildContext context) {
    final color = chairStatusColor(status);
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<ChairStatus>(
        showSelectedIcon: false,
        segments: [
          for (final s in ChairStatus.values)
            ButtonSegment(
              value: s,
              icon: Icon(chairStatusIcon(s), size: 16),
              label: Text(s == ChairStatus.onBreak ? 'Break' : s.label),
            ),
        ],
        selected: {status},
        onSelectionChanged: onChanged == null
            ? null
            : (selection) => onChanged!(selection.first),
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? color.withValues(alpha: 0.18)
                : null,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? color
                : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}
