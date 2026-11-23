import 'package:flutter/material.dart';

// ----------------------------- Design tokens ---------------------------------

class AppColors {
  static const bg = Color(0xFF0E0E10);
  static const surface = Color(0xFF17171A);
  static const card = Color(0xFF1F1F24);
  static const gold = Color(0xFFD4AF37);
  static const error = Color(0xFFE5484D);
  static const success = Color(0xFF3DD68C);
  static const warning = Color(0xFFF5A524);
  static const info = Color(0xFF6CB4F5);
  static const textPrimary = Color(0xFFF2F2F3);
  static const textSecondary = Color(0xFF9A9AA2);
  static const divider = Color(0xFF2C2C33);
}

class AppRadius {
  static const double card = 16;
  static const double button = 12;
  static const double chip = 20;
}

class AppSpacing {
  static const double xs = 4;
  static const double s = 8;
  static const double m = 16;
  static const double l = 24;
}

ThemeData buildAppTheme() {
  return ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    scaffoldBackgroundColor: AppColors.bg,
    colorScheme: const ColorScheme.dark(
      primary: AppColors.gold,
      onPrimary: Colors.black,
      surface: AppColors.surface,
      error: AppColors.error,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.bg,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: AppColors.textPrimary,
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
    ),
    cardTheme: CardThemeData(
      color: AppColors.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.gold,
        foregroundColor: Colors.black,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.button),
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.button),
        borderSide: BorderSide.none,
      ),
    ),
    textTheme: const TextTheme(
      bodyMedium: TextStyle(color: AppColors.textPrimary),
      bodySmall: TextStyle(color: AppColors.textSecondary),
    ),
  );
}

// -------------------------------- Helpers ------------------------------------

String fmtMinutes(int minutesFromMidnight) {
  final h = (minutesFromMidnight ~/ 60) % 24;
  final m = minutesFromMidnight % 60;
  final h12 = h % 12 == 0 ? 12 : h % 12;
  final ap = h >= 12 ? 'PM' : 'AM';
  return '$h12:${m.toString().padLeft(2, '0')} $ap';
}

String fmtDateTime(DateTime t) => fmtMinutes(t.hour * 60 + t.minute);

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "Today", "Tomorrow" or e.g. "Mon 18 Nov".
String fmtDay(DateTime t, DateTime now) {
  final day = DateTime(t.year, t.month, t.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = day.difference(today).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Tomorrow';
  if (diff == -1) return 'Yesterday';
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return '${weekdays[t.weekday - 1]} ${t.day} ${_months[t.month - 1]}';
}

String fmtDistance(double meters) => meters < 1000
    ? '${meters.round()} m'
    : '${(meters / 1000).toStringAsFixed(1)} km';

void showAppMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
