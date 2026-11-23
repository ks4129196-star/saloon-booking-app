import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth/session_gate.dart' show showSignIn;
import '../bookings/booking_form_screen.dart';
import '../core/realtime.dart';
import '../core/theme.dart';
import '../data/salon_repository.dart';
import '../models/profile.dart';
import '../models/salon.dart';
import '../owner/salon_editor_screen.dart';
import '../owner/staff_dashboard_screen.dart';
import '../queue/queue_widgets.dart';
import 'chair_widgets.dart';
import 'home_screen.dart' show WaitBadge;

class SalonDetailPage extends StatefulWidget {
  const SalonDetailPage({
    super.key,
    required this.salon,
    required this.profile,
  });

  final Salon salon;
  final Profile profile;

  @override
  State<SalonDetailPage> createState() => _SalonDetailPageState();
}

class _SalonDetailPageState extends State<SalonDetailPage> {
  final _repository = SalonRepository();
  final Set<Service> _selected = {};
  late Salon _salon = widget.salon;

  Salon get s => _salon;

  bool get _canManage =>
      widget.profile.isAdmin ||
      (widget.profile.isOwner && s.ownerId == widget.profile.id);

  int get _total => _selected.fold(0, (a, e) => a + e.price);
  int get _minutes => _selected.fold(0, (a, e) => a + e.minutes);

  StreamSubscription<RealtimeEvent>? _live;
  Timer? _queueReload;
  late final Timer _clock;

  QueueView? _queue;
  QueueToken? _myToken; // the signed-in customer's token here, if any
  bool _joining = false;

  @override
  void initState() {
    super.initState();
    _loadQueue();
    _live = Realtime.instance.events.listen((event) {
      if (event.type == 'token:changed') {
        _scheduleQueueReload();
        return;
      }
      if (event.salonId != s.id) return;
      if (event.type == 'salon:changed' || event.type == 'salon:deleted') {
        _reloadSalon();
      }
      if (event.type == 'queue:changed' || event.type == 'salon:changed') {
        _scheduleQueueReload();
      }
    });
    // Keeps "expected wait" counting down between updates.
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  void _scheduleQueueReload() {
    _queueReload?.cancel();
    _queueReload = Timer(const Duration(milliseconds: 300), _loadQueue);
  }

  Future<void> _loadQueue() async {
    try {
      final results = await Future.wait([
        _repository.fetchQueue(s.id),
        if (!widget.profile.isGuest) _repository.fetchMyToken(),
      ]);
      if (!mounted) return;
      final mine = results.length > 1 ? results[1] as QueueToken? : null;
      setState(() {
        _queue = results[0] as QueueView;
        _myToken = mine?.salonId == s.id ? mine : null;
      });
    } on RepositoryException {
      // The queue card stays as it was; the next update retries.
    }
  }

  Future<void> _joinQueue() async {
    if (widget.profile.isGuest) {
      await showSignIn(context);
      return;
    }
    final request = await showDialog<QueueRequest>(
      context: context,
      builder: (_) => JoinQueueDialog(
        salon: s,
        initialServices: _selected,
        initialName: widget.profile.fullName,
      ),
    );
    if (request == null || !mounted) return;
    setState(() => _joining = true);
    try {
      final token = await _repository.joinQueue(
        s.id,
        serviceIds: request.serviceIds,
        customerName: request.name.isEmpty ? null : request.name,
        customerPhone: request.phone.isEmpty ? null : request.phone,
      );
      if (!mounted) return;
      setState(() => _myToken = token);
      showAppMessage(
        context,
        'You are ${token.label} in the queue. We will update your wait live.',
      );
      _loadQueue();
    } on RepositoryException catch (error) {
      if (mounted) showAppMessage(context, error.message);
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  Future<void> _leaveQueue(QueueToken token) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Leave the queue?'),
        content: Text(
          'Token ${token.label} will be cancelled. You can take a new one later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Stay'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _repository.tokenAction(token.id, 'cancel');
      if (!mounted) return;
      setState(() => _myToken = null);
      _loadQueue();
    } on RepositoryException catch (error) {
      if (mounted) showAppMessage(context, error.message);
    }
  }

  @override
  void dispose() {
    _live?.cancel();
    _queueReload?.cancel();
    _clock.cancel();
    super.dispose();
  }

  Future<void> _reloadSalon() async {
    try {
      final fresh = await _repository.fetchSalon(s.id);
      fresh.distance = s.distance;
      if (!mounted) return;
      setState(() {
        _salon = fresh;
        _selected.removeWhere((e) => !fresh.services.contains(e));
      });
    } on RepositoryException {
      // Salon was deleted or is unreachable; go back to the list.
      if (mounted) Navigator.pop(context);
    }
  }

  Future<void> _open(Uri uri) async {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) showAppMessage(context, 'Could not open this link');
  }

  /// Opens the appointment form for the chosen services (or sign-in first).
  Future<void> _continue() async {
    if (widget.profile.isGuest) {
      await showSignIn(context);
      return;
    }
    final services = s.services.where(_selected.contains).toList();
    final booked = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => BookingFormScreen(
          salon: s,
          services: services,
          profile: widget.profile,
        ),
      ),
    );
    if (booked == true && mounted) setState(_selected.clear);
  }

  Future<void> _openEditor() async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SalonEditorScreen(profile: widget.profile, salon: s),
      ),
    );
    if (mounted) _reloadSalon();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final guest = widget.profile.isGuest;
    final canContinue = guest || (_selected.isNotEmpty && s.chairs.isNotEmpty);

    // Group services by category
    final categories = <String, List<Service>>{};
    for (final e in s.services) {
      categories.putIfAbsent(e.category, () => []).add(e);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(s.name),
        actions: [
          if (_canManage)
            IconButton(
              tooltip: 'Staff dashboard',
              icon: const Icon(Icons.dashboard_rounded, color: AppColors.gold),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) =>
                      StaffDashboardScreen(salon: s, profile: widget.profile),
                ),
              ),
            ),
          if (_canManage)
            IconButton(
              tooltip: 'Manage this salon',
              icon: const Icon(Icons.edit_rounded, color: AppColors.gold),
              onPressed: _openEditor,
            ),
        ],
      ),
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
                      guest
                          ? 'Sign in to book an appointment'
                          : s.chairs.isEmpty
                          ? 'Not taking bookings right now'
                          : 'Next: pick a date and time',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              ElevatedButton(
                onPressed: canContinue ? _continue : null,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.l,
                    vertical: 14,
                  ),
                ),
                child: Text(guest ? 'Sign in to book' : 'Choose time'),
              ),
            ],
          ),
        ),
      ),
      body: RefreshIndicator(
        color: AppColors.gold,
        backgroundColor: AppColors.surface,
        onRefresh: _reloadSalon,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.m),
          children: [
            // Header
            Row(
              children: [
                Flexible(
                  child: Text(
                    s.type,
                    style: const TextStyle(color: AppColors.gold),
                  ),
                ),
                const SizedBox(width: AppSpacing.m),
                const Icon(Icons.star, size: 16, color: AppColors.gold),
                const SizedBox(width: 3),
                Text(
                  s.reviews == 0
                      ? 'No reviews yet'
                      : '${s.rating} (${s.reviews} reviews)',
                ),
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
                    s.chairs.isEmpty
                        ? _stat('${s.staff}', 'stylists')
                        : _stat(
                            '${s.freeChairs}/${s.chairs.length}',
                            'chairs free',
                          ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.m),
            if (_myToken != null)
              MyTokenCard(
                token: _myToken!,
                now: now,
                onCancel: () => _leaveQueue(_myToken!),
              )
            else
              SalonQueueCard(
                queue: _queue,
                joinLabel: widget.profile.isGuest
                    ? 'Sign in to get a token'
                    : (_joining ? 'Getting your token…' : 'Get a token'),
                onJoin:
                    _joining ||
                        (_queue != null && (!_queue!.open || _queue!.paused))
                    ? null
                    : _joinQueue,
              ),
            if (s.chairs.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.m),
              Row(
                children: [
                  const Text(
                    'Chairs',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: AppSpacing.s),
                  const Text(
                    'updated live',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.s),
              ChairAvailability(chairs: s.chairs),
            ],
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
                    onPressed: s.phone.trim().isEmpty
                        ? null
                        : () => _open(
                            Uri.parse('tel:${s.phone.replaceAll(' ', '')}'),
                          ),
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
            if (s.services.isEmpty)
              const Text(
                'This salon has not listed any services yet.',
                style: TextStyle(color: AppColors.textSecondary),
              ),
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

            const SizedBox(height: AppSpacing.l),
          ],
        ),
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
