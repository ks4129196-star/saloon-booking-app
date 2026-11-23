import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/salon_repository.dart';
import '../models/profile.dart';
import '../models/salon.dart';
import 'salon_editor_screen.dart';
import 'staff_dashboard_screen.dart';

/// Owners see the salons they own; admins see every salon.
class ManageSalonsScreen extends StatefulWidget {
  const ManageSalonsScreen({super.key, required this.profile});

  final Profile profile;

  @override
  State<ManageSalonsScreen> createState() => _ManageSalonsScreenState();
}

class _ManageSalonsScreenState extends State<ManageSalonsScreen> {
  final _repository = SalonRepository();
  List<Salon>? _salons;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final salons = await _repository.fetchManagedSalons(widget.profile);
      if (!mounted) return;
      setState(() {
        _salons = salons;
        _error = null;
      });
    } on RepositoryException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    }
  }

  Future<void> _openEditor([Salon? salon]) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            SalonEditorScreen(profile: widget.profile, salon: salon),
      ),
    );
    if (mounted) _load();
  }

  Future<void> _openDashboard(Salon salon) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            StaffDashboardScreen(salon: salon, profile: widget.profile),
      ),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final salons = _salons;
    final now = DateTime.now();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.profile.isAdmin ? 'Manage salons' : 'My salons'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.gold,
        foregroundColor: Colors.black,
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add_business_rounded),
        label: const Text('Add salon'),
      ),
      body: SafeArea(
        child: salons == null
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
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.m,
                    AppSpacing.s,
                    AppSpacing.m,
                    96,
                  ),
                  children: [
                    if (salons.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 120),
                        child: Text(
                          widget.profile.isAdmin
                              ? 'No salons yet. Add the first one.'
                              : 'You do not own any salons yet. Add yours, '
                                    'or ask an admin to assign one to you.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                    for (final s in salons)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.s),
                        child: Card(
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.m,
                              vertical: AppSpacing.xs,
                            ),
                            title: Text(
                              s.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Text(
                              '${s.type} • ${s.services.length} services • '
                              '${s.isOpen(now) ? 'open, ${s.queue} waiting' : 'closed'}'
                              '${s.chairs.isEmpty ? '' : ' • ${s.freeChairs}/${s.chairs.length} chairs free'}'
                              '${widget.profile.isAdmin && s.ownerId == null ? ' • no owner' : ''}',
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: 'Staff dashboard',
                                  icon: const Icon(
                                    Icons.dashboard_rounded,
                                    color: AppColors.gold,
                                  ),
                                  onPressed: () => _openDashboard(s),
                                ),
                                const Icon(Icons.chevron_right_rounded),
                              ],
                            ),
                            onTap: () => _openEditor(s),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}
