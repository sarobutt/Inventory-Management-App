import 'package:flutter/material.dart';

import '../auth.dart';
import '../widgets.dart';

/// Admin only: list, add and edit user accounts.
class UsersScreen extends StatelessWidget {
  const UsersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final me = Session.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Users')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const UserFormScreen(), fullscreenDialog: true),
        ),
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('User'),
      ),
      body: StreamBuilder<List<AppUser>>(
        stream: Auth.watchUsers(),
        builder: (context, snap) {
          if (snap.hasError) return ErrorState(snap.error!);
          if (!snap.hasData) return const Loading();
          final users = snap.data!;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
            children: [
              for (final u in users)
                Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    leading: CircleAvatar(child: Text(u.initials)),
                    title: Text(
                      u.displayName.isEmpty ? u.username : u.displayName,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        decoration: u.active ? null : TextDecoration.lineThrough,
                      ),
                    ),
                    subtitle: Text('@${u.username} · ${u.roleLabel}${u.active ? '' : ' · Disabled'}'
                        '${u.uid == me?.uid ? ' · You' : ''}'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => UserFormScreen(user: u), fullscreenDialog: true),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Add a user (user == null) or edit one.
class UserFormScreen extends StatefulWidget {
  final AppUser? user;
  const UserFormScreen({super.key, this.user});

  @override
  State<UserFormScreen> createState() => _UserFormScreenState();
}

class _UserFormScreenState extends State<UserFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.user?.displayName ?? '');
  late final _username = TextEditingController(text: widget.user?.username ?? '');
  late final _email = TextEditingController(text: widget.user?.email ?? '');
  late final _phone = TextEditingController(text: widget.user?.phone ?? '');
  final _password = TextEditingController();
  late Role _role = widget.user?.role ?? Role.staff;
  late bool _active = widget.user?.active ?? true;
  bool _saving = false;
  bool _showPassword = false;

  bool get _isEdit => widget.user != null;

  @override
  void dispose() {
    for (final c in [_name, _username, _email, _phone, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final isSelf = widget.user?.uid == Session.of(context)?.uid;
    if (isSelf && (!_active || _role != Role.admin)) {
      showMessage(context, 'You can’t disable yourself or remove your own admin role.');
      return;
    }
    setState(() => _saving = true);
    try {
      if (_isEdit) {
        await Auth.adminUpdateUser(
          widget.user!.uid,
          displayName: _name.text,
          phone: _phone.text,
          role: _role,
          active: _active,
        );
      } else {
        await Auth.createUser(
          username: _username.text,
          displayName: _name.text,
          email: _email.text,
          phone: _phone.text,
          password: _password.text,
          role: _role,
        );
      }
      if (mounted) {
        Navigator.pop(context);
        showMessage(context, _isEdit ? 'User updated' : 'User created. Share the username and password with them.');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showMessage(context, e is AuthFailure ? e.message : 'Could not save: $e');
      }
    }
  }

  Future<void> _sendReset() async {
    try {
      await Auth.sendResetFor(widget.user!);
      if (mounted) showMessage(context, 'Password reset link sent to ${widget.user!.email}');
    } catch (e) {
      if (mounted) showMessage(context, e is AuthFailure ? e.message : 'Could not send: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Edit user' : 'New user')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Full name *'),
              validator: (v) => (v ?? '').trim().isEmpty ? 'Name is required' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _username,
              enabled: !_isEdit,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'Username *',
                helperText: _isEdit ? 'Usernames can’t be changed' : 'They’ll use this to sign in',
              ),
              validator: _isEdit ? null : Auth.validateUsername,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _email,
              enabled: !_isEdit,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'Email *',
                helperText: _isEdit ? 'Email can’t be changed here' : 'Used for password resets only',
              ),
              validator: _isEdit ? null : Auth.validateEmail,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Phone', hintText: 'Optional'),
            ),
            if (!_isEdit) ...[
              const SizedBox(height: 16),
              TextFormField(
                controller: _password,
                obscureText: !_showPassword,
                decoration: InputDecoration(
                  labelText: 'Starting password *',
                  helperText: 'They can change it later in My profile',
                  suffixIcon: IconButton(
                    icon: Icon(_showPassword ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                    onPressed: () => setState(() => _showPassword = !_showPassword),
                  ),
                ),
                validator: Auth.validatePassword,
              ),
            ],
            const SizedBox(height: 20),
            Text('Role', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            SegmentedButton<Role>(
              segments: const [
                ButtonSegment(value: Role.staff, label: Text('Staff'), icon: Icon(Icons.badge_outlined)),
                ButtonSegment(value: Role.admin, label: Text('Admin'), icon: Icon(Icons.admin_panel_settings_outlined)),
              ],
              selected: {_role},
              onSelectionChanged: (s) => setState(() => _role = s.first),
            ),
            const SizedBox(height: 6),
            Text(
              _role == Role.admin
                  ? 'Full access, including prices, approvals and managing users.'
                  : 'Can view stock and print tables (no prices). Stock changes are sent to an admin for approval.',
              style: TextStyle(color: muted, fontSize: 13),
            ),
            if (_isEdit) ...[
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Account active'),
                subtitle: const Text('Turn off to block this person from signing in'),
                value: _active,
                onChanged: (v) => setState(() => _active = v),
              ),
              OutlinedButton.icon(
                onPressed: _sendReset,
                icon: const Icon(Icons.lock_reset),
                label: const Text('Send password reset email'),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              child: _saving
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(_isEdit ? 'Save changes' : 'Create user'),
            ),
          ],
        ),
      ),
    );
  }
}
