import 'dart:async';

import 'package:flutter/material.dart';

import '../core/realtime.dart';
import '../core/theme.dart';
import '../data/salon_repository.dart';
import '../models/profile.dart';
import '../models/salon.dart';

class MyBookingsScreen extends StatefulWidget {
  const MyBookingsScreen({super.key, required this.profile});

  final Profile profile;

  @override
  State<MyBookingsScreen> createState() => _MyBookingsScreenState();
}

class _MyBookingsScreenState extends State<MyBookingsScreen> {
  final _repository = SalonRepository();
  List<Booking>? _bookings;
  String? _error;

  StreamSubscription<RealtimeEvent>? _live;

  @override
  void initState() {
    super.initState();
    _load();
    // e.g. the salon cancelled a booking, or an online payment went through.
    _live = Realtime.instance.events
        .where((event) => event.type == 'booking:changed')
        .listen((_) => _load());
  }

  @override
  void dispose() {
    _live?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final bookings = await _repository.fetchMyBookings(widget.profile.id);
      if (!mounted) return;
      setState(() {
        _bookings = bookings;
        _error = null;
      });
    } on RepositoryException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    }
  }

  Future<void> _cancel(Booking booking) async {
    final ok = await confirmCancelBooking(context, booking);
    if (!ok || !mounted) return;
    try {
      await _repository.cancelBooking(booking.id);
      if (!mounted) return;
      showAppMessage(context, 'Booking cancelled.');
      _load();
    } on RepositoryException catch (error) {
      if (mounted) showAppMessage(context, error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final bookings = _bookings;
    final upcoming =
        bookings?.where((b) => b.isUpcoming(now)).toList().reversed.toList() ??
        [];
    final past = bookings?.where((b) => !b.isUpcoming(now)).toList() ?? [];

    return Scaffold(
      appBar: AppBar(title: const Text('My bookings')),
      body: SafeArea(
        child: bookings == null
            ? Center(
                child: _error == null
                    ? const CircularProgressIndicator(color: AppColors.gold)
                    : Text(
                        _error!,
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
              )
            : RefreshIndicator(
                color: AppColors.gold,
                backgroundColor: AppColors.surface,
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.all(AppSpacing.m),
                  children: [
                    if (bookings.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 120),
                        child: Center(
                          child: Text(
                            'No bookings yet. Pick a salon to book a slot.',
                            style: TextStyle(color: AppColors.textSecondary),
                          ),
                        ),
                      ),
                    if (upcoming.isNotEmpty) ...[
                      const _SectionTitle('Upcoming'),
                      for (final b in upcoming)
                        BookingTile(
                          booking: b,
                          now: now,
                          title: b.salonName,
                          onCancel: () => _cancel(b),
                        ),
                    ],
                    if (past.isNotEmpty) ...[
                      const _SectionTitle('Past & cancelled'),
                      for (final b in past)
                        BookingTile(booking: b, now: now, title: b.salonName),
                    ],
                  ],
                ),
              ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s, bottom: AppSpacing.s),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: AppColors.gold,
          fontSize: 12,
          letterSpacing: 1,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// One booking row; used by customers (My bookings) and salon owners.
class BookingTile extends StatelessWidget {
  const BookingTile({
    super.key,
    required this.booking,
    required this.now,
    required this.title,
    this.onCancel,
  });

  final Booking booking;
  final DateTime now;
  final String title;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final b = booking;
    final end = b.slotStart.add(Duration(minutes: b.minutes));
    final status = b.cancelled
        ? ('Cancelled', AppColors.error)
        : b.isUpcoming(now)
        ? ('Confirmed', AppColors.success)
        : ('Completed', AppColors.textSecondary);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.m),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        decorationColor: AppColors.textSecondary,
                      ),
                    ),
                  ),
                  Text(
                    status.$1,
                    style: TextStyle(
                      color: status.$2,
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${fmtDay(b.slotStart, now)} • ${fmtDateTime(b.slotStart)} – ${fmtDateTime(end)}',
                style: const TextStyle(color: AppColors.gold),
              ),
              const SizedBox(height: AppSpacing.s),
              Text(
                [
                  b.services.map((e) => e.name).join(', '),
                  ?b.chairName,
                ].join(' • '),
                style: const TextStyle(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Text(
                    '₹${b.total}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  if (onCancel != null && !b.cancelled)
                    TextButton(
                      onPressed: onCancel,
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.error,
                      ),
                      child: const Text('Cancel booking'),
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

Future<bool> confirmCancelBooking(BuildContext context, Booking booking) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text('Cancel booking?'),
      content: Text(
        '${fmtDay(booking.slotStart, DateTime.now())} at '
        '${fmtDateTime(booking.slotStart)}. The slot will be freed for others.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Keep it'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.error,
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Cancel booking'),
        ),
      ],
    ),
  );
  return ok == true;
}
