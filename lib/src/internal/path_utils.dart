import 'dart:convert';

import 'package:webdav_client_plus/src/options.dart';

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

final _absoluteHttpUrl = RegExp('^https?://', caseSensitive: false);

/// Resolve [target] against [baseUrl] following [mode].
String resolveTarget(String baseUrl, String target, PathMode mode) =>
    switch (mode) {
      PathMode.baseRelative => _resolveBaseRelative(baseUrl, target),
      PathMode.legacy => resolveAgainstBaseUrl(baseUrl, target),
    };

/// Resolve [target] as described by [PathMode.baseRelative].
String _resolveBaseRelative(String baseUrl, String target) {
  if (target.startsWith(_absoluteHttpUrl)) {
    return Uri.parse(target).toString();
  }

  final rawSegments = target.split('/');
  final segments = <String>[];
  for (final segment in rawSegments) {
    switch (segment) {
      case '' || '.':
        continue;
      case '..':
        if (segments.isEmpty) {
          throw ArgumentError.value(target, 'path', 'escapes the base URL');
        }
        segments.removeLast();
      default:
        segments.add(segment);
    }
  }

  final baseUri = Uri.parse(baseUrl);
  final buffer = StringBuffer(_collectionPath(baseUri.path))
    ..writeAll(segments.map(Uri.encodeComponent), '/');
  if (segments.isNotEmpty && const {'', '.', '..'}.contains(rawSegments.last)) {
    buffer.write('/');
  }
  return _replaceRawPath(baseUri, buffer.toString());
}

/// Convert a response [href] to the target form of [PathMode.baseRelative]:
/// the decoded path relative to [baseUrl] when the
/// href lies inside it, otherwise the absolute URL. Relative hrefs resolve
/// against [requestUrl], the URL the response answers.
String hrefToTarget(String baseUrl, String href, {String? requestUrl}) {
  final baseUri = Uri.parse(baseUrl);
  // A fragment never reaches the server, so it does not change the resource;
  // a query does.
  final uri =
      Uri.parse(requestUrl ?? baseUrl).resolve(href.trim()).removeFragment();
  if (!sameOrigin(uri, baseUri) || uri.hasQuery) {
    return uri.toString();
  }

  // Servers may encode the base path differently, so compare decoded
  // segments.
  final baseSegments = baseUri.pathSegments.where((s) => s.isNotEmpty);
  final path = uri.path.isEmpty ? '/' : uri.path;
  final segments = path.substring(1).split('/');
  var index = 0;
  for (final baseSegment in baseSegments) {
    if (index >= segments.length ||
        _decodeSegment(segments[index]) != baseSegment) {
      return uri.toString();
    }
    index++;
  }

  final decoded = <String>[];
  for (var i = index; i < segments.length; i++) {
    final segment = _decodeSegment(segments[i]);
    // Names the decoded form cannot express, such as an encoded `/`, keep
    // the URL so the exact resource stays addressable.
    final isLast = i == segments.length - 1;
    if (segment == null ||
        segment.contains('/') ||
        segment == '.' ||
        segment == '..' ||
        (segment.isEmpty && !isLast)) {
      return uri.toString();
    }
    decoded.add(segment);
  }
  return '/${decoded.join('/')}';
}

/// Strictly percent-decode a path [segment], or `null` when it is not valid
/// UTF-8 percent-encoding.
String? _decodeSegment(String segment) {
  try {
    return Uri.decodeComponent(segment);
  } on FormatException {
    return null;
  }
}

/// Whether [a] and [b] share scheme, host and port (RFC 6454 §5), treating a
/// missing scheme as http and a missing port as the scheme's default.
bool sameOrigin(Uri a, Uri b) {
  String scheme(Uri uri) =>
      uri.scheme.isEmpty ? 'http' : uri.scheme.toLowerCase();
  int port(Uri uri) => uri.hasPort
      ? uri.port
      : switch (scheme(uri)) { 'https' => 443, 'http' => 80, _ => 0 };
  return scheme(a) == scheme(b) &&
      a.host.toLowerCase() == b.host.toLowerCase() &&
      port(a) == port(b);
}

String _collectionPath(String path) => path.endsWith('/') ? path : '$path/';

/// Resolve [target] against [baseUrl] as described by [PathMode.legacy].
// TODO: remove with the legacy path mode.
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

  // Schemes are case-insensitive (RFC 3986 §3.1).
  if (trimmed.startsWith(_absoluteHttpUrl)) {
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

/// Percent-decode an href. Characters outside `%XX` escapes, such as raw
/// non-ASCII text some servers send, are kept as they are. The href is
/// returned unchanged when it is not valid percent-encoding (such as a bare
/// `%`) or the escapes are not UTF-8.
String decodeHref(String href) {
  if (!href.contains('%')) return href;
  final bytes = <int>[];
  for (var i = 0; i < href.length; i++) {
    if (href[i] != '%') {
      final rune = href.codeUnitAt(i);
      // Keep surrogate pairs together so they encode as one code point.
      final end = rune >= 0xD800 && rune <= 0xDBFF && i + 1 < href.length
          ? i + 2
          : i + 1;
      bytes.addAll(utf8.encode(href.substring(i, end)));
      i = end - 1;
    } else if (_isEscapeAt(href, i)) {
      bytes.add(int.parse(href.substring(i + 1, i + 3), radix: 16));
      i += 2;
    } else {
      return href;
    }
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return href;
  }
}

/// Comparison key of [href] as described by [PathMode.legacy].
// TODO: remove with the legacy path mode.
String legacyHrefKey(
  String href, {
  required bool treatAsCollection,
}) {
  var value = href.trim();
  if (value.isEmpty) {
    return treatAsCollection ? '/' : '/';
  }

  Uri? parsed;
  try {
    parsed = Uri.parse(value);
  } catch (_) {
    parsed = null;
  }

  if (parsed != null) {
    if (parsed.hasScheme || value.startsWith('/')) {
      value = parsed.path;
    } else if (parsed.path.isNotEmpty) {
      value = parsed.path;
    }
  }

  final queryIndex = value.indexOf('?');
  if (queryIndex != -1) {
    value = value.substring(0, queryIndex);
  }

  final fragmentIndex = value.indexOf('#');
  if (fragmentIndex != -1) {
    value = value.substring(0, fragmentIndex);
  }

  if (!value.startsWith('/')) {
    value = '/$value';
  }

  value = value.replaceAll(RegExp('/+'), '/');
  if (value.isEmpty) {
    value = '/';
  }

  if (treatAsCollection) {
    if (!value.endsWith('/')) {
      value = '$value/';
    }
  } else if (value.length > 1 && value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }

  // Servers may percent-encode differently than the client did.
  return decodeHref(value);
}
