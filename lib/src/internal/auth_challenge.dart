/// An authentication challenge from a `WWW-Authenticate` field.
class AuthChallenge {
  /// Lowercase auth-scheme, such as `digest`.
  final String scheme;

  /// The challenge's parameters (or token68) as sent, without the scheme.
  final String params;

  const AuthChallenge(this.scheme, this.params);
}

final _schemeStart = RegExp(r"^([!#$%&'*+.^_`|~0-9A-Za-z-]+)(?:\s+(.*))?$");

/// Split `WWW-Authenticate` field values into challenges (RFC 9110 §11.6.1),
/// which may be listed several to a line.
List<AuthChallenge> parseAuthChallenges(Iterable<String> fieldValues) {
  final challenges = <AuthChallenge>[];
  String? scheme;
  final params = <String>[];

  void flush() {
    final current = scheme;
    if (current != null) {
      challenges.add(AuthChallenge(current, params.join(', ')));
    }
    params.clear();
  }

  for (final value in fieldValues) {
    for (final item in _splitOutsideQuotes(value)) {
      final match = _schemeStart.firstMatch(item);
      // `token=...` continues the current challenge; a bare token or
      // `token rest` starts a new one.
      if (match != null && !item.startsWith(RegExp(r'[^\s=]+\s*='))) {
        flush();
        scheme = match.group(1)!.toLowerCase();
        final rest = match.group(2)?.trim();
        if (rest != null && rest.isNotEmpty) params.add(rest);
      } else if (scheme != null) {
        params.add(item);
      }
    }
  }
  flush();
  return challenges;
}

/// Split [value] on commas that are outside quoted strings, dropping empty
/// list elements (RFC 9110 §5.6.1).
Iterable<String> _splitOutsideQuotes(String value) sync* {
  var start = 0;
  var quoted = false;
  for (var i = 0; i < value.length; i++) {
    final char = value[i];
    if (quoted && char == r'\') {
      i++;
    } else if (char == '"') {
      quoted = !quoted;
    } else if (char == ',' && !quoted) {
      final item = value.substring(start, i).trim();
      if (item.isNotEmpty) yield item;
      start = i + 1;
    }
  }
  final item = value.substring(start).trim();
  if (item.isNotEmpty) yield item;
}
