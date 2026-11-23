import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/salon_repository.dart';
import '../models/profile.dart';
import '../salons/home_screen.dart' show RoleBadge;

/// Admin-only: list every user and change their role. The database refuses
/// the request for anyone who is not an admin, and admins cannot change
/// their own role.
class UsersScreen extends StatefulWidget {
  const UsersScreen({super.key, required this.profile});

  final Profile profile;

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  final _repository = SalonRepository();
  List<Profile>? _profiles;
  String? _error;
  String _query = '';
  final Set<String> _saving = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final profiles = await _repository.fetchProfiles();
      if (!mounted) return;
      setState(() {
        _profiles = profiles;
        _error = null;
      });
    } on RepositoryException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    }
  }

  Future<void> _setRole(Profile user, AppRole role) async {
    if (role == user.role) return;
    if (role == AppRole.admin) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('Make admin?'),
          content: Text(
            '${user.displayName} will be able to edit every salon, see all '
            'bookings and change anyone\'s role.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Make admin'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }

    setState(() => _saving.add(user.id));
    try {
      await _repository.setUserRole(user.id, role);
      if (!mounted) return;
      showAppMessage(context, '${user.displayName} is now ${role.label}.');
      await _load();
    } on RepositoryException catch (error) {
      if (mounted) showAppMessage(context, error.message);
    } finally {
      if (mounted) setState(() => _saving.remove(user.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final profiles = _profiles;
    final q = _query.trim().toLowerCase();
    final visible =
        profiles
            ?.where(
              (p) =>
                  q.isEmpty ||
                  p.email.toLowerCase().contains(q) ||
                  (p.fullName?.toLowerCase().contains(q) ?? false),
            )
            .toList() ??
        [];

    return Scaffold(
      appBar: AppBar(title: const Text('Users & roles')),
      body: SafeArea(
        child: profiles == null
            ? Center(
                child: _error == null
                    ? const CircularProgressIndicator(color: AppColors.gold)
                    : Text(
                        _error!,
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
              )
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(AppSpacing.m),
                    child: TextField(
                      onChanged: (v) => setState(() => _query = v),
                      decoration: const InputDecoration(
                        hintText: 'Search by email or name',
                        prefixIcon: Icon(Icons.search),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: AppSpacing.m),
                    child: Text(
                      'Customers book. Salon owners also manage the salons '
                      'they own. Admins manage everything.',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.s),
                  Expanded(
                    child: RefreshIndicator(
                      color: AppColors.gold,
                      backgroundColor: AppColors.surface,
                      onRefresh: _load,
                      child: ListView.separated(
                        padding: const EdgeInsets.all(AppSpacing.m),
                        itemCount: visible.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(height: AppSpacing.s),
                        itemBuilder: (_, i) => _userTile(visible[i]),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _userTile(Profile user) {
    final isMe = user.id == widget.profile.id;
    final saving = _saving.contains(user.id);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.m,
          AppSpacing.s,
          AppSpacing.s,
          AppSpacing.s,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isMe ? '${user.displayName} (you)' : user.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  RoleBadge(role: user.role),
                ],
              ),
            ),
            if (saving)
              const Padding(
                padding: EdgeInsets.all(AppSpacing.m),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.gold,
                  ),
                ),
              )
            else
              PopupMenuButton<AppRole>(
                tooltip: isMe
                    ? 'You cannot change your own role'
                    : 'Change role',
                enabled: !isMe,
                color: AppColors.surface,
                onSelected: (role) => _setRole(user, role),
                itemBuilder: (_) => [
                  for (final role in AppRole.values)
                    CheckedPopupMenuItem(
                      value: role,
                      checked: role == user.role,
                      child: Text(role.label),
                    ),
                ],
                icon: Icon(
                  Icons.manage_accounts_rounded,
                  color: isMe ? AppColors.divider : AppColors.gold,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
