import 'package:flutter/material.dart';

import '../auth.dart';
import '../widgets.dart';
import 'audit_screen.dart';
import 'orders_screen.dart';
import 'requests_screen.dart';
import 'users_screen.dart';

/// "My profile": details, change password, sign out (+ admin shortcuts).
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final me = Session.of(context);
    if (me == null) return const Scaffold(body: Loading());
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('My profile')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: CircleAvatar(
              radius: 40,
              child: Text(me.initials, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(height: 12),
          Center(child: Text(me.displayName, style: Theme.of(context).textTheme.titleLarge)),
          const SizedBox(height: 6),
          Center(
            child: Chip(
              avatar: Icon(me.isAdmin ? Icons.admin_panel_settings : Icons.badge_outlined, size: 18),
              label: Text(me.roleLabel),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Column(
              children: [
                ListTile(leading: const Icon(Icons.alternate_email), title: const Text('Username'), subtitle: Text(me.username)),
                ListTile(leading: const Icon(Icons.email_outlined), title: const Text('Email'), subtitle: Text(me.email)),
                ListTile(
                  leading: const Icon(Icons.phone_outlined),
                  title: const Text('Phone'),
                  subtitle: Text(me.phone.isEmpty ? 'Not set' : me.phone),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: const Text('Edit my details'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => EditProfileScreen(user: me), fullscreenDialog: true),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.password),
                  title: const Text('Change password'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ChangePasswordScreen(), fullscreenDialog: true),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.pending_actions_outlined),
                  title: Text(me.isAdmin ? 'Stock requests' : 'My stock requests'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RequestsScreen())),
                ),
                if (me.isAdmin)
                  ListTile(
                    leading: const Icon(Icons.receipt_long_outlined),
                    title: const Text('Purchase orders'),
                    subtitle: const Text('Sell products to external customers'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const OrdersScreen())),
                  ),
                if (me.isAdmin)
                  ListTile(
                    leading: const Icon(Icons.history),
                    title: const Text('Stock audit'),
                    subtitle: const Text('Every stock change, with filters'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AuditScreen())),
                  ),
                if (me.isAdmin)
                  ListTile(
                    leading: const Icon(Icons.fact_check_outlined),
                    title: const Text('Approvals audit'),
                    subtitle: const Text('All staff requests: approved, rejected, pending'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () =>
                        Navigator.push(context, MaterialPageRoute(builder: (_) => const ApprovalAuditScreen())),
                  ),
                if (me.isAdmin)
                  ListTile(
                    leading: const Icon(Icons.group_outlined),
                    title: const Text('Manage users'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const UsersScreen())),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () async {
              Navigator.of(context).popUntil((r) => r.isFirst);
              await Auth.signOut();
            },
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
              foregroundColor: scheme.error,
            ),
            icon: const Icon(Icons.logout),
            label: const Text('Sign out'),
          ),
        ],
      ),
    );
  }
}

class EditProfileScreen extends StatefulWidget {
  final AppUser user;
  const EditProfileScreen({super.key, required this.user});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.user.displayName);
  late final _phone = TextEditingController(text: widget.user.phone);
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await Auth.updateMyProfile(displayName: _name.text, phone: _phone.text);
      if (mounted) {
        Navigator.pop(context);
        showMessage(context, 'Profile updated');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Edit my details')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Name *'),
              validator: (v) => (v ?? '').trim().isEmpty ? 'Name is required' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Phone', hintText: 'Optional'),
            ),
            const SizedBox(height: 8),
            Text('Username, email and role can only be changed by an admin.',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              child: _saving
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}

class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _current.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await Auth.changePassword(_current.text, _new.text);
      if (mounted) {
        Navigator.pop(context);
        showMessage(context, 'Password changed');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showMessage(context, e is AuthFailure ? e.message : 'Could not change password: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Change password')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _current,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Current password'),
              validator: (v) => (v ?? '').isEmpty ? 'Required' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _new,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'New password'),
              validator: Auth.validatePassword,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _confirm,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Confirm new password'),
              validator: (v) => v != _new.text ? 'Passwords don’t match' : null,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              child: _saving
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Change password'),
            ),
          ],
        ),
      ),
    );
  }
}
