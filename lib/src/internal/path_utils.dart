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

  if (_hasUriScheme(trimmed)) {
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

  if (rawTarget.isEmpty) {
    // Query-only (`?x=1`) and fragment-only (`#frag`) references must not
    // change the base path (RFC 3986 §5.3).
    return _replaceRawPath(
      baseUri,
      baseUri.path.isEmpty ? '/' : baseUri.path,
      query: query,
      fragment: fragment,
    );
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
    // Prepend base segments and append target segments, then normalize dot
    // segments across the combined path.
    final combinedSegments = <String>[...baseSegments, ...rawSegments];
    final normalizedCombined = _normalizeRawSegments(
      combinedSegments,
      preserveTrailingSlash: rawTarget.endsWith('/'),
    );
    return _replaceRawPath(
      baseUri,
      normalizedCombined,
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

/// Return `true` when [target] carries an explicit URI scheme
/// (for example `http://`, `ftp://` or `webdavs://`), meaning the target is
/// already absolute and must not be resolved against the base URL.
bool _hasUriScheme(String target) {
  final colonIndex = target.indexOf(':');
  if (colonIndex <= 0) return false;
  final scheme = target.substring(0, colonIndex);
  if (scheme.isEmpty || target.startsWith('/')) return false;
  for (var i = 0; i < scheme.length; i++) {
    final code = scheme.codeUnitAt(i);
    final isAlpha = (code >= 0x41 && code <= 0x5A) ||
        (code >= 0x61 && code <= 0x7A);
    final isDigit = code >= 0x30 && code <= 0x39;
    final isPlus = code == 0x2B;
    final isDot = code == 0x2E;
    final isDash = code == 0x2D;
    if (!(isAlpha || (i > 0 && (isDigit || isPlus || isDot || isDash)))) {
      return false;
    }
  }
  return true;
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
  buffer.write(rawPath);
  if (query != null) {
    buffer
      ..write('?')
      ..write(query);
  }
  if (fragment != null) {
    buffer
      ..write('#')
      ..write(fragment);
  }
  return buffer.toString();
}
