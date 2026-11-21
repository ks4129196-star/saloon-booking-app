import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import '../bookings/my_bookings_screen.dart' show BookingTile, confirmCancelBooking;
import '../core/realtime.dart';
import '../core/theme.dart';
import '../data/salon_repository.dart';
import '../models/profile.dart';
import '../models/salon.dart';

const _categories = [
  'Hair',
  'Beard & Shave',
  'Skin',
  'Hands & Feet',
  'Waxing & Threading',
  'Bridal & Makeup',
  'Other',
];

/// Create a salon (no [salon]) or manage an existing one.
///
/// Available to owners (for salons they own) and admins (for any salon).
class SalonEditorScreen extends StatefulWidget {
  const SalonEditorScreen({super.key, required this.profile, this.salon});

  final Profile profile;
  final Salon? salon;

  @override
  State<SalonEditorScreen> createState() => _SalonEditorScreenState();
}

class _SalonEditorScreenState extends State<SalonEditorScreen> {
  final _repository = SalonRepository();
  late Salon? _salon = widget.salon;

  Future<void> _reload() async {
    final id = _salon?.id;
    if (id == null) return;
    try {
      final fresh = await _repository.fetchSalon(id);
      if (mounted) setState(() => _salon = fresh);
    } on RepositoryException catch (error) {
      if (mounted) showAppMessage(context, error.message);
    }
  }

  Future<void> _created(int id) async {
    try {
      final salon = await _repository.fetchSalon(id);
      if (mounted) setState(() => _salon = salon);
    } on RepositoryException catch (error) {
      if (mounted) showAppMessage(context, error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final salon = _salon;
    if (salon == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Add salon')),
        body: SafeArea(
          child: _DetailsTab(
            profile: widget.profile,
            salon: null,
            onCreated: _created,
            onChanged: _reload,
          ),
        ),
      );
    }

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(salon.name),
          bottom: const TabBar(
            indicatorColor: AppColors.gold,
            labelColor: AppColors.gold,
            unselectedLabelColor: AppColors.textSecondary,
            tabs: [
              Tab(text: 'Details'),
              Tab(text: 'Services'),
              Tab(text: 'Bookings'),
            ],
          ),
        ),
        body: SafeArea(
          child: TabBarView(
            children: [
              _DetailsTab(
                key: ValueKey('details-${salon.id}'),
                profile: widget.profile,
                salon: salon,
                onCreated: _created,
                onChanged: _reload,
              ),
              _ServicesTab(salon: salon, onChanged: _reload),
              _BookingsTab(salon: salon),
            ],
          ),
        ),
      ),
    );
  }
}

// --------------------------------- Details -----------------------------------

class _DetailsTab extends StatefulWidget {
  const _DetailsTab({
    super.key,
    required this.profile,
    required this.salon,
    required this.onCreated,
    required this.onChanged,
  });

  final Profile profile;
  final Salon? salon;
  final ValueChanged<int> onCreated;
  final Future<void> Function() onChanged;

  @override
  State<_DetailsTab> createState() => _DetailsTabState();
}

class _DetailsTabState extends State<_DetailsTab>
    with AutomaticKeepAliveClientMixin {
  final _repository = SalonRepository();
  final _formKey = GlobalKey<FormState>();

  late final _name = TextEditingController(text: widget.salon?.name);
  late final _type = TextEditingController(
    text: widget.salon?.type ?? 'Unisex Salon',
  );
  late final _address = TextEditingController(text: widget.salon?.address);
  late final _phone = TextEditingController(text: widget.salon?.phone);
  late final _lat = TextEditingController(text: widget.salon?.lat.toString());
  late final _lon = TextEditingController(text: widget.salon?.lon.toString());
  late final _staff = TextEditingController(
    text: (widget.salon?.staff ?? 1).toString(),
  );
  late final _highlights = TextEditingController(
    text: widget.salon?.highlights.join(', '),
  );
  late int _openMin = widget.salon?.openMin ?? 10 * 60;
  late int _closeMin = widget.salon?.closeMin ?? 20 * 60;
  late String? _ownerId = widget.salon == null
      ? (widget.profile.isAdmin ? null : widget.profile.id)
      : widget.salon!.ownerId;
  late int _queue = widget.salon?.queue ?? 0;

  List<Profile>? _owners;
  bool _saving = false;
  bool _locating = false;

  bool get _isNew => widget.salon == null;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    if (widget.profile.isAdmin) _loadOwners();
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _type,
      _address,
      _phone,
      _lat,
      _lon,
      _staff,
      _highlights,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadOwners() async {
    try {
      final profiles = await _repository.fetchProfiles();
      if (!mounted) return;
      setState(() {
        _owners = profiles
            .where((p) => p.role == AppRole.owner || p.id == _ownerId)
            .toList();
      });
    } on RepositoryException catch (error) {
      if (mounted) showAppMessage(context, error.message);
    }
  }

  Future<void> _useMyLocation() async {
    setState(() => _locating = true);
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        throw Exception('permission denied');
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      _lat.text = pos.latitude.toStringAsFixed(6);
      _lon.text = pos.longitude.toStringAsFixed(6);
    } catch (_) {
      if (mounted) {
        showAppMessage(
          context,
          'Could not get your location. Enter the coordinates manually.',
        );
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _pickTime({required bool opening}) async {
    final current = opening ? _openMin : _closeMin;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: (current ~/ 60) % 24, minute: current % 60),
    );
    if (picked == null) return;
    setState(() {
      final m = picked.hour * 60 + picked.minute;
      if (opening) {
        _openMin = m;
      } else {
        _closeMin = m == 0 ? 24 * 60 : m;
      }
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_closeMin - _openMin < slotMinutes) {
      showAppMessage(context, 'Closing time must be after opening time.');
      return;
    }
    final draft = SalonDraft(
      ownerId: _ownerId,
      name: _name.text.trim(),
      type: _type.text.trim().isEmpty ? 'Salon' : _type.text.trim(),
      address: _address.text.trim(),
      phone: _phone.text.trim(),
      lat: double.parse(_lat.text.trim()),
      lon: double.parse(_lon.text.trim()),
      openMin: _openMin,
      closeMin: _closeMin,
      staff: int.parse(_staff.text.trim()),
      highlights: _highlights.text
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(),
    );

    setState(() => _saving = true);
    try {
      if (_isNew) {
        final id = await _repository.createSalon(draft);
        if (!mounted) return;
        showAppMessage(context, 'Salon created. Now add its services.');
        widget.onCreated(id);
      } else {
        await _repository.updateSalon(widget.salon!.id, draft);
        if (!mounted) return;
        showAppMessage(context, 'Changes saved.');
        await widget.onChanged();
      }
    } on RepositoryException catch (error) {
      if (mounted) showAppMessage(context, error.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _changeQueue(int delta) async {
    final next = (_queue + delta).clamp(0, 500);
    if (next == _queue) return;
    final previous = _queue;
    setState(() => _queue = next);
    try {
      await _repository.setQueue(widget.salon!.id, next);
    } on RepositoryException catch (error) {
      if (!mounted) return;
      setState(() => _queue = previous);
      showAppMessage(context, error.message);
    }
  }

  Future<void> _delete() async {
    final salon = widget.salon!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Delete salon?'),
        content: Text(
          '${salon.name}, its services and all of its bookings will be '
          'permanently deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _repository.deleteSalon(salon.id);
      if (!mounted) return;
      showAppMessage(context, 'Salon deleted.');
      Navigator.of(context).popUntil((route) => route.isFirst);
    } on RepositoryException catch (error) {
      if (mounted) showAppMessage(context, error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.m),
        children: [
          if (!_isNew) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.m,
                  vertical: AppSpacing.s,
                ),
                child: Row(
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Live queue',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          Text(
                            'People waiting right now. Customers see this '
                            'as the wait time.',
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'One less',
                      onPressed: _queue > 0 ? () => _changeQueue(-1) : null,
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                    Text(
                      '$_queue',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: AppColors.gold,
                      ),
                    ),
                    IconButton(
                      tooltip: 'One more',
                      onPressed: () => _changeQueue(1),
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.m),
          ],
          if (widget.profile.isAdmin) ...[
            DropdownButtonFormField<String?>(
              initialValue: _ownerId,
              decoration: const InputDecoration(
                labelText: 'Owner',
                helperText:
                    'Only users with the Salon owner role are listed. '
                    'Assign roles under Users & roles.',
              ),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('No owner (admins only)'),
                ),
                for (final p in _owners ?? const <Profile>[])
                  DropdownMenuItem<String?>(
                    value: p.id,
                    child: Text(p.displayName),
                  ),
              ],
              onChanged: (v) => setState(() => _ownerId = v),
            ),
            const SizedBox(height: AppSpacing.m),
          ],
          TextFormField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Salon name'),
            textCapitalization: TextCapitalization.words,
            validator: (v) => (v?.trim().length ?? 0) < 2
                ? 'Enter at least 2 characters.'
                : null,
          ),
          const SizedBox(height: AppSpacing.m),
          TextFormField(
            controller: _type,
            decoration: const InputDecoration(
              labelText: 'Type',
              hintText: 'e.g. Barber Shop, Ladies Parlour',
            ),
          ),
          const SizedBox(height: AppSpacing.m),
          TextFormField(
            controller: _address,
            decoration: const InputDecoration(labelText: 'Address'),
          ),
          const SizedBox(height: AppSpacing.m),
          TextFormField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Phone'),
          ),
          const SizedBox(height: AppSpacing.m),
          Row(
            children: [
              Expanded(
                child: _TimeField(
                  label: 'Opens',
                  minutes: _openMin,
                  onTap: () => _pickTime(opening: true),
                ),
              ),
              const SizedBox(width: AppSpacing.m),
              Expanded(
                child: _TimeField(
                  label: 'Closes',
                  minutes: _closeMin,
                  onTap: () => _pickTime(opening: false),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.m),
          TextFormField(
            controller: _staff,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(labelText: 'Number of stylists'),
            validator: (v) {
              final n = int.tryParse(v?.trim() ?? '');
              return n == null || n < 1 || n > 100 ? 'Enter 1 to 100.' : null;
            },
          ),
          const SizedBox(height: AppSpacing.m),
          TextFormField(
            controller: _highlights,
            decoration: const InputDecoration(
              labelText: 'Highlights',
              hintText: 'AC, Parking, UPI accepted',
              helperText: 'Separate with commas.',
            ),
          ),
          const SizedBox(height: AppSpacing.m),
          Row(
            children: [
              Expanded(
                child: _CoordinateField(
                  controller: _lat,
                  label: 'Latitude',
                  max: 90,
                ),
              ),
              const SizedBox(width: AppSpacing.m),
              Expanded(
                child: _CoordinateField(
                  controller: _lon,
                  label: 'Longitude',
                  max: 180,
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _locating ? null : _useMyLocation,
              icon: const Icon(Icons.my_location, size: 18),
              label: Text(
                _locating ? 'Locating…' : 'Use my current location',
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.m),
          SizedBox(
            height: 50,
            child: ElevatedButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.black,
                      ),
                    )
                  : Text(_isNew ? 'Create salon' : 'Save changes'),
            ),
          ),
          if (!_isNew) ...[
            const SizedBox(height: AppSpacing.l),
            OutlinedButton.icon(
              onPressed: _delete,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.error,
                side: const BorderSide(color: AppColors.error),
              ),
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete salon'),
            ),
          ],
          const SizedBox(height: AppSpacing.l),
        ],
      ),
    );
  }
}

class _TimeField extends StatelessWidget {
  const _TimeField({
    required this.label,
    required this.minutes,
    required this.onTap,
  });

  final String label;
  final int minutes;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.button),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: const Icon(Icons.schedule),
        ),
        child: Text(minutes >= 24 * 60 ? 'Midnight' : fmtMinutes(minutes)),
      ),
    );
  }
}

class _CoordinateField extends StatelessWidget {
  const _CoordinateField({
    required this.controller,
    required this.label,
    required this.max,
  });

  final TextEditingController controller;
  final String label;
  final double max;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(
        signed: true,
        decimal: true,
      ),
      decoration: InputDecoration(labelText: label),
      validator: (v) {
        final n = double.tryParse(v?.trim() ?? '');
        return n == null || n.abs() > max ? 'Enter -$max to $max.' : null;
      },
    );
  }
}

// -------------------------------- Services -----------------------------------

class _ServicesTab extends StatelessWidget {
  const _ServicesTab({required this.salon, required this.onChanged});

  final Salon salon;
  final Future<void> Function() onChanged;

  Future<void> _edit(BuildContext context, [Service? service]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _ServiceDialog(salonId: salon.id, service: service),
    );
    if (saved == true) await onChanged();
  }

  Future<void> _delete(BuildContext context, Service service) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Remove service?'),
        content: Text(
          '${service.name} will no longer be bookable. '
          'Existing bookings keep it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await SalonRepository().deleteService(service.id);
      await onChanged();
    } on RepositoryException catch (error) {
      if (context.mounted) showAppMessage(context, error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.gold,
        foregroundColor: Colors.black,
        onPressed: () => _edit(context),
        icon: const Icon(Icons.add),
        label: const Text('Add service'),
      ),
      body: salon.services.isEmpty
          ? const Center(
              child: Text(
                'No services yet. Customers cannot book until you add one.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondary),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.m,
                AppSpacing.m,
                AppSpacing.m,
                96,
              ),
              itemCount: salon.services.length,
              separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.s),
              itemBuilder: (context, i) {
                final service = salon.services[i];
                return Card(
                  child: ListTile(
                    title: Text(service.name),
                    subtitle: Text(
                      '${service.category} • ${service.minutes} min',
                      style: const TextStyle(color: AppColors.textSecondary),
                    ),
                    onTap: () => _edit(context, service),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '₹${service.price}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        IconButton(
                          tooltip: 'Remove ${service.name}',
                          icon: const Icon(
                            Icons.delete_outline,
                            color: AppColors.textSecondary,
                          ),
                          onPressed: () => _delete(context, service),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _ServiceDialog extends StatefulWidget {
  const _ServiceDialog({required this.salonId, this.service});

  final int salonId;
  final Service? service;

  @override
  State<_ServiceDialog> createState() => _ServiceDialogState();
}

class _ServiceDialogState extends State<_ServiceDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.service?.name);
  late final _price = TextEditingController(
    text: widget.service?.price.toString(),
  );
  late final _minutes = TextEditingController(
    text: (widget.service?.minutes ?? 30).toString(),
  );
  late String _category = widget.service?.category ?? _categories.first;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _price.dispose();
    _minutes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await SalonRepository().saveService(
        id: widget.service?.id,
        salonId: widget.salonId,
        name: _name.text.trim(),
        price: int.parse(_price.text.trim()),
        minutes: int.parse(_minutes.text.trim()),
        category: _category,
      );
      if (mounted) Navigator.pop(context, true);
    } on RepositoryException catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showAppMessage(context, error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories = {..._categories, _category}.toList();
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(widget.service == null ? 'Add service' : 'Edit service'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _name,
                autofocus: widget.service == null,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Name'),
                validator: (v) =>
                    (v?.trim().isEmpty ?? true) ? 'Enter a name.' : null,
              ),
              const SizedBox(height: AppSpacing.m),
              DropdownButtonFormField<String>(
                initialValue: _category,
                decoration: const InputDecoration(labelText: 'Category'),
                items: [
                  for (final c in categories)
                    DropdownMenuItem(value: c, child: Text(c)),
                ],
                onChanged: (v) => setState(() => _category = v ?? _category),
              ),
              const SizedBox(height: AppSpacing.m),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _price,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: 'Price',
                        prefixText: '₹ ',
                      ),
                      validator: (v) => int.tryParse(v?.trim() ?? '') == null
                          ? 'Required'
                          : null,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.m),
                  Expanded(
                    child: TextFormField(
                      controller: _minutes,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: 'Minutes',
                      ),
                      validator: (v) {
                        final n = int.tryParse(v?.trim() ?? '');
                        return n == null || n < 5 || n > 600
                            ? '5 to 600'
                            : null;
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _saving ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

// -------------------------------- Bookings -----------------------------------

class _BookingsTab extends StatefulWidget {
  const _BookingsTab({required this.salon});

  final Salon salon;

  @override
  State<_BookingsTab> createState() => _BookingsTabState();
}

class _BookingsTabState extends State<_BookingsTab> {
  final _repository = SalonRepository();
  List<Booking>? _bookings;
  String? _error;
  StreamSubscription<RealtimeEvent>? _live;

  @override
  void initState() {
    super.initState();
    _load();
    // New and cancelled bookings for this salon arrive live.
    Realtime.instance.watchSalonBookings(widget.salon.id);
    _live = Realtime.instance.events
        .where(
          (event) =>
              event.type == 'booking:changed' &&
              event.salonId == widget.salon.id,
        )
        .listen((_) => _load());
  }

  @override
  void dispose() {
    _live?.cancel();
    Realtime.instance.unwatchSalonBookings(widget.salon.id);
    super.dispose();
  }

  Future<void> _load() async {
    final now = DateTime.now();
    try {
      final bookings = await _repository.fetchSalonBookings(
        widget.salon.id,
        DateTime(now.year, now.month, now.day),
      );
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
    final bookings = _bookings;
    final now = DateTime.now();
    if (bookings == null) {
      return Center(
        child: _error == null
            ? const CircularProgressIndicator(color: AppColors.gold)
            : Text(
                _error!,
                style: const TextStyle(color: AppColors.textSecondary),
              ),
      );
    }
    return RefreshIndicator(
      color: AppColors.gold,
      backgroundColor: AppColors.surface,
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.m),
        children: [
          const Text(
            'Today and upcoming',
            style: TextStyle(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.s),
          if (bookings.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 80),
              child: Center(
                child: Text(
                  'No bookings yet.',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              ),
            ),
          for (final b in bookings)
            BookingTile(
              booking: b,
              now: now,
              title: b.customerEmail.isEmpty ? 'Customer' : b.customerEmail,
              onCancel: b.isUpcoming(now) ? () => _cancel(b) : null,
            ),
        ],
      ),
    );
  }
}
