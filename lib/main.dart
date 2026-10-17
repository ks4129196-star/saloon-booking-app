// =============================================================================
// Salon Finder - DEMO version with hard-coded data (single file)
//
// What this demo shows:
//   * 8 sample salons placed around the user's real location (so they are
//     always "nearby" while you test)
//   * Services with prices (INR) and durations
//   * Opening hours, "open now" status, estimated waiting time
//   * Free / booked time slots for today, and a working (in-memory) booking
//   * Sort by Nearest or Least wait, filter by Open now / Low wait
//
// NOTE: All salon names, phones and prices below are FAKE sample data.
//
// pubspec.yaml dependencies:
//     geolocator: ^13.0.1
//     url_launcher: ^6.3.1
//
// Android (AndroidManifest.xml, inside <manifest>):
//     <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
//     <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
//     <queries>
//       <intent><action android:name="android.intent.action.VIEW"/><data android:scheme="https"/></intent>
//       <intent><action android:name="android.intent.action.DIAL"/><data android:scheme="tel"/></intent>
//     </queries>
//
// iOS (Info.plist):
//     NSLocationWhenInUseUsageDescription = "Used to show salons near you"
//     LSApplicationQueriesSchemes = [tel, https]
// =============================================================================

import 'dart:math' as math;

import 'package:flutter_first_app/auth/auth_screen.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

// ----------------------------- Design tokens ---------------------------------

class AppColors {
  static const bg = Color(0xFF0E0E10);
  static const surface = Color(0xFF17171A);
  static const card = Color(0xFF1F1F24);
  static const gold = Color(0xFFD4AF37);
  static const error = Color(0xFFE5484D);
  static const success = Color(0xFF3DD68C);
  static const warning = Color(0xFFF5A524);
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

// -------------------------------- Helpers ------------------------------------

String fmtMinutes(int minutesFromMidnight) {
  final h = minutesFromMidnight ~/ 60;
  final m = minutesFromMidnight % 60;
  final h12 = h % 12 == 0 ? 12 : h % 12;
  final ap = h >= 12 ? 'PM' : 'AM';
  return '$h12:${m.toString().padLeft(2, '0')} $ap';
}

String fmtDateTime(DateTime t) => fmtMinutes(t.hour * 60 + t.minute);

String fmtDistance(double meters) => meters < 1000
    ? '${meters.round()} m'
    : '${(meters / 1000).toStringAsFixed(1)} km';

// -------------------------------- Models -------------------------------------

class Service {
  final String name;
  final int price; // INR
  final int minutes;
  final String category;
  const Service(this.name, this.price, this.minutes, this.category);
}

class Slot {
  final DateTime start;
  final String key;
  final bool taken;
  const Slot(this.start, this.key, {required this.taken});
}

class Salon {
  final int id;
  final String name;
  final String type;
  final String address;
  final String phone;
  final double rating;
  final int reviews;
  final double dxMeters; // east/west offset from the user (demo only)
  final double dyMeters; // north/south offset from the user (demo only)
  final int openMin; // minutes from midnight
  final int closeMin;
  final int staff;
  final int queue; // people currently waiting
  final List<Service> services;
  final List<String> highlights;

  final Set<String> myBookings = {};
  double lat = 0, lon = 0, distance = 0;

  Salon({
    required this.id,
    required this.name,
    required this.type,
    required this.address,
    required this.phone,
    required this.rating,
    required this.reviews,
    required this.dxMeters,
    required this.dyMeters,
    required this.openMin,
    required this.closeMin,
    required this.staff,
    required this.queue,
    required this.services,
    this.highlights = const [],
  });

  void placeNear(double baseLat, double baseLon) {
    lat = baseLat + dyMeters / 111320.0;
    lon = baseLon + dxMeters / (111320.0 * math.cos(baseLat * math.pi / 180));
    distance = Geolocator.distanceBetween(baseLat, baseLon, lat, lon);
  }

  bool isOpen(DateTime now) {
    final m = now.hour * 60 + now.minute;
    return m >= openMin && m < closeMin;
  }

  double get avgServiceMinutes =>
      services.map((s) => s.minutes).reduce((a, b) => a + b) / services.length;

  /// Estimated waiting time in minutes (null when closed).
  int? waitMinutes(DateTime now) {
    if (!isOpen(now)) return null;
    return ((queue * avgServiceMinutes) / staff).ceil();
  }

  int get minPrice => services.map((s) => s.price).reduce(math.min);

  List<Slot> slotsToday(DateTime now) {
    final day = DateTime(now.year, now.month, now.day);
    final out = <Slot>[];
    var idx = 0;
    for (var m = openMin; m + 30 <= closeMin; m += 30, idx++) {
      final start = day.add(Duration(minutes: m));
      if (!start.isAfter(now)) continue;
      final key = '$m';
      // Fake "already booked" pattern: busier salons have more taken slots.
      final busy = (id * 31 + idx * 17) % (queue >= 4 ? 2 : 4) == 0;
      out.add(Slot(start, key, taken: busy || myBookings.contains(key)));
    }
    return out;
  }
}

// ------------------------- Hard-coded sample data ----------------------------

List<Salon> buildSampleSalons() {
  const hair = 'Hair';
  const beard = 'Beard & Shave';
  const skin = 'Skin';
  const nails = 'Hands & Feet';
  const wax = 'Waxing & Threading';
  const bridal = 'Bridal & Makeup';

  return [
    Salon(
      id: 1,
      name: 'Glow & Go Unisex Salon',
      type: 'Unisex Salon',
      address: 'Shop 12, Main Market Road',
      phone: '+91 98765 00001',
      rating: 4.6,
      reviews: 412,
      dxMeters: 300,
      dyMeters: 400,
      openMin: 10 * 60,
      closeMin: 21 * 60,
      staff: 4,
      queue: 2,
      highlights: ['AC', 'Card / UPI accepted', 'Parking'],
      services: const [
        Service("Men's Haircut", 250, 30, hair),
        Service("Women's Haircut", 450, 45, hair),
        Service('Hair Wash & Blow Dry', 300, 30, hair),
        Service('Hair Colour (Global)', 1800, 90, hair),
        Service('Beard Trim', 120, 15, beard),
        Service('Fruit Facial', 700, 45, skin),
        Service('Cleanup', 500, 30, skin),
        Service('Eyebrow Threading', 50, 10, wax),
      ],
    ),
    Salon(
      id: 2,
      name: 'The Royal Barber',
      type: 'Barber Shop',
      address: '14, Station Road, Near Bus Stand',
      phone: '+91 98765 00002',
      rating: 4.4,
      reviews: 268,
      dxMeters: 700,
      dyMeters: -200,
      openMin: 9 * 60,
      closeMin: 22 * 60,
      staff: 3,
      queue: 5,
      highlights: ['Men only', 'UPI accepted', 'Walk-ins welcome'],
      services: const [
        Service('Haircut', 200, 25, hair),
        Service('Haircut + Beard', 300, 40, hair),
        Service('Clean Shave', 100, 15, beard),
        Service('Beard Styling', 150, 20, beard),
        Service('Head Massage', 150, 15, hair),
        Service('Hair Colour (Black)', 400, 30, hair),
        Service('Face Cleanup', 350, 25, skin),
      ],
    ),
    Salon(
      id: 3,
      name: 'Bella Beauty Parlour',
      type: 'Ladies Parlour',
      address: '2nd Floor, Lotus Complex, Garden Lane',
      phone: '+91 98765 00003',
      rating: 4.7,
      reviews: 530,
      dxMeters: -900,
      dyMeters: 600,
      openMin: 10 * 60,
      closeMin: 20 * 60,
      staff: 3,
      queue: 1,
      highlights: ['Women only', 'AC', 'Bridal specialists'],
      services: const [
        Service('Haircut', 400, 40, hair),
        Service('Hair Spa', 900, 60, hair),
        Service('Keratin Treatment', 4500, 150, hair),
        Service('Gold Facial', 1200, 60, skin),
        Service('Full Arms Waxing', 300, 20, wax),
        Service('Full Legs Waxing', 450, 30, wax),
        Service('Eyebrow + Upper Lip', 80, 15, wax),
        Service('Manicure', 500, 40, nails),
        Service('Pedicure', 600, 45, nails),
        Service('Bridal Makeup', 12000, 180, bridal),
      ],
    ),
    Salon(
      id: 4,
      name: 'Style Studio',
      type: 'Unisex Salon',
      address: '5, City Square, Ring Road',
      phone: '+91 98765 00004',
      rating: 4.3,
      reviews: 190,
      dxMeters: 1500,
      dyMeters: 1200,
      openMin: 11 * 60,
      closeMin: 21 * 60,
      staff: 5,
      queue: 4,
      highlights: ['AC', 'Card / UPI accepted', 'Wi-Fi'],
      services: const [
        Service("Men's Haircut", 350, 30, hair),
        Service("Women's Haircut", 550, 45, hair),
        Service('Hair Colour (Highlights)', 2500, 120, hair),
        Service('Beard Design', 200, 20, beard),
        Service('D-Tan Facial', 900, 50, skin),
        Service('Manicure', 450, 35, nails),
        Service('Pedicure', 550, 40, nails),
      ],
    ),
    Salon(
      id: 5,
      name: 'Gents Cut Corner',
      type: 'Barber Shop',
      address: 'Opp. Post Office, Temple Street',
      phone: '+91 98765 00005',
      rating: 4.1,
      reviews: 96,
      dxMeters: -400,
      dyMeters: -1100,
      openMin: 8 * 60,
      closeMin: 20 * 60 + 30,
      staff: 2,
      queue: 0,
      highlights: ['Men only', 'No waiting usually', 'Cash only'],
      services: const [
        Service('Haircut', 150, 20, hair),
        Service('Shave', 80, 15, beard),
        Service('Haircut + Shave', 220, 35, hair),
        Service('Head Massage', 100, 15, hair),
      ],
    ),
    Salon(
      id: 6,
      name: 'Pink Petals Ladies Parlour',
      type: 'Ladies Parlour',
      address: 'G-7, Shanti Nagar Market',
      phone: '+91 98765 00006',
      rating: 4.5,
      reviews: 321,
      dxMeters: 2200,
      dyMeters: -900,
      openMin: 10 * 60,
      closeMin: 19 * 60,
      staff: 3,
      queue: 3,
      highlights: ['Women only', 'Home service available', 'UPI accepted'],
      services: const [
        Service('Haircut', 350, 40, hair),
        Service('Hair Colour (Root Touch-up)', 900, 60, hair),
        Service('Fruit Facial', 650, 45, skin),
        Service('Bleach', 400, 30, skin),
        Service('Threading (Full Face)', 150, 25, wax),
        Service('Full Body Waxing', 1800, 90, wax),
        Service('Mehendi (Hands)', 500, 40, bridal),
      ],
    ),
    Salon(
      id: 7,
      name: "Urban Trim Men's Salon",
      type: "Men's Salon",
      address: '27, Sector 4 Commercial Complex',
      phone: '+91 98765 00007',
      rating: 4.2,
      reviews: 154,
      dxMeters: -2500,
      dyMeters: 300,
      openMin: 9 * 60 + 30,
      closeMin: 21 * 60 + 30,
      staff: 4,
      queue: 6,
      highlights: ['Men only', 'AC', 'Card / UPI accepted'],
      services: const [
        Service('Haircut', 300, 30, hair),
        Service('Beard Trim', 130, 15, beard),
        Service('Hair Spa', 700, 45, hair),
        Service('Charcoal Facial', 800, 40, skin),
        Service('Pedicure', 500, 40, nails),
        Service('Groom Package', 3500, 120, bridal),
      ],
    ),
    Salon(
      id: 8,
      name: 'Serenity Spa & Salon',
      type: 'Premium Salon & Spa',
      address: 'Ground Floor, Crown Mall, Highway Road',
      phone: '+91 98765 00008',
      rating: 4.8,
      reviews: 702,
      dxMeters: 3500,
      dyMeters: 2000,
      openMin: 10 * 60,
      closeMin: 22 * 60,
      staff: 6,
      queue: 2,
      highlights: ['AC', 'Premium products', 'Parking', 'Card / UPI accepted'],
      services: const [
        Service("Men's Haircut", 600, 40, hair),
        Service("Women's Haircut", 900, 50, hair),
        Service('Hair Spa', 1500, 70, hair),
        Service('Keratin Treatment', 6000, 180, hair),
        Service('Hydra Facial', 2800, 60, skin),
        Service('Aroma Body Massage', 2200, 60, skin),
        Service('Manicure + Pedicure', 1600, 80, nails),
        Service('Bridal Makeup (HD)', 15000, 210, bridal),
      ],
    ),
  ];
}

// --------------------------------- App ---------------------------------------

const _supabaseUrl = String.fromEnvironment(
  'SUPABASE_URL',
  defaultValue: 'https://zszfdqppfsstzrluzvhj.supabase.co',
);
const _supabasePublishableKey =
    String.fromEnvironment(
      'SUPABASE_PUBLISHABLE_KEY',
      defaultValue: 'sb_publishable_Qy5iqG9GJHEp778w17gz8Q_Ow0DEBHW',
    );
const _supabaseConfigured =
    _supabaseUrl != '' && _supabasePublishableKey != '';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (_supabaseConfigured) {
    await Supabase.initialize(
      url: _supabaseUrl,
      publishableKey: _supabasePublishableKey,
    );
  }
  runApp(const MyApp(supabaseConfigured: _supabaseConfigured));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, this.supabaseConfigured = true});

  final bool supabaseConfigured;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Salon Finder',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: AppColors.bg,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.gold,
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
        textTheme: const TextTheme(
          bodyMedium: TextStyle(color: AppColors.textPrimary),
          bodySmall: TextStyle(color: AppColors.textSecondary),
        ),
      ),
      home: supabaseConfigured
          ? AuthScreen(destinationBuilder: () => const HomeScreen())
          : const SupabaseConfigurationScreen(),
    );
  }
}

class SupabaseConfigurationScreen extends StatelessWidget {
  const SupabaseConfigurationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(AppSpacing.l),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 460),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.content_cut_rounded,
                    color: AppColors.gold,
                    size: 42,
                  ),
                  SizedBox(height: AppSpacing.m),
                  Text(
                    'Connect your Supabase project',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: AppSpacing.s),
                  Text(
                    'Run the app with SUPABASE_URL and '
                    'SUPABASE_PUBLISHABLE_KEY '
                    'configured using --dart-define. See README.md for setup.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ------------------------------- Home screen ---------------------------------

enum SortBy { nearest, leastWait }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // Used when location is unavailable (demo only).
  static const _fallbackLat = 28.6139;
  static const _fallbackLon = 77.2090;

  bool _loading = true;
  bool _usingDemoLocation = false;
  String _locationNote = '';
  List<Salon> _salons = [];

  SortBy _sort = SortBy.nearest;
  bool _openNowOnly = false;
  bool _lowWaitOnly = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    setState(() => _loading = true);
    double lat = _fallbackLat, lon = _fallbackLon;
    _usingDemoLocation = true;
    _locationNote = 'Using a demo location.';

    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _locationNote = 'GPS is off, showing salons around a demo location.';
      } else {
        var perm = await Geolocator.checkPermission();
        if (perm == LocationPermission.denied) {
          perm = await Geolocator.requestPermission();
        }
        if (perm == LocationPermission.denied ||
            perm == LocationPermission.deniedForever) {
          _locationNote = 'Location permission denied, showing salons around a demo location.';
        } else {
          final pos = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              timeLimit: Duration(seconds: 15),
            ),
          );
          lat = pos.latitude;
          lon = pos.longitude;
          _usingDemoLocation = false;
          _locationNote = '';
        }
      }
    } catch (_) {
      _locationNote = 'Could not get location, showing a demo location.';
    }

    final salons = buildSampleSalons();
    for (final s in salons) {
      s.placeNear(lat, lon);
    }
    if (!mounted) return;
    setState(() {
      _salons = salons;
      _loading = false;
    });
  }

  List<Salon> _visible(DateTime now) {
    var list = _salons.where((s) {
      if (_openNowOnly && !s.isOpen(now)) return false;
      if (_lowWaitOnly) {
        final w = s.waitMinutes(now);
        if (w == null || w > 15) return false;
      }
      if (_query.trim().isNotEmpty) {
        final q = _query.toLowerCase();
        final inServices = s.services.any(
          (e) => e.name.toLowerCase().contains(q),
        );
        if (!s.name.toLowerCase().contains(q) &&
            !s.type.toLowerCase().contains(q) &&
            !inServices) {
          return false;
        }
      }
      return true;
    }).toList();

    if (_sort == SortBy.nearest) {
      list.sort((a, b) => a.distance.compareTo(b.distance));
    } else {
      list.sort((a, b) {
        final wa = a.waitMinutes(now) ?? 9999;
        final wb = b.waitMinutes(now) ?? 9999;
        final c = wa.compareTo(wb);
        return c != 0 ? c : a.distance.compareTo(b.distance);
      });
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Salons near you'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.my_location, color: AppColors.gold),
            onPressed: _init,
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(color: AppColors.gold),
              )
            : _buildList(now),
      ),
    );
  }

  Widget _buildList(DateTime now) {
    final list = _visible(now);
    return Column(
      children: [
        if (_usingDemoLocation)
          Container(
            width: double.infinity,
            color: AppColors.warning.withValues(alpha: 0.15),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.m,
              vertical: AppSpacing.s,
            ),
            child: Text(
              _locationNote,
              style: const TextStyle(color: AppColors.warning, fontSize: 12.5),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.m,
            AppSpacing.s,
            AppSpacing.m,
            AppSpacing.s,
          ),
          child: TextField(
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              hintText: 'Search salon, type or service (e.g. facial)',
              prefixIcon: const Icon(Icons.search),
              filled: true,
              fillColor: AppColors.surface,
              contentPadding: EdgeInsets.zero,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.button),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        SizedBox(
          height: 42,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.m),
            children: [
              _chip(
                'Nearest',
                _sort == SortBy.nearest,
                () => setState(() => _sort = SortBy.nearest),
              ),
              _chip(
                'Least wait',
                _sort == SortBy.leastWait,
                () => setState(() => _sort = SortBy.leastWait),
              ),
              _chip(
                'Open now',
                _openNowOnly,
                () => setState(() => _openNowOnly = !_openNowOnly),
              ),
              _chip(
                'Wait under 15 min',
                _lowWaitOnly,
                () => setState(() => _lowWaitOnly = !_lowWaitOnly),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.m,
            vertical: AppSpacing.s,
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '${list.length} salon${list.length == 1 ? '' : 's'} • updated ${fmtDateTime(now)}',
              style: const TextStyle(color: AppColors.textSecondary),
            ),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            color: AppColors.gold,
            backgroundColor: AppColors.surface,
            onRefresh: () async => setState(() {}),
            child: list.isEmpty
                ? ListView(
                    children: const [
                      SizedBox(height: 120),
                      Center(
                        child: Text(
                          'No salons match your filters.',
                          style: TextStyle(color: AppColors.textSecondary),
                        ),
                      ),
                    ],
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.m,
                      0,
                      AppSpacing.m,
                      AppSpacing.l,
                    ),
                    itemCount: list.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: AppSpacing.s + 4),
                    itemBuilder: (_, i) => SalonCard(
                      salon: list[i],
                      now: now,
                      onTap: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => SalonDetailPage(salon: list[i]),
                          ),
                        );
                        if (mounted) setState(() {});
                      },
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.s),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        showCheckmark: false,
        selectedColor: AppColors.gold,
        backgroundColor: AppColors.surface,
        labelStyle: TextStyle(
          color: selected ? Colors.black : AppColors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.chip),
        ),
        side: BorderSide.none,
        onSelected: (_) => onTap(),
      ),
    );
  }
}

// -------------------------------- Wait badge ---------------------------------

class WaitBadge extends StatelessWidget {
  final Salon salon;
  final DateTime now;
  const WaitBadge({super.key, required this.salon, required this.now});

  @override
  Widget build(BuildContext context) {
    final wait = salon.waitMinutes(now);
    late final String text;
    late final Color color;
    if (wait == null) {
      text = 'Closed';
      color = AppColors.textSecondary;
    } else if (wait == 0) {
      text = 'No wait';
      color = AppColors.success;
    } else {
      text = '~$wait min wait';
      color = wait <= 10
          ? AppColors.success
          : (wait <= 25 ? AppColors.warning : AppColors.error);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: 12.5,
        ),
      ),
    );
  }
}

// -------------------------------- Salon card ---------------------------------

class SalonCard extends StatelessWidget {
  final Salon salon;
  final DateTime now;
  final VoidCallback onTap;

  const SalonCard({
    super.key,
    required this.salon,
    required this.now,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final open = salon.isOpen(now);
    final nextFree = salon.slotsToday(now).where((s) => !s.taken).toList();
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.m),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      salon.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  WaitBadge(salon: salon, now: now),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                salon.type,
                style: const TextStyle(color: AppColors.gold, fontSize: 12.5),
              ),
              const SizedBox(height: AppSpacing.s),
              Row(
                children: [
                  const Icon(Icons.star, size: 16, color: AppColors.gold),
                  const SizedBox(width: 3),
                  Text(
                    '${salon.rating} (${salon.reviews})',
                    style: const TextStyle(fontSize: 13),
                  ),
                  const SizedBox(width: AppSpacing.m),
                  const Icon(
                    Icons.near_me,
                    size: 15,
                    color: AppColors.textSecondary,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    fmtDistance(salon.distance),
                    style: const TextStyle(fontSize: 13),
                  ),
                  const SizedBox(width: AppSpacing.m),
                  Text(
                    'From ₹${salon.minPrice}',
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.s),
              Text(
                salon.address,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: AppSpacing.xs + 2),
              Row(
                children: [
                  Icon(
                    Icons.schedule,
                    size: 14,
                    color: open ? AppColors.success : AppColors.error,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      open
                          ? 'Open until ${fmtMinutes(salon.closeMin)}'
                                '${nextFree.isNotEmpty ? ' • next free slot ${fmtDateTime(nextFree.first.start)}' : ' • no free slots today'}'
                          : 'Closed • opens ${fmtMinutes(salon.openMin)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ------------------------------- Detail page ---------------------------------

class SalonDetailPage extends StatefulWidget {
  final Salon salon;
  const SalonDetailPage({super.key, required this.salon});

  @override
  State<SalonDetailPage> createState() => _SalonDetailPageState();
}

class _SalonDetailPageState extends State<SalonDetailPage> {
  final Set<Service> _selected = {};
  String? _slotKey;

  Salon get s => widget.salon;

  int get _total => _selected.fold(0, (a, e) => a + e.price);
  int get _minutes => _selected.fold(0, (a, e) => a + e.minutes);

  Future<void> _open(Uri uri) async {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not open this link')));
    }
  }

  Future<void> _book(Slot slot) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Confirm booking'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.name, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: AppSpacing.s),
            Text('Today at ${fmtDateTime(slot.start)}'),
            const SizedBox(height: AppSpacing.s),
            ..._selected.map((e) => Text('• ${e.name}  ₹${e.price}')),
            const Divider(),
            Text(
              'Total: ₹$_total  (~$_minutes min)',
              style: const TextStyle(
                color: AppColors.gold,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: AppSpacing.s),
            const Text(
              'Pay at the salon. Demo booking only.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      setState(() {
        s.myBookings.add(slot.key);
        _selected.clear();
        _slotKey = null;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Booked at ${fmtDateTime(slot.start)} 🎉')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final slots = s.slotsToday(now);
    Slot? chosen;
    for (final sl in slots) {
      if (sl.key == _slotKey && !sl.taken) chosen = sl;
    }
    final canBook = _selected.isNotEmpty && chosen != null;

    // Group services by category
    final categories = <String, List<Service>>{};
    for (final e in s.services) {
      categories.putIfAbsent(e.category, () => []).add(e);
    }

    return Scaffold(
      appBar: AppBar(title: Text(s.name)),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.m),
          decoration: const BoxDecoration(
            color: AppColors.surface,
            border: Border(top: BorderSide(color: AppColors.divider)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _selected.isEmpty
                          ? 'Select services'
                          : '₹$_total  •  ~$_minutes min',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      chosen == null
                          ? 'Pick a time slot'
                          : 'Today ${fmtDateTime(chosen.start)}',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              ElevatedButton(
                onPressed: canBook ? () => _book(chosen!) : null,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.l,
                    vertical: 14,
                  ),
                ),
                child: const Text('Book slot'),
              ),
            ],
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.m),
        children: [
          // Header
          Row(
            children: [
              Text(s.type, style: const TextStyle(color: AppColors.gold)),
              const SizedBox(width: AppSpacing.m),
              const Icon(Icons.star, size: 16, color: AppColors.gold),
              const SizedBox(width: 3),
              Text('${s.rating} (${s.reviews} reviews)'),
            ],
          ),
          const SizedBox(height: AppSpacing.s),
          Text(
            s.address,
            style: const TextStyle(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 4),
          Text(
            '${fmtDistance(s.distance)} away • ${fmtMinutes(s.openMin)} - ${fmtMinutes(s.closeMin)}',
            style: const TextStyle(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.m),

          // Live status card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.m),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Right now',
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 4),
                        WaitBadge(salon: s, now: now),
                      ],
                    ),
                  ),
                  _stat('${s.queue}', 'in queue'),
                  const SizedBox(width: AppSpacing.l),
                  _stat('${s.staff}', 'stylists'),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.m),

          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.directions),
                  label: const Text('Directions'),
                  onPressed: () => _open(
                    Uri.parse(
                      'https://www.google.com/maps/dir/?api=1&destination=${s.lat},${s.lon}',
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.s),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.call),
                  label: const Text('Call'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.gold,
                    side: const BorderSide(color: AppColors.gold),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.button),
                    ),
                  ),
                  onPressed: () =>
                      _open(Uri.parse('tel:${s.phone.replaceAll(' ', '')}')),
                ),
              ),
            ],
          ),

          if (s.highlights.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.m),
            Wrap(
              spacing: AppSpacing.s,
              runSpacing: AppSpacing.s,
              children: s.highlights
                  .map(
                    (h) => Chip(
                      label: Text(h),
                      backgroundColor: AppColors.card,
                      side: BorderSide.none,
                      labelStyle: const TextStyle(fontSize: 12),
                    ),
                  )
                  .toList(),
            ),
          ],

          // Services
          const SizedBox(height: AppSpacing.l),
          const Text(
            'Services & prices',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppSpacing.s),
          for (final entry in categories.entries) ...[
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s),
              child: Text(
                entry.key.toUpperCase(),
                style: const TextStyle(
                  color: AppColors.gold,
                  fontSize: 12,
                  letterSpacing: 1,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Card(
              child: Column(
                children: [
                  for (var i = 0; i < entry.value.length; i++) ...[
                    CheckboxListTile(
                      value: _selected.contains(entry.value[i]),
                      activeColor: AppColors.gold,
                      checkColor: Colors.black,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(entry.value[i].name),
                      subtitle: Text(
                        '${entry.value[i].minutes} min',
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                      secondary: Text(
                        '₹${entry.value[i].price}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                      onChanged: (v) => setState(() {
                        if (v == true) {
                          _selected.add(entry.value[i]);
                        } else {
                          _selected.remove(entry.value[i]);
                        }
                      }),
                    ),
                    if (i != entry.value.length - 1)
                      const Divider(height: 1, color: AppColors.divider),
                  ],
                ],
              ),
            ),
          ],

          // Slots
          const SizedBox(height: AppSpacing.l),
          const Text(
            "Today's available slots",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppSpacing.s),
          if (slots.isEmpty)
            Text(
              s.isOpen(now)
                  ? 'No more slots today.'
                  : 'Closed right now. Opens at ${fmtMinutes(s.openMin)}.',
              style: const TextStyle(color: AppColors.textSecondary),
            )
          else
            Wrap(
              spacing: AppSpacing.s,
              runSpacing: AppSpacing.s,
              children: slots.map((sl) {
                final selected = sl.key == _slotKey && !sl.taken;
                return ChoiceChip(
                  label: Text(fmtDateTime(sl.start)),
                  selected: selected,
                  showCheckmark: false,
                  selectedColor: AppColors.gold,
                  backgroundColor: AppColors.card,
                  disabledColor: AppColors.surface,
                  side: BorderSide.none,
                  labelStyle: TextStyle(
                    color: sl.taken
                        ? AppColors.textSecondary
                        : (selected ? Colors.black : AppColors.textPrimary),
                    decoration: sl.taken ? TextDecoration.lineThrough : null,
                    fontWeight: FontWeight.w600,
                  ),
                  onSelected: sl.taken
                      ? null
                      : (_) => setState(() => _slotKey = sl.key),
                );
              }).toList(),
            ),
          const SizedBox(height: AppSpacing.s),
          const Text(
            'Struck-through slots are already booked.',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: AppSpacing.l),
        ],
      ),
    );
  }

  Widget _stat(String value, String label) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: AppColors.gold,
          ),
        ),
        Text(
          label,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 11.5,
          ),
        ),
      ],
    );
  }
}
