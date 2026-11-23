import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';
import '../models/salon.dart';

/// "about 12 min", "under a minute", "now".
String fmtWait(int minutes) {
  if (minutes <= 0) return 'now';
  if (minutes < 60) return 'about $minutes min';
  final h = minutes ~/ 60, m = minutes % 60;
  return m == 0 ? 'about $h h' : 'about $h h $m min';
}

/// What someone joining the queue filled in.
class QueueRequest {
  const QueueRequest({
    required this.serviceIds,
    required this.name,
    required this.phone,
    this.minutes,
  });

  final List<int> serviceIds;
  final String name;
  final String phone;

  /// Staff only: a length when no services were picked.
  final int? minutes;
}

/// Asks for the services, name and phone of someone joining the queue.
/// [forStaff] adds a walk-in (name required, optional length).
class JoinQueueDialog extends StatefulWidget {
  const JoinQueueDialog({
    super.key,
    required this.salon,
    this.initialServices = const {},
    this.initialName,
    this.forStaff = false,
  });

  final Salon salon;
  final Set<Service> initialServices;
  final String? initialName;
  final bool forStaff;

  @override
  State<JoinQueueDialog> createState() => _JoinQueueDialogState();
}

class _JoinQueueDialogState extends State<JoinQueueDialog> {
  final _form = GlobalKey<FormState>();
  late final Set<Service> _services = {...widget.initialServices};
  late final _name = TextEditingController(text: widget.initialName);
  final _phone = TextEditingController();
  int _minutes = 30;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_form.currentState!.validate()) return;
    Navigator.pop(
      context,
      QueueRequest(
        serviceIds: _services.map((s) => s.id).toList(),
        name: _name.text.trim(),
        phone: _phone.text.trim(),
        minutes: widget.forStaff && _services.isEmpty ? _minutes : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final total = _services.fold(0, (sum, s) => sum + s.minutes);
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(widget.forStaff ? 'Add a walk-in' : 'Get a queue token'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _form,
          child: ListView(
            shrinkWrap: true,
            children: [
              Text(
                widget.forStaff
                    ? 'For someone at the door without the app.'
                    : 'Join the walk-in queue now. We will show your place '
                          'and update the wait as the queue moves.',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12.5,
                ),
              ),
              const SizedBox(height: AppSpacing.m),
              if (widget.salon.services.isNotEmpty) ...[
                const Text(
                  'Services',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                for (final s in widget.salon.services)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: _services.contains(s),
                    activeColor: AppColors.gold,
                    checkColor: Colors.black,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(s.name),
                    subtitle: Text(
                      '${s.minutes} min • ₹${s.price}',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                    onChanged: (v) => setState(() {
                      v == true ? _services.add(s) : _services.remove(s);
                    }),
                  ),
                Text(
                  _services.isEmpty
                      ? (widget.forStaff
                            ? 'No services picked: choose how long below.'
                            : 'Not sure yet? Skip this; the salon will ask.')
                      : '$total min in total',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: AppSpacing.m),
              ],
              if (widget.forStaff && _services.isEmpty) ...[
                DropdownButtonFormField<int>(
                  initialValue: _minutes,
                  decoration: const InputDecoration(
                    labelText: 'About how long',
                  ),
                  items: [
                    for (final m in const [10, 15, 20, 30, 45, 60, 90, 120])
                      DropdownMenuItem(value: m, child: Text('$m min')),
                  ],
                  onChanged: (v) => setState(() => _minutes = v ?? 30),
                ),
                const SizedBox(height: AppSpacing.m),
              ],
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                maxLength: 80,
                decoration: InputDecoration(
                  labelText: widget.forStaff ? 'Name' : 'Name (optional)',
                  helperText: 'So staff can call you when it is your turn.',
                  counterText: '',
                ),
                validator: (v) => widget.forStaff && (v?.trim().isEmpty ?? true)
                    ? 'Enter a name to call them by.'
                    : null,
              ),
              const SizedBox(height: AppSpacing.s),
              TextFormField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                maxLength: 20,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9+()\- ]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Phone (optional)',
                  counterText: '',
                ),
                validator: (v) {
                  final digits = (v ?? '').replaceAll(RegExp(r'[^0-9]'), '');
                  return digits.isNotEmpty &&
                          (digits.length < 6 || digits.length > 15)
                      ? 'Enter a valid phone number.'
                      : null;
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _submit,
          child: Text(widget.forStaff ? 'Add to queue' : 'Get token'),
        ),
      ],
    );
  }
}

/// The signed-in customer's own token: number, place and expected wait.
class MyTokenCard extends StatelessWidget {
  const MyTokenCard({
    super.key,
    required this.token,
    required this.now,
    this.showSalon = false,
    this.onCancel,
    this.onTap,
  });

  final QueueToken token;
  final DateTime now;
  final bool showSalon;
  final VoidCallback? onCancel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = token;
    final wait = t.waitFrom(now);
    final (headline, detail, color) = switch (t.status) {
      TokenStatus.called => (
        "It's your turn",
        'Please go to ${t.chairName ?? 'the counter'} now.',
        AppColors.success,
      ),
      TokenStatus.serving => (
        "You're in the chair",
        t.chairName == null ? 'Enjoy!' : 'At ${t.chairName}.',
        AppColors.success,
      ),
      _ => (
        t.ahead == 0
            ? "You're next"
            : '${t.ahead ?? '?'} ${t.ahead == 1 ? 'person' : 'people'} ahead of you',
        wait == null
            ? 'Waiting for a chair.'
            : 'Expected wait ${fmtWait(wait)}.',
        AppColors.gold,
      ),
    };
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: BorderSide(color: color.withValues(alpha: 0.6)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.m),
          child: Row(
            children: [
              Container(
                width: 64,
                height: 64,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(AppRadius.button),
                ),
                child: Text(
                  t.label,
                  style: TextStyle(
                    color: color,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      showSalon && t.salonName != null
                          ? 'Your token at ${t.salonName}'
                          : 'Your token',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                    Text(
                      headline,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(detail, style: TextStyle(color: color, fontSize: 13)),
                  ],
                ),
              ),
              if (onCancel != null && t.status != TokenStatus.serving)
                TextButton(
                  onPressed: onCancel,
                  style: TextButton.styleFrom(foregroundColor: AppColors.error),
                  child: const Text('Leave'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A salon's walk-in queue for customers: who is in the chairs, how many
/// wait, and the wait for someone joining now.
class SalonQueueCard extends StatelessWidget {
  const SalonQueueCard({
    super.key,
    required this.queue,
    required this.onJoin,
    required this.joinLabel,
  });

  final QueueView? queue;
  final VoidCallback? onJoin;
  final String joinLabel;

  @override
  Widget build(BuildContext context) {
    final q = queue;
    final String status;
    if (q == null) {
      status = 'Loading the queue…';
    } else if (!q.open) {
      status = 'The walk-in queue opens when the salon does.';
    } else if (q.paused) {
      status = 'Paused: every chair is on break.';
    } else if (q.waiting == 0 && (q.waitMinutes ?? 0) == 0) {
      status = 'Nobody waiting: walk in now.';
    } else {
      status =
          '${q.waiting} waiting • a new token waits '
          '${fmtWait(q.waitMinutes ?? 0)}';
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
                const Text(
                  'Walk-in queue',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                if (q != null && q.nowServing.isNotEmpty)
                  Text(
                    'Serving ${q.nowServing.map((t) => t.label).join(', ')}',
                    style: const TextStyle(
                      color: AppColors.success,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              status,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            if (q != null && q.queue.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.s),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final t in q.queue.take(12))
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: t.status == TokenStatus.called
                            ? AppColors.success.withValues(alpha: 0.15)
                            : AppColors.surface,
                        borderRadius: BorderRadius.circular(AppRadius.chip),
                      ),
                      child: Text(
                        t.label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: t.status == TokenStatus.called
                              ? AppColors.success
                              : AppColors.textPrimary,
                        ),
                      ),
                    ),
                  if (q.queue.length > 12)
                    Text(
                      '+${q.queue.length - 12} more',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ],
            if (onJoin != null) ...[
              const SizedBox(height: AppSpacing.m),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: onJoin,
                  icon: const Icon(Icons.add_rounded),
                  label: Text(joinLabel),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
