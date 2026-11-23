import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../admin/users_screen.dart';
import '../auth/session_gate.dart';
import '../bookings/my_bookings_screen.dart';
import '../claude/claude_chat_screen.dart';
import '../core/realtime.dart';
import '../core/theme.dart';
import '../data/salon_repository.dart';
import '../models/profile.dart';
import '../models/salon.dart';
import '../owner/manage_salons_screen.dart';
import '../owner/staff_dashboard_screen.dart';
import '../queue/queue_widgets.dart';
import 'chair_widgets.dart';
import 'salon_detail_page.dart';

enum SortBy { nearest, leastWait }

enum _MenuAction { signIn, bookings, dashboard, manageSalons, users, logout }

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.profile,
    required this.onReloadProfile,
  });

  final Profile profile;
  final Future<void> Function() onReloadProfile;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // Used when location is unavailable. The demo salons are around here.
  static const _fallbackLat = 28.6139;
  static const _fallbackLon = 77.2090;

  final _repository = SalonRepository();

  bool _loading = true;
  String? _loadError;
  bool _usingDemoLocation = false;
  String _locationNote = '';
  double _lat = _fallbackLat, _lon = _fallbackLon;
  List<Salon> _salons = [];

  /// The signed-in customer's walk-in token, shown above the list.
  QueueToken? _myToken;
  Map<int, Set<DateTime>> _taken = {};
  DateTime _updatedAt = DateTime.now();

  SortBy _sort = SortBy.nearest;
  bool _openNowOnly = false;
  bool _lowWaitOnly = false;
  String _query = '';

  StreamSubscription<RealtimeEvent>? _live;
  Timer? _liveReload;

  @override
  void initState() {
    super.initState();
    _locateAndLoad();
    // Queue sizes, salons and booked slots change live; refresh at most
    // once a second.
    _live = Realtime.instance.events
        .where((event) => event.type != 'booking:changed')
        .listen((_) {
          _liveReload?.cancel();
          _liveReload = Timer(const Duration(seconds: 1), () {
            if (mounted && !_loading) _loadSalons();
          });
        });
  }

  @override
  void dispose() {
    _live?.cancel();
    _liveReload?.cancel();
    super.dispose();
  }

  Future<void> _locateAndLoad() async {
    setState(() => _loading = true);
    await _locate();
    await _loadSalons();
  }

  Future<void> _locate() async {
    var lat = _fallbackLat, lon = _fallbackLon;
    var demo = true;
    var note = 'Using a demo location.';
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        note = 'GPS is off, showing distances from a demo location.';
      } else {
        var perm = await Geolocator.checkPermission();
        if (perm == LocationPermission.denied) {
          perm = await Geolocator.requestPermission();
        }
        if (perm == LocationPermission.denied ||
            perm == LocationPermission.deniedForever) {
          note =
              'Location permission denied, showing distances from a demo '
              'location.';
        } else {
          final pos = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              timeLimit: Duration(seconds: 15),
            ),
          );
          lat = pos.latitude;
          lon = pos.longitude;
          demo = false;
          note = '';
        }
      }
    } catch (_) {
      note = 'Could not get location, showing distances from a demo location.';
    }
    _lat = lat;
    _lon = lon;
    _usingDemoLocation = demo;
    _locationNote = note;
  }

  Future<void> _loadSalons() async {
    if (mounted && !_loading && _salons.isEmpty) {
      setState(() => _loading = true);
    }
    try {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final results = await Future.wait([
        _repository.fetchSalons(),
        _repository.fetchTakenSlots(today, today.add(const Duration(days: 1))),
      ]);
      final salons = results[0] as List<Salon>;
      for (final s in salons) {
        s.distance = Geolocator.distanceBetween(_lat, _lon, s.lat, s.lon);
      }
      QueueToken? myToken;
      if (!widget.profile.isGuest) {
        try {
          myToken = await _repository.fetchMyToken();
        } on RepositoryException {
          myToken = _myToken; // keep showing the last known token
        }
      }
      if (!mounted) return;
      setState(() {
        _salons = salons;
        _myToken = myToken;
        _taken = results[1] as Map<int, Set<DateTime>>;
        _updatedAt = DateTime.now();
        _loadError = null;
        _loading = false;
      });
    } on RepositoryException catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error.message;
        _loading = false;
      });
    }
  }

  List<Salon> _visible(DateTime now) {
    final q = _query.trim().toLowerCase();
    final list = _salons.where((s) {
      if (_openNowOnly && !s.isOpen(now)) return false;
      if (_lowWaitOnly) {
        final w = s.waitMinutes(now);
        if (w == null || w > 15) return false;
      }
      if (q.isNotEmpty) {
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

  Future<void> _push(Widget screen) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => screen),
    );
    if (mounted) _loadSalons();
  }

  void _onMenu(_MenuAction action) {
    switch (action) {
      case _MenuAction.signIn:
        showSignIn(context);
      case _MenuAction.bookings:
        _push(MyBookingsScreen(profile: widget.profile));
      case _MenuAction.dashboard:
        openStaffDashboard(context, widget.profile);
      case _MenuAction.manageSalons:
        _push(ManageSalonsScreen(profile: widget.profile));
      case _MenuAction.users:
        _push(UsersScreen(profile: widget.profile));
      case _MenuAction.logout:
        signOut(context, confirm: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Salons near you'),
        actions: [
          IconButton(
            tooltip: 'Ask Claude',
            icon: const Icon(Icons.auto_awesome, color: AppColors.gold),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const ClaudeChatScreen()),
            ),
          ),
          IconButton(
            tooltip: 'Refresh location',
            icon: const Icon(Icons.my_location, color: AppColors.gold),
            onPressed: () {
              widget.onReloadProfile();
              _locateAndLoad();
            },
          ),
          _AccountMenu(profile: widget.profile, onSelected: _onMenu),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(color: AppColors.gold),
              )
            : _loadError != null && _salons.isEmpty
            ? _ErrorView(message: _loadError!, onRetry: _loadSalons)
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
        if (_myToken != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.m,
              AppSpacing.s,
              AppSpacing.m,
              0,
            ),
            child: MyTokenCard(
              token: _myToken!,
              now: now,
              showSalon: true,
              onTap: () {
                final salon = _salons
                    .where((s) => s.id == _myToken!.salonId)
                    .firstOrNull;
                if (salon != null) {
                  _push(SalonDetailPage(salon: salon, profile: widget.profile));
                }
              },
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
            decoration: const InputDecoration(
              hintText: 'Search salon, type or service (e.g. facial)',
              prefixIcon: Icon(Icons.search),
              contentPadding: EdgeInsets.zero,
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
              '${list.length} salon${list.length == 1 ? '' : 's'} • updated ${fmtDateTime(_updatedAt)}',
              style: const TextStyle(color: AppColors.textSecondary),
            ),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            color: AppColors.gold,
            backgroundColor: AppColors.surface,
            onRefresh: _loadSalons,
            child: list.isEmpty
                ? ListView(
                    children: [
                      const SizedBox(height: 120),
                      Center(
                        child: Text(
                          _salons.isEmpty
                              ? 'No salons have been added yet.'
                              : 'No salons match your filters.',
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                          ),
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
                      taken: _taken[list[i].id] ?? const {},
                      onTap: () => _push(
                        SalonDetailPage(
                          salon: list[i],
                          profile: widget.profile,
                        ),
                      ),
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

// ------------------------------- Account menu --------------------------------

class _AccountMenu extends StatelessWidget {
  const _AccountMenu({required this.profile, required this.onSelected});

  final Profile profile;
  final ValueChanged<_MenuAction> onSelected;

  @override
  Widget build(BuildContext context) {
    final initial = profile.displayName.isEmpty
        ? '?'
        : profile.displayName.characters.first.toUpperCase();
    return PopupMenuButton<_MenuAction>(
      tooltip: 'Account',
      color: AppColors.surface,
      onSelected: onSelected,
      itemBuilder: (_) => [
        PopupMenuItem(
          enabled: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                profile.displayName,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              RoleBadge(role: profile.role),
            ],
          ),
        ),
        const PopupMenuDivider(),
        if (profile.isGuest)
          const PopupMenuItem(
            value: _MenuAction.signIn,
            child: ListTile(
              leading: Icon(Icons.login_rounded, color: AppColors.gold),
              title: Text('Sign in or create account'),
              subtitle: Text(
                'To book, see your bookings or manage a salon',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ),
        if (!profile.isGuest)
          const PopupMenuItem(
            value: _MenuAction.bookings,
            child: ListTile(
              leading: Icon(Icons.event_note_rounded),
              title: Text('My bookings'),
            ),
          ),
        if (!profile.isGuest && profile.canManageSalons)
          const PopupMenuItem(
            value: _MenuAction.dashboard,
            child: ListTile(
              leading: Icon(Icons.dashboard_rounded, color: AppColors.gold),
              title: Text('Staff dashboard'),
            ),
          ),
        if (!profile.isGuest && profile.canManageSalons)
          PopupMenuItem(
            value: _MenuAction.manageSalons,
            child: ListTile(
              leading: const Icon(Icons.storefront_rounded),
              title: Text(profile.isAdmin ? 'Manage salons' : 'My salons'),
            ),
          ),
        if (!profile.isGuest && profile.isAdmin)
          const PopupMenuItem(
            value: _MenuAction.users,
            child: ListTile(
              leading: Icon(Icons.admin_panel_settings_rounded),
              title: Text('Users & roles'),
            ),
          ),
        if (!profile.isGuest) ...[
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: _MenuAction.logout,
            child: ListTile(
              leading: Icon(Icons.logout_rounded, color: AppColors.error),
              title: Text('Log out', style: TextStyle(color: AppColors.error)),
            ),
          ),
        ],
      ],
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s),
        child: CircleAvatar(
          radius: 16,
          backgroundColor: AppColors.gold.withValues(alpha: 0.18),
          child: Text(
            initial,
            style: const TextStyle(
              color: AppColors.gold,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }
}

class RoleBadge extends StatelessWidget {
  const RoleBadge({super.key, required this.role});

  final AppRole role;

  @override
  Widget build(BuildContext context) {
    final color = switch (role) {
      AppRole.admin => AppColors.error,
      AppRole.owner => AppColors.gold,
      AppRole.customer => AppColors.info,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      child: Text(
        role.label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.cloud_off_rounded,
              color: AppColors.textSecondary,
              size: 40,
            ),
            const SizedBox(height: AppSpacing.m),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.m),
            ElevatedButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}

// -------------------------------- Wait badge ---------------------------------

class WaitBadge extends StatelessWidget {
  const WaitBadge({super.key, required this.salon, required this.now});

  final Salon salon;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final wait = salon.waitMinutes(now);
    late final String text;
    late final Color color;
    if (wait == null) {
      text = 'Closed';
      color = AppColors.textSecondary;
    } else if (salon.allChairsOnBreak) {
      text = 'On break';
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
  const SalonCard({
    super.key,
    required this.salon,
    required this.now,
    required this.taken,
    required this.onTap,
  });

  final Salon salon;
  final DateTime now;
  final Set<DateTime> taken;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final open = salon.isOpen(now);
    final nextFree = salon
        .slotsToday(now, taken)
        .where((s) => !s.taken)
        .toList();
    final minPrice = salon.minPrice;
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
                    salon.reviews == 0
                        ? 'New'
                        : '${salon.rating} (${salon.reviews})',
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
                  if (minPrice != null) ...[
                    const SizedBox(width: AppSpacing.m),
                    Text(
                      'From ₹$minPrice',
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
              if (open && salon.chairs.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xs + 2),
                ChairSummary(salon: salon),
              ],
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
