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

  final targetUri = Uri.parse(trimmed);
  final baseSegments = _withoutTrailingEmpty(baseUri.pathSegments);
  final targetSegments = _withoutTrailingEmpty(targetUri.pathSegments);

  final combinedSegments = <String>[];
  if (trimmed.startsWith('/')) {
    final matchesPrefix = _segmentsHavePrefix(targetSegments, baseSegments);
    if (targetSegments.isEmpty) {
      combinedSegments.addAll(baseSegments);
    } else if (matchesPrefix) {
      combinedSegments.addAll(targetSegments);
    } else if (baseSegments.isNotEmpty &&
        targetSegments.first != baseSegments.first) {
      combinedSegments
        ..addAll(baseSegments)
        ..addAll(targetSegments);
    } else {
      combinedSegments.addAll(targetSegments);
    }
  } else {
    combinedSegments
      ..addAll(baseSegments)
      ..addAll(targetSegments);
  }

  final normalizedSegments = _removeDotSegments(combinedSegments);

  final pathBuffer = StringBuffer();
  if (normalizedSegments.isEmpty) {
    pathBuffer.write('/');
  } else {
    pathBuffer.write('/');
    pathBuffer.writeAll(normalizedSegments, '/');
    if (trimmed.endsWith('/')) {
      pathBuffer.write('/');
    }
  }

  final resolved = baseUri.replace(
    path: pathBuffer.toString(),
    query: targetUri.hasQuery ? targetUri.query : null,
    fragment: targetUri.hasFragment ? targetUri.fragment : null,
  );

  return resolved.toString();
}

bool _segmentsHavePrefix(List<String> segments, List<String> prefix) {
  if (prefix.isEmpty) {
    return true;
  }
  if (segments.length < prefix.length) {
    return false;
  }
  for (var i = 0; i < prefix.length; i++) {
    if (segments[i] != prefix[i]) {
      return false;
    }
  }
  return true;
}

List<String> _withoutTrailingEmpty(List<String> segments) {
  var end = segments.length;
  while (end > 0 && segments[end - 1].isEmpty) {
    end--;
  }
  if (end == segments.length) {
    return List<String>.from(segments);
  }
  return segments.sublist(0, end);
}

List<String> _removeDotSegments(List<String> segments) {
  final normalized = <String>[];
  for (final segment in segments) {
    if (segment.isEmpty || segment == '.') {
      continue;
    }
    if (segment == '..') {
      if (normalized.isNotEmpty) {
        normalized.removeLast();
      }
      continue;
    }
    normalized.add(segment);
  }
  return normalized;
}
