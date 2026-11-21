/// Roles used by the local demo app to decide what to show.
enum AppRole {
  customer,
  owner,
  admin;

  static AppRole parse(Object? value) => AppRole.values.firstWhere(
    (role) => role.name == value,
    orElse: () => AppRole.customer,
  );

  String get label => switch (this) {
    AppRole.customer => 'Customer',
    AppRole.owner => 'Salon owner',
    AppRole.admin => 'Admin',
  };
}

class Profile {
  const Profile({
    required this.id,
    required this.email,
    required this.role,
    this.fullName,
  });

  final String id;
  final String email;
  final String? fullName;
  final AppRole role;

  bool get isAdmin => role == AppRole.admin;
  bool get isOwner => role == AppRole.owner;

  /// Owners manage their own salons; admins manage every salon.
  bool get canManageSalons => isOwner || isAdmin;

  String get displayName {
    final name = fullName?.trim() ?? '';
    return name.isNotEmpty ? name : email;
  }

  factory Profile.fromJson(Map<String, dynamic> json) => Profile(
    id: json['id'] as String,
    email: (json['email'] as String?) ?? '',
    fullName: json['full_name'] as String?,
    role: AppRole.parse(json['role']),
  );
}
