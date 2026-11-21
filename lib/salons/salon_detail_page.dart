import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/realtime.dart';
import '../core/theme.dart';
import '../data/salon_repository.dart';
import '../models/profile.dart';
import '../models/salon.dart';
import '../owner/salon_editor_screen.dart';
import '../payments/razorpay_checkout.dart';
import 'home_screen.dart' show WaitBadge;

enum _PayChoice { atSalon, online }

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
  Set<DateTime> _taken = {};
  bool _loadingSlots = true;
  bool _booking = false;
  DateTime? _slotStart;

  Salon get s => _salon;

  bool get _canManage =>
      widget.profile.isAdmin ||
      (widget.profile.isOwner && s.ownerId == widget.profile.id);

  int get _total => _selected.fold(0, (a, e) => a + e.price);
  int get _minutes => _selected.fold(0, (a, e) => a + e.minutes);

  StreamSubscription<RealtimeEvent>? _live;

  @override
  void initState() {
    super.initState();
    _loadSlots();
    // Another customer booked or the owner changed the salon: refresh.
    _live = Realtime.instance.events
        .where((event) => event.salonId == s.id)
        .listen((event) {
          if (event.type == 'slots:changed') {
            _loadSlots();
          } else if (event.type == 'salon:changed' ||
              event.type == 'salon:deleted') {
            _reloadSalon();
          }
        });
  }

  @override
  void dispose() {
    _live?.cancel();
    super.dispose();
  }

  Future<void> _loadSlots() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    try {
      final taken = await _repository.fetchTakenSlots(
        today,
        today.add(const Duration(days: 1)),
        salonId: s.id,
      );
      if (!mounted) return;
      setState(() {
        _taken = taken[s.id] ?? {};
        _loadingSlots = false;
      });
    } on RepositoryException catch (error) {
      if (!mounted) return;
      setState(() => _loadingSlots = false);
      showAppMessage(context, error.message);
    }
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
      return;
    }
    await _loadSlots();
  }

  Future<void> _open(Uri uri) async {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) showAppMessage(context, 'Could not open this link');
  }

  Future<void> _book(Slot slot) async {
    final choice = await showDialog<_PayChoice>(
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
            Text(
              onlinePaymentSupported
                  ? 'Pay now with UPI or card, or pay at the salon.'
                  : 'Pay at the salon.',
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          if (onlinePaymentSupported)
            OutlinedButton(
              onPressed: () => Navigator.pop(ctx, _PayChoice.atSalon),
              child: const Text('Pay at salon'),
            ),
          ElevatedButton(
            onPressed: () => Navigator.pop(
              ctx,
              onlinePaymentSupported ? _PayChoice.online : _PayChoice.atSalon,
            ),
            child: Text(onlinePaymentSupported ? 'Pay now' : 'Confirm'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;

    setState(() => _booking = true);
    try {
      final payment = await _repository.createBooking(
        salonId: s.id,
        slotStart: slot.start,
        serviceIds: _selected.map((e) => e.id),
        payOnline: choice == _PayChoice.online,
      );
      if (!mounted) return;
      setState(() {
        _taken = {..._taken, slot.start};
        _selected.clear();
        _slotStart = null;
      });
      if (payment == null) {
        showAppMessage(
          context,
          'Booked at ${fmtDateTime(slot.start)}. See it under My bookings.',
        );
        return;
      }

      final result = await openRazorpayCheckout(payment);
      if (!mounted) return;
      if (!result.succeeded) {
        showAppMessage(
          context,
          '${result.error} The slot is held for 15 minutes, then released.',
        );
        return;
      }
      await _repository.verifyPayment(
        orderId: result.orderId!,
        paymentId: result.paymentId!,
        signature: result.signature!,
      );
      if (!mounted) return;
      showAppMessage(
        context,
        'Paid and booked at ${fmtDateTime(slot.start)}. See it under My bookings.',
      );
    } on RepositoryException catch (error) {
      if (!mounted) return;
      showAppMessage(context, error.message);
      setState(() => _slotStart = null);
      _reloadSalon();
    } finally {
      if (mounted) setState(() => _booking = false);
    }
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
    final slots = s.slotsToday(now, _taken);
    Slot? chosen;
    for (final sl in slots) {
      if (sl.start == _slotStart && !sl.taken) chosen = sl;
    }
    final canBook = _selected.isNotEmpty && chosen != null && !_booking;

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
                child: _booking
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.black,
                        ),
                      )
                    : const Text('Book slot'),
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

            // Slots
            const SizedBox(height: AppSpacing.l),
            const Text(
              "Today's available slots",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: AppSpacing.s),
            if (_loadingSlots)
              const Padding(
                padding: EdgeInsets.all(AppSpacing.m),
                child: Center(
                  child: CircularProgressIndicator(color: AppColors.gold),
                ),
              )
            else if (slots.isEmpty)
              Text(
                s.isOpen(now)
                    ? 'No more slots today.'
                    : 'Closed right now. Opens at ${fmtMinutes(s.openMin)}.',
                style: const TextStyle(color: AppColors.textSecondary),
              )
            else ...[
              Wrap(
                spacing: AppSpacing.s,
                runSpacing: AppSpacing.s,
                children: slots.map((sl) {
                  final selected = sl.start == _slotStart && !sl.taken;
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
                        : (_) => setState(() => _slotStart = sl.start),
                  );
                }).toList(),
              ),
              const SizedBox(height: AppSpacing.s),
              const Text(
                'Struck-through slots are already booked.',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
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
