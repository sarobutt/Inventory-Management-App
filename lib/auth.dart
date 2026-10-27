import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'firebase_options.dart';

// =====================================================================
//  Users & sign-in
//
//  Firestore:
//    users/{uid}          username, displayName, email, phone, role, active
//    usernames/{username} uid, email        (lets people sign in with a username)
//    meta/app             adminUid          (exists once the first admin is set up)
//
//  Sign-in uses Firebase Authentication with email + password behind the
//  scenes; people only ever type their username.
// =====================================================================

enum Role { admin, staff }

class AppUser {
  final String uid;
  final String username;
  final String displayName;
  final String email;
  final String phone;
  final Role role;
  final bool active;

  const AppUser({
    required this.uid,
    required this.username,
    required this.displayName,
    required this.email,
    required this.phone,
    required this.role,
    required this.active,
  });

  bool get isAdmin => role == Role.admin;
  bool get isStaff => role == Role.staff;
  String get roleLabel => isAdmin ? 'Admin' : 'Staff';
  String get initials {
    final parts = displayName.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return username.isEmpty ? '?' : username[0].toUpperCase();
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return (parts[0][0] + parts.last[0]).toUpperCase();
  }

  factory AppUser.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const <String, dynamic>{};
    return AppUser(
      uid: doc.id,
      username: (d['username'] as String?) ?? '',
      displayName: (d['displayName'] as String?) ?? '',
      email: (d['email'] as String?) ?? '',
      phone: (d['phone'] as String?) ?? '',
      role: d['role'] == 'admin' ? Role.admin : Role.staff,
      active: (d['active'] as bool?) ?? true,
    );
  }
}

/// The signed-in user, available everywhere (set by the AuthGate in main.dart).
final ValueNotifier<AppUser?> currentUser = ValueNotifier<AppUser?>(null);

/// Makes [currentUser] available to every screen via `Session.of(context)`.
class Session extends InheritedWidget {
  final AppUser? user;
  const Session({super.key, required this.user, required super.child});

  static AppUser? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<Session>()?.user;

  /// True when the signed-in user is an admin.
  static bool isAdmin(BuildContext context) => of(context)?.isAdmin ?? false;

  @override
  bool updateShouldNotify(Session oldWidget) => oldWidget.user != user;
}

class AuthFailure implements Exception {
  final String message;
  AuthFailure(this.message);
  @override
  String toString() => message;
}

class Auth {
  Auth._();

  static FirebaseAuth get _auth => FirebaseAuth.instance;
  static FirebaseFirestore get _fs => FirebaseFirestore.instance;
  static CollectionReference<Map<String, dynamic>> get _users => _fs.collection('users');
  static CollectionReference<Map<String, dynamic>> get _usernames => _fs.collection('usernames');
  static DocumentReference<Map<String, dynamic>> get _meta => _fs.collection('meta').doc('app');

  static String normalize(String username) => username.trim().toLowerCase();

  /// Returns an error message, or null if the username is valid.
  static String? validateUsername(String? value) {
    final u = normalize(value ?? '');
    if (u.isEmpty) return 'Username is required';
    if (u.length < 3) return 'At least 3 characters';
    if (u.length > 30) return 'At most 30 characters';
    if (!RegExp(r'^[a-z0-9._-]+$').hasMatch(u)) return 'Use letters, numbers, dot, dash or underscore only';
    return null;
  }

  static String? validateEmail(String? value) {
    final e = (value ?? '').trim();
    if (e.isEmpty) return 'Email is required';
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(e)) return 'Enter a valid email';
    return null;
  }

  static String? validatePassword(String? value) {
    final p = value ?? '';
    if (p.length < 6) return 'At least 6 characters';
    return null;
  }

  static String _friendly(FirebaseAuthException e) {
    switch (e.code) {
      case 'wrong-password':
      case 'invalid-credential':
      case 'user-not-found':
      case 'invalid-login-credentials':
        return 'Wrong username or password.';
      case 'user-disabled':
        return 'This account has been disabled.';
      case 'too-many-requests':
        return 'Too many attempts. Please wait a few minutes and try again.';
      case 'email-already-in-use':
        return 'That email is already used by another account.';
      case 'invalid-email':
        return 'That email address is not valid.';
      case 'weak-password':
        return 'Password is too weak (use at least 6 characters).';
      case 'requires-recent-login':
        return 'Please sign out and sign in again, then retry.';
      case 'network-request-failed':
        return 'No internet connection.';
      default:
        return e.message ?? 'Something went wrong (${e.code}).';
    }
  }

  // ----- Setup -----

  /// True once the first admin account has been created.
  static Future<bool> isSetUp() async => (await _meta.get()).exists;

  /// Creates the very first admin. Only works while no admin exists.
  static Future<void> createFirstAdmin({
    required String username,
    required String displayName,
    required String email,
    required String password,
  }) async {
    final u = normalize(username);
    if (await isSetUp()) throw AuthFailure('An admin already exists. Please sign in.');
    if ((await _usernames.doc(u).get()).exists) throw AuthFailure('That username is taken.');

    UserCredential cred;
    try {
      cred = await _auth.createUserWithEmailAndPassword(email: email.trim(), password: password);
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(_friendly(e));
    }
    final uid = cred.user!.uid;
    try {
      final batch = _fs.batch();
      batch.set(_users.doc(uid), {
        'username': u,
        'displayName': displayName.trim(),
        'email': email.trim(),
        'phone': '',
        'role': 'admin',
        'active': true,
        'createdAt': FieldValue.serverTimestamp(),
      });
      batch.set(_usernames.doc(u), {'uid': uid, 'email': email.trim()});
      batch.set(_meta, {'adminUid': uid, 'createdAt': FieldValue.serverTimestamp()});
      await batch.commit();
    } catch (e) {
      // Roll back the login account so setup can be retried.
      await cred.user?.delete();
      rethrow;
    }
  }

  // ----- Sign in / out -----

  static Future<void> signIn(String username, String password) async {
    final u = normalize(username);
    if (u.isEmpty || password.isEmpty) throw AuthFailure('Enter your username and password.');
    final doc = await _usernames.doc(u).get();
    final email = doc.data()?['email'] as String?;
    if (email == null) throw AuthFailure('Wrong username or password.');
    try {
      await _auth.signInWithEmailAndPassword(email: email, password: password);
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(_friendly(e));
    }
  }

  static Future<void> signOut() => _auth.signOut();

  /// Emails a password-reset link to the address attached to [username].
  static Future<String> sendPasswordReset(String username) async {
    final doc = await _usernames.doc(normalize(username)).get();
    final email = doc.data()?['email'] as String?;
    if (email == null) throw AuthFailure('No account with that username.');
    try {
      await _auth.sendPasswordResetEmail(email: email);
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(_friendly(e));
    }
    return _maskEmail(email);
  }

  static String _maskEmail(String email) {
    final at = email.indexOf('@');
    if (at <= 1) return email;
    return '${email[0]}${'*' * (at - 1)}${email.substring(at)}';
  }

  static Future<void> changePassword(String currentPassword, String newPassword) async {
    final user = _auth.currentUser;
    if (user == null || user.email == null) throw AuthFailure('Not signed in.');
    try {
      final cred = EmailAuthProvider.credential(email: user.email!, password: currentPassword);
      await user.reauthenticateWithCredential(cred);
      await user.updatePassword(newPassword);
    } on FirebaseAuthException catch (e) {
      if (e.code == 'wrong-password' || e.code == 'invalid-credential') {
        throw AuthFailure('Current password is wrong.');
      }
      throw AuthFailure(_friendly(e));
    }
  }

  // ----- Profiles -----

  static Stream<AppUser?> watchUser(String uid) =>
      _users.doc(uid).snapshots().map((d) => d.exists ? AppUser.fromDoc(d) : null);

  static Stream<List<AppUser>> watchUsers() => _users.snapshots().map((s) {
        final list = s.docs.map(AppUser.fromDoc).toList();
        list.sort((a, b) {
          if (a.active != b.active) return a.active ? -1 : 1;
          return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
        });
        return list;
      });

  /// Anyone can update their own name and phone.
  static Future<void> updateMyProfile({required String displayName, required String phone}) {
    final uid = _auth.currentUser!.uid;
    return _users.doc(uid).update({
      'displayName': displayName.trim(),
      'phone': phone.trim(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  // ----- Admin: manage users -----

  /// Creates a new user account without signing the admin out
  /// (uses a second, temporary Firebase connection).
  static Future<void> createUser({
    required String username,
    required String displayName,
    required String email,
    required String phone,
    required String password,
    required Role role,
  }) async {
    final u = normalize(username);
    if ((await _usernames.doc(u).get()).exists) throw AuthFailure('That username is taken.');

    FirebaseApp app;
    try {
      app = Firebase.app('userCreator');
    } catch (_) {
      app = await Firebase.initializeApp(name: 'userCreator', options: DefaultFirebaseOptions.currentPlatform);
    }
    final auth2 = FirebaseAuth.instanceFor(app: app);

    UserCredential cred;
    try {
      cred = await auth2.createUserWithEmailAndPassword(email: email.trim(), password: password);
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(_friendly(e));
    }

    try {
      final uid = cred.user!.uid;
      final batch = _fs.batch(); // written as the admin
      batch.set(_users.doc(uid), {
        'username': u,
        'displayName': displayName.trim(),
        'email': email.trim(),
        'phone': phone.trim(),
        'role': role == Role.admin ? 'admin' : 'staff',
        'active': true,
        'createdAt': FieldValue.serverTimestamp(),
        'createdBy': _auth.currentUser?.uid,
      });
      batch.set(_usernames.doc(u), {'uid': uid, 'email': email.trim()});
      await batch.commit();
    } catch (e) {
      await cred.user?.delete(); // roll back the login account
      rethrow;
    } finally {
      await auth2.signOut();
    }
  }

  static Future<void> adminUpdateUser(
    String uid, {
    required String displayName,
    required String phone,
    required Role role,
    required bool active,
  }) {
    return _users.doc(uid).update({
      'displayName': displayName.trim(),
      'phone': phone.trim(),
      'role': role == Role.admin ? 'admin' : 'staff',
      'active': active,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Sends a reset link to that user's email (admin "reset password").
  static Future<void> sendResetFor(AppUser user) async {
    try {
      await _auth.sendPasswordResetEmail(email: user.email);
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(_friendly(e));
    }
  }
}
