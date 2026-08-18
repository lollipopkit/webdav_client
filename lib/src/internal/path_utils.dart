/// Join [path0] and [path1] ensuring exactly one slash boundary between them.
String joinPath(String path0, String path1) {
  while (path0.isNotEmpty && path0.endsWith('/')) {
    path0 = path0.substring(0, path0.length - 1);
  }

  while (path1.isNotEmpty && path1.startsWith('/')) {
    path1 = path1.substring(1);
  }

  if (path0.isEmpty && path1.isEmpty) {
    return '/';
  }

  return path0.isEmpty
      ? '/$path1'
      : path1.isEmpty
          ? '$path0/'
          : '$path0/$path1';
}

/// Resolve [target] against [baseUrl] in a WebDAV-aware manner.
///
/// Preserves percent-encoding of special characters (such as `%2F` for `/`)
/// that would otherwise be decoded and lost through `Uri.pathSegments`.
///
/// Mirrors SabreDAV's `Client::getAbsoluteUrl` helper:
/// - Absolute URIs are returned verbatim.
/// - Network-path references (`//host/path`) adopt the base scheme.
/// - For path-only targets we split the raw string (preserving encoding),
///   compute dot-segment normalization on raw segments, and then decide
///   whether to replace or append to the base path using the same prefix
///   logic as the original `resolveAgainstBaseUrl`.
String resolveAgainstBaseUrl(String baseUrl, String target) {
  final trimmed = target.trim();
  if (trimmed.isEmpty) {
    return Uri.parse(baseUrl).toString();
  }

  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    return Uri.parse(trimmed).toString();
  }

  final baseUri = Uri.parse(baseUrl);

  if (trimmed.startsWith('//')) {
    final scheme = baseUri.scheme;
    if (scheme.isEmpty) {
      return Uri.parse(trimmed).toString();
    }
    return Uri.parse('$scheme:$trimmed').toString();
  }

  // Extract raw path, query, fragment preserving percent-encoding.
  var rawTarget = trimmed;
  String? query;
  String? fragment;

  final fi = rawTarget.indexOf('#');
  if (fi != -1) {
    fragment = rawTarget.substring(fi + 1);
    rawTarget = rawTarget.substring(0, fi);
  }
  final qi = rawTarget.indexOf('?');
  if (qi != -1) {
    query = rawTarget.substring(qi + 1);
    rawTarget = rawTarget.substring(0, qi);
  }

  // Split raw path into segments preserving encoding.
  final rawSegments = rawTarget.split('/').where((s) => s.isNotEmpty).toList();

  // Normalize dot segments on raw string tokens.
  final normalizedTarget = _normalizeRawSegments(rawSegments,
      preserveTrailingSlash: rawTarget.endsWith('/'));

  if (!trimmed.startsWith('/')) {
    // Relative path: append raw target to base, then normalize dot segments.
    final basePath = baseUri.path;
    final baseDir = basePath.endsWith('/') ? basePath : '$basePath/';
    final combinedSegments =
        '$baseDir$rawTarget'.split('/').where((s) => s.isNotEmpty).toList();
    final normalized = _normalizeRawSegments(combinedSegments,
        preserveTrailingSlash: rawTarget.endsWith('/'));
    return _replaceRawPath(
      baseUri,
      normalized,
      query: query,
      fragment: fragment,
    );
  }

  // Absolute path: use SabreDAV's prefix-matching semantics.
  final basePath = baseUri.path;
  final baseSegments = basePath.split('/').where((s) => s.isNotEmpty).toList();

  if (rawSegments.isEmpty) {
    // Target is just "/" - resolve to base with trailing slash.
    return _replaceRawPath(
      baseUri,
      basePath.endsWith('/') ? basePath : '$basePath/',
      query: query,
      fragment: fragment,
    );
  }

  // Check if target segments start with base segments (collection-qualified).
  final matchesPrefix = _rawSegmentsHavePrefix(rawSegments, baseSegments);

  if (matchesPrefix) {
    // Target already includes the base path prefix — use it directly.
    return _replaceRawPath(
      baseUri,
      normalizedTarget,
      query: query,
      fragment: fragment,
    );
  }

  // Check if first segments differ — append to base (SabreDAV behavior).
  if (baseSegments.isNotEmpty && (rawSegments.first != baseSegments.first)) {
    // Prepend base segments and append target segments.
    final combined = <String>[...baseSegments, ...rawSegments];
    final path = '/${combined.join('/')}${rawTarget.endsWith('/') ? '/' : ''}';
    return _replaceRawPath(
      baseUri,
      path,
      query: query,
      fragment: fragment,
    );
  }

  // Default: use target path as-is with base URI authority.
  return _replaceRawPath(
    baseUri,
    normalizedTarget,
    query: query,
    fragment: fragment,
  );
}

/// Check if [segments] starts with [prefix] using raw (percent-encoded) comparison.
bool _rawSegmentsHavePrefix(List<String> segments, List<String> prefix) {
  if (prefix.isEmpty) return true;
  if (segments.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (segments[i] != prefix[i]) return false;
  }
  return true;
}

/// Normalize dot segments (`.` and `..`) from raw segment tokens, preserving
/// percent-encoding of each token.
String _normalizeRawSegments(List<String> segments,
    {bool preserveTrailingSlash = false}) {
  final normalized = <String>[];
  for (final segment in segments) {
    if (segment == '.') continue;
    if (segment == '..') {
      if (normalized.isNotEmpty) normalized.removeLast();
      continue;
    }
    normalized.add(segment);
  }
  if (normalized.isEmpty) return '/';
  var result = '/${normalized.join('/')}';
  if (preserveTrailingSlash) result = '$result/';
  return result;
}

String _replaceRawPath(
  Uri baseUri,
  String rawPath, {
  String? query,
  String? fragment,
}) {
  final buffer = StringBuffer();
  if (baseUri.scheme.isNotEmpty) {
    buffer
      ..write(baseUri.scheme)
      ..write(':');
  }
  if (baseUri.hasAuthority) {
    buffer
      ..write('//')
      ..write(baseUri.authority);
  }
  if (!rawPath.startsWith('/')) {
    buffer.write('/');
  }
  buffer.write(_percentEncode(rawPath, _pathAllowed));
  if (query != null) {
    buffer
      ..write('?')
      ..write(_percentEncode(query, _queryAllowed));
  }
  if (fragment != null) {
    buffer
      ..write('#')
      ..write(_percentEncode(fragment, _queryAllowed));
  }
  return buffer.toString();
}

/// Characters allowed unescaped in a URI path: `pchar` plus `/` (RFC 3986 §3.3).
const _pathAllowed = r"-._~!$&'()*+,;=:@/";

/// Characters allowed unescaped in a query or fragment: `pchar` plus `/` and
/// `?` (RFC 3986 §§3.4-3.5).
const _queryAllowed = r"-._~!$&'()*+,;=:@/?";

/// Percent-encode [raw] so the result is a valid URI component, leaving
/// existing `%XX` escapes untouched so callers can pass pre-encoded input
/// (such as `%2F` standing for a literal slash inside a segment).
String _percentEncode(String raw, String allowed) {
  final buffer = StringBuffer();
  // Characters needing escapes are buffered so surrogate pairs reach
  // `Uri.encodeComponent` intact and encode to a single UTF-8 sequence.
  var pending = 0;

  void flushPending(int end) {
    if (pending == 0) return;
    buffer.write(Uri.encodeComponent(raw.substring(end - pending, end)));
    pending = 0;
  }

  for (var i = 0; i < raw.length; i++) {
    final char = raw[i];
    if (char == '%' && _isEscapeAt(raw, i)) {
      flushPending(i);
      buffer.write(raw.substring(i, i + 3));
      i += 2;
      continue;
    }
    final code = raw.codeUnitAt(i);
    final isUnreserved = (code >= 0x30 && code <= 0x39) || // 0-9
        (code >= 0x41 && code <= 0x5A) || // A-Z
        (code >= 0x61 && code <= 0x7A); // a-z
    if (isUnreserved || allowed.contains(char)) {
      flushPending(i);
      buffer.write(char);
      continue;
    }
    pending++;
  }
  flushPending(raw.length);
  return buffer.toString();
}

/// Whether [raw] holds a complete `%XX` escape starting at [index].
bool _isEscapeAt(String raw, int index) {
  if (index + 2 >= raw.length) return false;
  return _isHexDigit(raw.codeUnitAt(index + 1)) &&
      _isHexDigit(raw.codeUnitAt(index + 2));
}

bool _isHexDigit(int code) =>
    (code >= 0x30 && code <= 0x39) || // 0-9
    (code >= 0x41 && code <= 0x46) || // A-F
    (code >= 0x61 && code <= 0x66); // a-f
