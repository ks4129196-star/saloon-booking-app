import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../bookings/booking_form_screen.dart' show bookingDays;
import '../bookings/my_bookings_screen.dart' show confirmCancelBooking;
import '../core/realtime.dart';
import '../core/theme.dart';
import '../data/salon_repository.dart';
import '../models/profile.dart';
import '../models/salon.dart';
import '../queue/queue_widgets.dart';
import '../salons/chair_widgets.dart';

/// The staff dashboard for one salon: every chair with its live status and
/// the day's appointments on it. Staff switch a chair between Free, Busy and
/// On break, start and finish appointments, and cancel them. New bookings
/// and changes from other devices appear straight away.
class StaffDashboardScreen extends StatefulWidget {
  const StaffDashboardScreen({
    super.key,
    required this.salon,
    required this.profile,
  });

  final Salon salon;
  final Profile profile;

  @override
  State<StaffDashboardScreen> createState() => _StaffDashboardScreenState();
}

class _StaffDashboardScreenState extends State<StaffDashboardScreen> {
  final _repository = SalonRepository();
  late Salon _salon = widget.salon;
  late DateTime _day = _today;
  List<Booking>? _bookings;
  QueueView? _queue; // today's walk-in tokens, with names
  final _busyTokens = <String>{}; // actions in flight
  String? _error;
  int _request = 0;

  /// Chair changes shown before the server confirms them, by chair id.
  final _pending = <int, Chair>{};

  StreamSubscription<RealtimeEvent>? _live;
  Timer? _liveReload;
  late final Timer _clock;

  static DateTime get _today {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  bool get _isToday => _day == _today;

  List<Chair> get _chairs => [
    for (final chair in _salon.chairs) _pending[chair.id] ?? chair,
  ];

  @override
  void initState() {
    super.initState();
    _load();
    Realtime.instance.watchSalonBookings(_salon.id);
    _live = Realtime.instance.events
        .where((event) => event.salonId == _salon.id)
        .listen((event) {
          if (!mounted) return;
          switch (event.type) {
            case 'salon:changed':
              setState(() => _salon = Salon.fromJson(event.data));
            case 'salon:deleted':
              Navigator.of(context).pop();
            default: // a booking was made, cancelled or paid
              _liveReload?.cancel();
              _liveReload = Timer(const Duration(milliseconds: 400), _load);
          }
        });
    // Keeps "now", "next" and "busy for" current.
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      if (_day.isBefore(_today)) {
        // Past midnight: move on to the new day.
        _pickDay(_today);
      } else {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    Realtime.instance.unwatchSalonBookings(_salon.id);
    _live?.cancel();
    _liveReload?.cancel();
    _clock.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final request = ++_request;
    final day = _day;
    try {
      final results = await Future.wait([
        _repository.fetchSalonBookings(
          _salon.id,
          day,
          to: DateTime(day.year, day.month, day.day + 1),
        ),
        _repository.fetchSalon(_salon.id),
        if (day == _today) _repository.fetchManagedQueue(_salon.id),
      ]);
      if (!mounted || request != _request) return;
      setState(() {
        _bookings = results[0] as List<Booking>;
        _salon = results[1] as Salon;
        _queue = results.length > 2 ? results[2] as QueueView : null;
        _error = null;
      });
    } on RepositoryException catch (error) {
      if (!mounted || request != _request) return;
      setState(() => _error = error.message);
    }
  }

  void _pickDay(DateTime day) {
    setState(() {
      _day = day;
      _bookings = null;
    });
    _load();
  }

  Future<void> _setStatus(Chair chair, ChairStatus status) async {
    if (chair.status == status) return;
    setState(() => _pending[chair.id] = chair.copyWith(status: status));
    try {
      await _repository.updateChair(chair.id, status: status);
      final fresh = await _repository.fetchSalon(_salon.id);
      if (mounted) setState(() => _salon = fresh);
    } on RepositoryException catch (error) {
      if (mounted) showAppMessage(context, error.message);
    } finally {
      if (mounted) setState(() => _pending.remove(chair.id));
    }
  }

  // ------------------------------ Walk-in queue ------------------------------

  Future<void> _addWalkIn() async {
    final request = await showDialog<QueueRequest>(
      context: context,
      builder: (_) => JoinQueueDialog(salon: _salon, forStaff: true),
    );
    if (request == null || !mounted) return;
    try {
      final token = await _repository.addWalkIn(
        _salon.id,
        customerName: request.name,
        customerPhone: request.phone.isEmpty ? null : request.phone,
        serviceIds: request.serviceIds,
        minutes: request.minutes,
      );
      if (!mounted) return;
      showAppMessage(context, 'Added ${request.name} as ${token.label}.');
      _load();
    } on RepositoryException catch (error) {
      if (mounted) showAppMessage(context, error.message);
    }
  }

  /// Picks a chair for [token]: chairs not on break and not serving someone.
  Future<Chair?> _pickChair(QueueToken token, String title) {
    final serving = {
      for (final t in _queue?.nowServing ?? const <QueueToken>[])
        if (t.chairId != null) t.chairId!: t,
    };
    return showModalBottomSheet<Chair>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.m),
              child: Text(
                '$title ${token.label} ${token.callName}',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            for (final chair in _chairs)
              ListTile(
                enabled:
                    chair.status != ChairStatus.onBreak &&
                    !serving.containsKey(chair.id),
                leading: Icon(
                  chairStatusIcon(chair.status),
                  color: chairStatusColor(chair.status),
                ),
                title: Text(chair.name),
                subtitle: Text(
                  serving.containsKey(chair.id)
                      ? 'Serving ${serving[chair.id]!.label}'
                      : chair.status.label,
                ),
                onTap: () => Navigator.pop(ctx, chair),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _tokenAction(
    QueueToken token,
    String action, {
    bool pickChair = false,
  }) async {
    int? chairId;
    if (pickChair) {
      final chair = await _pickChair(
        token,
        action == 'call' ? 'Call' : 'Start',
      );
      if (chair == null || !mounted) return;
      chairId = chair.id;
    }
    setState(() => _busyTokens.add(token.id));
    try {
      try {
        await _repository.tokenAction(token.id, action, chairId: chairId);
      } on RepositoryException catch (error) {
        if (error.code != 'appointment_clash' || !mounted) rethrow;
        // The chair has an appointment soon: staff may still go ahead.
        final go = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: AppColors.surface,
            title: const Text('Appointment coming up'),
            content: Text(error.message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Pick another chair'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Start anyway'),
              ),
            ],
          ),
        );
        if (go != true) return;
        await _repository.tokenAction(
          token.id,
          action,
          chairId: chairId,
          force: true,
        );
      }
      _load();
    } on RepositoryException catch (error) {
      if (mounted) showAppMessage(context, error.message);
    } finally {
      if (mounted) setState(() => _busyTokens.remove(token.id));
    }
  }

  Future<void> _cancel(Booking booking) async {
    final ok = await confirmCancelBooking(context, booking);
    if (!ok || !mounted) return;
    try {
      await _repository.cancelBooking(booking.id);
      if (!mounted) return;
      showAppMessage(context, 'Appointment cancelled. The time is free again.');
      _load();
    } on RepositoryException catch (error) {
      if (mounted) showAppMessage(context, error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final chairs = _chairs;
    final bookings = (_bookings ?? const <Booking>[])
        .where((b) => b.active)
        .toList();
    final chairIds = chairs.map((c) => c.id).toSet();
    final unassigned = bookings
        .where((b) => b.chairId == null || !chairIds.contains(b.chairId))
        .toList();
    final cancelled = (_bookings ?? const <Booking>[])
        .where((b) => !b.active)
        .length;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Staff dashboard'),
            Text(
              _salon.name,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12.5,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _load,
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          color: AppColors.gold,
          backgroundColor: AppColors.surface,
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.m,
              AppSpacing.s,
              AppSpacing.m,
              AppSpacing.l,
            ),
            children: [
              _DayBar(day: _day, today: _today, onPick: _pickDay),
              const SizedBox(height: AppSpacing.m),
              _Totals(
                chairs: chairs,
                appointments: bookings.length,
                cancelled: cancelled,
                isToday: _isToday,
              ),
              const SizedBox(height: AppSpacing.m),
              if (_isToday && _queue != null) ...[
                _QueuePanel(
                  queue: _queue!,
                  now: now,
                  busy: _busyTokens,
                  onAdd: _addWalkIn,
                  onAction: _tokenAction,
                ),
                const SizedBox(height: AppSpacing.m),
              ],
              if (_error != null && _bookings == null)
                _Message(
                  icon: Icons.cloud_off_rounded,
                  text: _error!,
                  action: TextButton(
                    onPressed: _load,
                    child: const Text('Try again'),
                  ),
                )
              else if (_bookings == null)
                const Padding(
                  padding: EdgeInsets.all(AppSpacing.l),
                  child: Center(
                    child: CircularProgressIndicator(color: AppColors.gold),
                  ),
                )
              else if (chairs.isEmpty)
                const _Message(
                  icon: Icons.event_seat_outlined,
                  text:
                      'No chairs yet. Add them under Manage salon → Chairs, '
                      'one for each stylist.',
                )
              else ...[
                for (final chair in chairs)
                  _ChairPanel(
                    chair: chair,
                    bookings: bookings
                        .where((b) => b.chairId == chair.id)
                        .toList(),
                    now: now,
                    isToday: _isToday,
                    saving: _pending.containsKey(chair.id),
                    onStatus: (status) => _setStatus(chair, status),
                    onCancel: _cancel,
                    serving: _isToday
                        ? _queue?.nowServing
                              .where((t) => t.chairId == chair.id)
                              .firstOrNull
                        : null,
                    onFinishToken: (t) => _tokenAction(t, 'done'),
                  ),
                if (unassigned.isNotEmpty)
                  _UnassignedPanel(
                    bookings: unassigned,
                    now: now,
                    onCancel: _cancel,
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ------------------------------- Day switcher --------------------------------

class _DayBar extends StatelessWidget {
  const _DayBar({required this.day, required this.today, required this.onPick});

  final DateTime day;
  final DateTime today;
  final ValueChanged<DateTime> onPick;

  @override
  Widget build(BuildContext context) {
    final first = DateTime(today.year, today.month, today.day - 7);
    final last = DateTime(today.year, today.month, today.day + bookingDays - 1);
    DateTime shift(int days) => DateTime(day.year, day.month, day.day + days);
    return Row(
      children: [
        IconButton(
          tooltip: 'Previous day',
          onPressed: shift(-1).isBefore(first) ? null : () => onPick(shift(-1)),
          icon: const Icon(Icons.chevron_left_rounded),
        ),
        Expanded(
          child: TextButton.icon(
            onPressed: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: day,
                firstDate: first,
                lastDate: last,
              );
              if (picked != null) onPick(picked);
            },
            icon: const Icon(Icons.calendar_today_rounded, size: 16),
            label: Text(
              fmtDay(day, DateTime.now()),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ),
        if (day != today)
          TextButton(
            onPressed: () => onPick(today),
            child: const Text('Today'),
          ),
        IconButton(
          tooltip: 'Next day',
          onPressed: shift(1).isAfter(last) ? null : () => onPick(shift(1)),
          icon: const Icon(Icons.chevron_right_rounded),
        ),
      ],
    );
  }
}

// --------------------------------- Totals ------------------------------------

class _Totals extends StatelessWidget {
  const _Totals({
    required this.chairs,
    required this.appointments,
    required this.cancelled,
    required this.isToday,
  });

  final List<Chair> chairs;
  final int appointments;
  final int cancelled;
  final bool isToday;

  @override
  Widget build(BuildContext context) {
    int count(ChairStatus s) => chairs.where((c) => c.status == s).length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.m),
        child: Row(
          children: [
            _tile('${count(ChairStatus.free)}', 'free', AppColors.success),
            _tile('${count(ChairStatus.busy)}', 'busy', AppColors.warning),
            _tile(
              '${count(ChairStatus.onBreak)}',
              'on break',
              AppColors.textSecondary,
            ),
            _tile(
              '$appointments',
              isToday ? 'booked today' : 'booked',
              AppColors.gold,
              note: cancelled == 0 ? null : '$cancelled cancelled',
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(String value, String label, Color color, {String? note}) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 11.5,
            ),
          ),
          if (note != null)
            Text(
              note,
              style: const TextStyle(color: AppColors.error, fontSize: 11),
            ),
        ],
      ),
    );
  }
}

// --------------------------------- Chairs ------------------------------------

class _ChairPanel extends StatelessWidget {
  const _ChairPanel({
    required this.chair,
    required this.bookings,
    required this.now,
    required this.isToday,
    required this.saving,
    required this.onStatus,
    required this.onCancel,
    this.serving,
    this.onFinishToken,
  });

  final Chair chair;
  final List<Booking> bookings; // active, on this chair, this day

  /// The walk-in token in this chair now, if any.
  final QueueToken? serving;
  final ValueChanged<QueueToken>? onFinishToken;
  final DateTime now;
  final bool isToday;
  final bool saving;
  final ValueChanged<ChairStatus> onStatus;
  final ValueChanged<Booking> onCancel;

  @override
  Widget build(BuildContext context) {
    final color = chairStatusColor(chair.status);
    Booking? current, next;
    if (isToday) {
      for (final b in bookings) {
        if (!b.slotStart.isAfter(now) && b.end.isAfter(now)) current ??= b;
        if (b.slotStart.isAfter(now)) next ??= b;
      }
    }

    // The obvious next step for this chair, as one button.
    Widget? quickAction;
    final walkIn = serving;
    if (walkIn != null) {
      final end = walkIn.expectedEnd;
      quickAction = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'WALK-IN ${walkIn.label} • ${walkIn.callName}'
            '${end == null ? '' : ' • until about ${fmtDateTime(end)}'}',
            style: const TextStyle(
              color: AppColors.gold,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          _QuickAction(
            icon: Icons.check_rounded,
            label: 'Finish ${walkIn.label} – chair free',
            color: AppColors.success,
            onPressed: onFinishToken == null
                ? null
                : () => onFinishToken!(walkIn),
          ),
        ],
      );
    } else if (isToday && chair.status == ChairStatus.busy) {
      quickAction = _QuickAction(
        icon: Icons.check_rounded,
        label: 'Finish – chair free',
        color: AppColors.success,
        onPressed: saving ? null : () => onStatus(ChairStatus.free),
      );
    } else if (isToday &&
        chair.status != ChairStatus.busy &&
        (current ?? next) != null) {
      final b = (current ?? next)!;
      quickAction = _QuickAction(
        icon: Icons.content_cut_rounded,
        label: 'Start ${b.customerLabel}',
        color: AppColors.warning,
        onPressed: saving ? null : () => onStatus(ChairStatus.busy),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.m),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.m),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      chairStatusIcon(chair.status),
                      color: color,
                      size: 19,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s + 2),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          chair.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          '${chair.status.label} ${fmtFor(chair.statusSince, now)}',
                          style: TextStyle(color: color, fontSize: 12.5),
                        ),
                      ],
                    ),
                  ),
                  if (saving)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.gold,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.m),
              ChairStatusSwitch(
                status: chair.status,
                onChanged: saving ? null : onStatus,
              ),
              if (isToday && (current != null || next != null)) ...[
                const SizedBox(height: AppSpacing.m),
                _NowNext(current: current, next: next, now: now),
              ],
              if (quickAction != null) ...[
                const SizedBox(height: AppSpacing.s),
                quickAction,
              ],
              const SizedBox(height: AppSpacing.m),
              Text(
                bookings.isEmpty
                    ? 'No appointments${isToday ? ' today' : ''}.'
                    : '${bookings.length} '
                          '${bookings.length == 1 ? 'appointment' : 'appointments'}',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              for (final b in bookings)
                _AppointmentRow(
                  booking: b,
                  now: now,
                  highlight: b == current,
                  onCancel: () => onCancel(b),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          side: BorderSide(color: color.withValues(alpha: 0.6)),
        ),
      ),
    );
  }
}

class _NowNext extends StatelessWidget {
  const _NowNext({
    required this.current,
    required this.next,
    required this.now,
  });

  final Booking? current;
  final Booking? next;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final b = current ?? next!;
    final String label;
    if (current != null) {
      final left = current!.end.difference(now).inMinutes;
      label = 'NOW • ends in ${left < 1 ? 'under a minute' : '$left min'}';
    } else {
      final wait = next!.slotStart.difference(now).inMinutes;
      label = 'NEXT • ${wait < 1 ? 'starting now' : 'in $wait min'}';
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.s + 2),
      decoration: BoxDecoration(
        color: AppColors.gold.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.button),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: AppColors.gold,
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${b.customerLabel} • ${fmtDateTime(b.slotStart)} – ${fmtDateTime(b.end)}',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          Text(
            b.services.map((s) => s.name).join(', '),
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12.5,
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------- Appointments --------------------------------

class _AppointmentRow extends StatelessWidget {
  const _AppointmentRow({
    required this.booking,
    required this.now,
    required this.highlight,
    required this.onCancel,
  });

  final Booking booking;
  final DateTime now;
  final bool highlight;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final b = booking;
    final past = !b.end.isAfter(now);
    final (payText, payColor) = b.awaitingPayment
        ? ('Awaiting payment', AppColors.warning)
        : b.paid
        ? ('Paid ₹${b.total}', AppColors.success)
        : ('₹${b.total} at salon', AppColors.textSecondary);
    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.s),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s + 2,
        AppSpacing.s,
        0,
        AppSpacing.s,
      ),
      decoration: BoxDecoration(
        color: highlight
            ? AppColors.gold.withValues(alpha: 0.08)
            : AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.button),
        border: Border(
          left: BorderSide(
            color: past ? AppColors.divider : AppColors.gold,
            width: 3,
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fmtDateTime(b.slotStart),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: past
                        ? AppColors.textSecondary
                        : AppColors.textPrimary,
                  ),
                ),
                Text(
                  '${b.minutes} min',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  b.customerLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  b.services.map((s) => s.name).join(', '),
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12.5,
                  ),
                ),
                if (b.notes.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '“${b.notes}”',
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                const SizedBox(height: 2),
                Text(payText, style: TextStyle(color: payColor, fontSize: 12)),
              ],
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Appointment actions',
            color: AppColors.surface,
            icon: const Icon(
              Icons.more_vert_rounded,
              color: AppColors.textSecondary,
            ),
            onSelected: (action) {
              switch (action) {
                case 'call':
                  launchUrl(Uri(scheme: 'tel', path: b.customerPhone));
                case 'email':
                  launchUrl(Uri(scheme: 'mailto', path: b.customerEmail));
                case 'cancel':
                  onCancel();
              }
            },
            itemBuilder: (_) => [
              if (b.customerPhone.isNotEmpty)
                PopupMenuItem(
                  value: 'call',
                  child: ListTile(
                    leading: const Icon(Icons.call_rounded),
                    title: Text('Call ${b.customerPhone}'),
                  ),
                ),
              PopupMenuItem(
                value: 'email',
                child: ListTile(
                  leading: const Icon(Icons.mail_outline_rounded),
                  title: Text(
                    b.customerEmail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const PopupMenuItem(
                value: 'cancel',
                child: ListTile(
                  leading: Icon(
                    Icons.event_busy_rounded,
                    color: AppColors.error,
                  ),
                  title: Text(
                    'Cancel appointment',
                    style: TextStyle(color: AppColors.error),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _UnassignedPanel extends StatelessWidget {
  const _UnassignedPanel({
    required this.bookings,
    required this.now,
    required this.onCancel,
  });

  final List<Booking> bookings;
  final DateTime now;
  final ValueChanged<Booking> onCancel;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'No chair assigned',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const Text(
              'Booked before chairs were set up, or their chair was removed.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
            ),
            for (final b in bookings)
              _AppointmentRow(
                booking: b,
                now: now,
                highlight: false,
                onCancel: () => onCancel(b),
              ),
          ],
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.l),
      child: Column(
        children: [
          Icon(icon, color: AppColors.textSecondary, size: 36),
          const SizedBox(height: AppSpacing.s),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textSecondary),
          ),
          ?action,
        ],
      ),
    );
  }
}

/// Opens the staff dashboard: straight away for an owner with one salon,
/// otherwise after picking which salon.
Future<void> openStaffDashboard(BuildContext context, Profile profile) async {
  final navigator = Navigator.of(context);
  List<Salon> salons;
  try {
    salons = await SalonRepository().fetchManagedSalons(profile);
  } on RepositoryException catch (error) {
    if (context.mounted) showAppMessage(context, error.message);
    return;
  }
  if (!context.mounted) return;
  if (salons.isEmpty) {
    showAppMessage(context, 'You do not manage any salons yet.');
    return;
  }
  final salon = salons.length == 1
      ? salons.single
      : await showModalBottomSheet<Salon>(
          context: context,
          backgroundColor: AppColors.surface,
          builder: (ctx) => SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                const Padding(
                  padding: EdgeInsets.all(AppSpacing.m),
                  child: Text(
                    'Which salon?',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
                for (final s in salons)
                  ListTile(
                    leading: const Icon(Icons.storefront_rounded),
                    title: Text(s.name),
                    subtitle: s.chairs.isEmpty
                        ? null
                        : Text(
                            '${s.freeChairs}/${s.chairs.length} chairs free',
                          ),
                    onTap: () => Navigator.pop(ctx, s),
                  ),
              ],
            ),
          ),
        );
  if (salon == null) return;
  await navigator.push(
    MaterialPageRoute<void>(
      builder: (_) => StaffDashboardScreen(salon: salon, profile: profile),
    ),
  );
}

// ------------------------------ Walk-in queue --------------------------------

class _QueuePanel extends StatelessWidget {
  const _QueuePanel({
    required this.queue,
    required this.now,
    required this.busy,
    required this.onAdd,
    required this.onAction,
  });

  final QueueView queue;
  final DateTime now;
  final Set<String> busy;
  final VoidCallback onAdd;
  final Future<void> Function(QueueToken, String, {bool pickChair}) onAction;

  @override
  Widget build(BuildContext context) {
    final waiting = queue.queue
        .where(
          (t) =>
              t.status == TokenStatus.waiting || t.status == TokenStatus.called,
        )
        .toList();
    final finished = queue.queue.where((t) => !t.status.active).length;
    final String summary;
    if (!queue.open) {
      summary = 'Closed: the queue reopens with the salon.';
    } else if (queue.paused) {
      summary = 'Paused: every chair is on break.';
    } else {
      summary =
          '${queue.waiting} waiting • a new walk-in waits '
          '${fmtWait(queue.waitMinutes ?? 0)}';
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.confirmation_number_rounded,
                  color: AppColors.gold,
                  size: 20,
                ),
                const SizedBox(width: AppSpacing.s),
                const Expanded(
                  child: Text(
                    'Walk-in queue',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton.icon(
                  onPressed: queue.open ? onAdd : null,
                  icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
                  label: const Text('Add walk-in'),
                ),
              ],
            ),
            Text(
              summary,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12.5,
              ),
            ),
            if (finished > 0)
              Text(
                '$finished finished, left or no-show today',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11.5,
                ),
              ),
            if (waiting.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: AppSpacing.s),
                child: Text('Nobody waiting.'),
              ),
            for (final t in waiting) _tokenRow(t),
          ],
        ),
      ),
    );
  }

  Widget _tokenRow(QueueToken t) {
    final wait = t.waitFrom(now);
    final saving = busy.contains(t.id);
    final called = t.status == TokenStatus.called;
    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.s),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s + 2,
        AppSpacing.s,
        0,
        AppSpacing.s,
      ),
      decoration: BoxDecoration(
        color: called
            ? AppColors.success.withValues(alpha: 0.08)
            : AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.button),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            child: Text(
              t.label,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: called ? AppColors.success : AppColors.gold,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${t.callName}${t.walkIn ? ' (at the door)' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  [
                    if (t.services.isNotEmpty)
                      t.services.map((s) => s.name).join(', '),
                    '${t.minutes} min',
                  ].join(' • '),
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12.5,
                  ),
                ),
                Text(
                  called
                      ? 'Called to ${t.chairName ?? 'a chair'}'
                      : (wait == null
                            ? 'Waiting'
                            : 'Expected in ${fmtWait(wait)}'),
                  style: TextStyle(
                    color: called ? AppColors.success : AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          if (saving)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: AppSpacing.s),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.gold,
                ),
              ),
            )
          else
            TextButton(
              onPressed: () =>
                  onAction(t, 'start', pickChair: t.chairId == null),
              child: const Text('Start'),
            ),
          PopupMenuButton<String>(
            tooltip: 'Token actions',
            color: AppColors.surface,
            enabled: !saving,
            icon: const Icon(
              Icons.more_vert_rounded,
              color: AppColors.textSecondary,
            ),
            onSelected: (action) => switch (action) {
              'call' => onAction(t, 'call', pickChair: true),
              'start_on' => onAction(t, 'start', pickChair: true),
              _ => onAction(t, action),
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'call',
                child: ListTile(
                  leading: Icon(Icons.campaign_rounded),
                  title: Text('Call to a chair…'),
                ),
              ),
              PopupMenuItem(
                value: 'start_on',
                child: ListTile(
                  leading: Icon(Icons.event_seat_rounded),
                  title: Text('Start on a chair…'),
                ),
              ),
              PopupMenuItem(
                value: 'no_show',
                child: ListTile(
                  leading: Icon(Icons.person_off_rounded),
                  title: Text('No-show'),
                ),
              ),
              PopupMenuItem(
                value: 'cancel',
                child: ListTile(
                  leading: Icon(Icons.close_rounded, color: AppColors.error),
                  title: Text(
                    'Remove from queue',
                    style: TextStyle(color: AppColors.error),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
