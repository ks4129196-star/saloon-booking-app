import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/realtime.dart';
import '../core/theme.dart';
import '../data/salon_repository.dart';
import '../models/profile.dart';
import '../models/salon.dart';
import '../payments/razorpay_checkout.dart';

/// How many days ahead customers can book (the server allows 14).
const bookingDays = 14;

/// The appointment form: date, chair, time from the live free slots, and the
/// customer's details. Pops with `true` once booked.
class BookingFormScreen extends StatefulWidget {
  const BookingFormScreen({
    super.key,
    required this.salon,
    required this.services,
    required this.profile,
  });

  final Salon salon;
  final List<Service> services;
  final Profile profile;

  @override
  State<BookingFormScreen> createState() => _BookingFormScreenState();
}

class _BookingFormScreenState extends State<BookingFormScreen> {
  final _repository = SalonRepository();
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.profile.fullName);
  final _phone = TextEditingController();
  final _notes = TextEditingController();

  late Salon _salon = widget.salon;
  late DateTime _day = _today;
  int? _chairId; // null: any free chair
  DateTime? _start;
  bool _payOnline = false;

  List<AvailableSlot>? _slots;
  String? _slotsError;
  bool _submitting = false;
  int _request = 0;

  StreamSubscription<RealtimeEvent>? _live;
  Timer? _liveReload;

  static DateTime get _today {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  int get _minutes => widget.services.fold(0, (sum, s) => sum + s.minutes);
  int get _total => widget.services.fold(0, (sum, s) => sum + s.price);

  /// Times the chosen chair (or any chair) is free for the whole appointment.
  bool _fits(AvailableSlot slot) =>
      _chairId == null ? slot.available : slot.chairIds.contains(_chairId);

  @override
  void initState() {
    super.initState();
    _loadSlots();
    // Someone else booked or cancelled, or the owner changed chairs.
    _live = Realtime.instance.events
        .where((event) => event.salonId == _salon.id)
        .listen((event) {
          if (!mounted) return;
          if (event.type == 'salon:changed') {
            setState(() {
              _salon = Salon.fromJson(event.data);
              if (_chairId != null &&
                  !_salon.chairs.any((c) => c.id == _chairId)) {
                _chairId = null;
              }
            });
          }
          if (event.type == 'salon:deleted') {
            showAppMessage(context, 'This salon is no longer listed.');
            Navigator.of(context).pop();
            return;
          }
          _liveReload?.cancel();
          _liveReload = Timer(const Duration(milliseconds: 400), _loadSlots);
        });
  }

  @override
  void dispose() {
    _live?.cancel();
    _liveReload?.cancel();
    _name.dispose();
    _phone.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _loadSlots() async {
    final request = ++_request;
    final day = _day;
    setState(() => _slotsError = null);
    try {
      final slots = await _repository.fetchAvailability(
        _salon.id,
        day,
        _minutes,
      );
      if (!mounted || request != _request) return;
      setState(() {
        _slots = slots;
        // The chosen time was just taken: ask for another.
        final start = _start;
        if (start != null && !slots.any((s) => s.start == start && _fits(s))) {
          _start = null;
          showAppMessage(context, 'That time was just booked. Pick another.');
        }
      });
    } on RepositoryException catch (error) {
      if (!mounted || request != _request) return;
      setState(() => _slotsError = error.message);
    }
  }

  void _pickDay(DateTime day) {
    if (day == _day) return;
    setState(() {
      _day = day;
      _start = null;
      _slots = null;
    });
    _loadSlots();
  }

  void _pickChair(int? chairId) {
    setState(() {
      _chairId = chairId;
      final start = _start;
      if (start != null &&
          !(_slots ?? const []).any((s) => s.start == start && _fits(s))) {
        _start = null;
      }
    });
  }

  Future<void> _submit() async {
    final start = _start;
    if (start == null) {
      showAppMessage(context, 'Pick a time.');
      return;
    }
    if (!_form.currentState!.validate()) return;

    setState(() => _submitting = true);
    try {
      final (booking, payment) = await _repository.createBooking(
        salonId: _salon.id,
        slotStart: start,
        serviceIds: widget.services.map((s) => s.id),
        payOnline: _payOnline,
        chairId: _chairId,
        customerName: _name.text.trim(),
        customerPhone: _phone.text.trim(),
        notes: _notes.text.trim(),
      );
      if (!mounted) return;

      if (payment != null) {
        final result = await openRazorpayCheckout(payment);
        if (!mounted) return;
        if (!result.succeeded) {
          showAppMessage(
            context,
            '${result.error} Your chair is held for 15 minutes, then released.',
          );
          Navigator.of(context).pop(true);
          return;
        }
        await _repository.verifyPayment(
          orderId: result.orderId!,
          paymentId: result.paymentId!,
          signature: result.signature!,
        );
        if (!mounted) return;
      }

      await _showConfirmation(booking, paid: payment != null);
      if (mounted) Navigator.of(context).pop(true);
    } on RepositoryException catch (error) {
      if (!mounted) return;
      showAppMessage(context, error.message);
      setState(() => _start = null);
      _loadSlots();
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _showConfirmation(Booking booking, {required bool paid}) {
    final now = DateTime.now();
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        icon: const Icon(
          Icons.check_circle_rounded,
          color: AppColors.success,
          size: 44,
        ),
        title: Text(paid ? 'Paid and booked' : 'Booked'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _salon.name,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '${fmtDay(booking.slotStart, now)}, '
              '${fmtDateTime(booking.slotStart)} – ${fmtDateTime(booking.end)}',
              style: const TextStyle(color: AppColors.gold),
            ),
            if (booking.chairName != null) Text(booking.chairName!),
            const SizedBox(height: AppSpacing.s),
            const Text(
              'You can see or cancel it under My bookings.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final start = _start;
    return Scaffold(
      appBar: AppBar(title: const Text('Book an appointment')),
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
                      '₹$_total  •  $_minutes min',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      start == null
                          ? 'Pick a time'
                          : '${fmtDay(start, now)}, ${fmtDateTime(start)} – '
                                '${fmtDateTime(start.add(Duration(minutes: _minutes)))}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: start == null
                            ? AppColors.textSecondary
                            : AppColors.gold,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              ElevatedButton(
                onPressed: start == null || _submitting ? null : _submit,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.l,
                    vertical: 14,
                  ),
                ),
                child: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.black,
                        ),
                      )
                    : Text(_payOnline ? 'Pay & book' : 'Confirm booking'),
              ),
            ],
          ),
        ),
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.m),
          children: [
            _Summary(salon: _salon, services: widget.services),
            const SizedBox(height: AppSpacing.l),

            const _Heading('Date'),
            SizedBox(
              height: 44,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: bookingDays,
                separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.s),
                itemBuilder: (context, i) {
                  final day = DateTime(
                    _today.year,
                    _today.month,
                    _today.day + i,
                  );
                  final selected = day == _day;
                  return ChoiceChip(
                    label: Text(fmtDay(day, now)),
                    selected: selected,
                    showCheckmark: false,
                    selectedColor: AppColors.gold,
                    backgroundColor: AppColors.card,
                    side: BorderSide.none,
                    labelStyle: TextStyle(
                      color: selected ? Colors.black : AppColors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                    onSelected: (_) => _pickDay(day),
                  );
                },
              ),
            ),
            const SizedBox(height: AppSpacing.l),

            if (_salon.chairs.length > 1) ...[
              const _Heading('Chair'),
              Wrap(
                spacing: AppSpacing.s,
                runSpacing: AppSpacing.s,
                children: [
                  _chairChip(null, 'Any free chair'),
                  for (final chair in _salon.chairs)
                    _chairChip(chair.id, chair.name),
                ],
              ),
              const SizedBox(height: AppSpacing.l),
            ],

            _Heading('Time', trailing: '$_minutes min • updated live'),
            _timeGrid(now),
            const SizedBox(height: AppSpacing.l),

            const _Heading('Your details'),
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              maxLength: 80,
              decoration: const InputDecoration(
                labelText: 'Name',
                counterText: '',
              ),
              validator: (v) => (v?.trim().isEmpty ?? true)
                  ? 'Enter the name the salon should call.'
                  : null,
            ),
            const SizedBox(height: AppSpacing.m),
            TextFormField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.next,
              maxLength: 20,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9+()\- ]')),
              ],
              decoration: const InputDecoration(
                labelText: 'Phone (optional)',
                helperText: 'So the salon can reach you if something changes.',
                counterText: '',
              ),
              validator: (v) {
                final digits = (v ?? '').replaceAll(RegExp(r'[^0-9]'), '');
                if (digits.isEmpty) return null;
                return digits.length < 6 || digits.length > 15
                    ? 'Enter a valid phone number.'
                    : null;
              },
            ),
            const SizedBox(height: AppSpacing.m),
            TextFormField(
              controller: _notes,
              maxLength: 500,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Notes for the stylist (optional)',
                hintText: 'e.g. Short on the sides, allergic to henna',
              ),
            ),

            if (onlinePaymentSupported) ...[
              const SizedBox(height: AppSpacing.m),
              const _Heading('Payment'),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: false,
                    icon: Icon(Icons.storefront_rounded, size: 18),
                    label: Text('Pay at salon'),
                  ),
                  ButtonSegment(
                    value: true,
                    icon: Icon(Icons.credit_card_rounded, size: 18),
                    label: Text('Pay now'),
                  ),
                ],
                selected: {_payOnline},
                onSelectionChanged: (v) => setState(() => _payOnline = v.first),
              ),
            ],
            const SizedBox(height: AppSpacing.l),
          ],
        ),
      ),
    );
  }

  Widget _chairChip(int? chairId, String label) {
    final selected = _chairId == chairId;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      selectedColor: AppColors.gold,
      backgroundColor: AppColors.card,
      side: BorderSide.none,
      labelStyle: TextStyle(
        color: selected ? Colors.black : AppColors.textPrimary,
        fontWeight: FontWeight.w600,
      ),
      onSelected: (_) => _pickChair(chairId),
    );
  }

  Widget _timeGrid(DateTime now) {
    final slots = _slots;
    if (_slotsError != null && slots == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _slotsError!,
            style: const TextStyle(color: AppColors.textSecondary),
          ),
          TextButton(onPressed: _loadSlots, child: const Text('Try again')),
        ],
      );
    }
    if (slots == null) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.m),
        child: Center(child: CircularProgressIndicator(color: AppColors.gold)),
      );
    }
    if (_salon.chairs.isEmpty) {
      return const Text(
        'This salon is not taking bookings right now.',
        style: TextStyle(color: AppColors.textSecondary),
      );
    }
    if (slots.isEmpty) {
      return Text(
        _day == _today
            ? 'No more times today. Try another day.'
            : 'No times this day: the salon is closed or these services '
                  'run past closing time.',
        style: const TextStyle(color: AppColors.textSecondary),
      );
    }
    final open = slots.where(_fits).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: AppSpacing.s,
          runSpacing: AppSpacing.s,
          children: [
            for (final slot in slots)
              _TimeChip(
                slot: slot,
                fits: _fits(slot),
                selected: slot.start == _start,
                showChairs: _chairId == null && _salon.chairs.length > 1,
                onTap: () => setState(() => _start = slot.start),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.s),
        Text(
          open == 0
              ? 'Fully booked this day. Try another day'
                    '${_chairId == null ? '' : ' or any free chair'}.'
              : 'Struck-through times are booked.',
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
        ),
      ],
    );
  }
}

class _TimeChip extends StatelessWidget {
  const _TimeChip({
    required this.slot,
    required this.fits,
    required this.selected,
    required this.showChairs,
    required this.onTap,
  });

  final AvailableSlot slot;
  final bool fits;
  final bool selected;
  final bool showChairs;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final free = slot.chairIds.length;
    return Semantics(
      button: true,
      selected: selected,
      enabled: fits,
      label:
          '${fmtDateTime(slot.start)}, '
          '${fits ? (showChairs ? '$free free' : 'free') : 'booked'}',
      child: ExcludeSemantics(
        child: InkWell(
          onTap: fits ? onTap : null,
          borderRadius: BorderRadius.circular(AppRadius.button),
          child: Container(
            width: 92,
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.s),
            decoration: BoxDecoration(
              color: selected
                  ? AppColors.gold
                  : (fits ? AppColors.card : AppColors.surface),
              borderRadius: BorderRadius.circular(AppRadius.button),
            ),
            child: Column(
              children: [
                Text(
                  fmtDateTime(slot.start),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: selected
                        ? Colors.black
                        : (fits
                              ? AppColors.textPrimary
                              : AppColors.textSecondary),
                    decoration: fits ? null : TextDecoration.lineThrough,
                  ),
                ),
                if (showChairs && fits)
                  Text(
                    '$free ${free == 1 ? 'chair' : 'chairs'}',
                    style: TextStyle(
                      fontSize: 11,
                      color: selected ? Colors.black87 : AppColors.success,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.salon, required this.services});

  final Salon salon;
  final List<Service> services;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              salon.name,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            if (salon.address.isNotEmpty)
              Text(
                salon.address,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12.5,
                ),
              ),
            const Divider(height: AppSpacing.l, color: AppColors.divider),
            for (final s in services)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Expanded(child: Text(s.name)),
                    Text(
                      '${s.minutes} min',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12.5,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.m),
                    SizedBox(
                      width: 64,
                      child: Text(
                        '₹${s.price}',
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text, {this.trailing});

  final String text;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s),
      child: Row(
        children: [
          Text(
            text,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          if (trailing != null) ...[
            const SizedBox(width: AppSpacing.s),
            Text(
              trailing!,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
