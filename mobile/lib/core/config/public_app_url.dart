/// The deployed web app's address, which auth emails link to.
///
/// The phone app has no deep link (no intent filter in AndroidManifest.xml),
/// so a password-reset link opens the web app's `/reset-password` page in the
/// browser — on the phone or any other device — where the new password is
/// chosen; the user then signs in here with it. Sign-up confirmation links go
/// to the web app's root for the same reason.
///
/// Supabase only honours a redirect that is in its Redirect URLs allow-list;
/// anything else falls back to the dashboard's Site URL (`localhost:3000` on a
/// new project). So the address must be a real, public https URL: a loopback
/// address would be unreachable from the phone that opens the email.
library;

class PublicAppUrl {
  const PublicAppUrl._();

  /// The `.env` key holding the address, e.g. `https://expenses.example.com`.
  static const String envKey = 'PUBLIC_APP_URL';

  static const String resetPasswordPath = '/reset-password';

  static const Set<String> _loopbackHosts = <String>{
    'localhost',
    '127.0.0.1',
    '::1',
    '0.0.0.0',
    // The Android emulator's alias for the host machine.
    '10.0.2.2',
  };

  /// [raw] normalised (no trailing slash), or null when it is missing or not
  /// an absolute, public https URL without query or fragment. Null makes
  /// Supabase use the project's Site URL.
  static String? resolve(String? raw) {
    final String value = (raw ?? '').trim();
    if (value.isEmpty) return null;
    final Uri? uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    final String host = uri.host.toLowerCase();
    if (_loopbackHosts.contains(host) || host.endsWith('.localhost')) {
      return null;
    }
    return '${uri.origin}${uri.path}'.replaceFirst(RegExp(r'/+$'), '');
  }

  /// The page a reset email links to, or null to let Supabase use the Site URL.
  static String? resetPasswordUrl(String? base) =>
      base == null ? null : '$base$resetPasswordPath';

  /// Where a sign-up confirmation link lands, or null for the Site URL.
  static String? confirmEmailUrl(String? base) => base == null ? null : '$base/';
}
