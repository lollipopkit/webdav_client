import 'dart:convert';
import 'dart:math';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:xml/xml.dart';

const _defaultDavNamespace = 'DAV:';
final _clarkNotationPattern = RegExp(r'^\{([^}]+)\}(.+)$');

/// XML

List<XmlElement> findAllElements(XmlDocument document, String tag) =>
    document.findAllElements(tag, namespace: '*').toList();

List<XmlElement> findElements(XmlElement element, String tag) =>
    element.findElements(tag, namespace: '*').toList();

/// Extract a string value from the first matching element
String? getElementText(XmlElement parent, String tag) =>
    findElements(parent, tag).firstOrNull?.innerText;

/// Extract an integer value from the first matching element
int? getIntValue(XmlElement parent, String tag) {
  final value = getElementText(parent, tag);
  return value != null ? int.tryParse(value) : null;
}

/// Check if element contains a specific child element
bool hasElement(XmlElement parent, String childTag) =>
    findElements(parent, childTag).isNotEmpty;

/// PATH

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

/// Resolve [target] against [baseUrl] producing an absolute HTTP(S) URL.
///
/// - If [target] is already an absolute URL, it is returned as-is after
///   normalization.
/// - If [target] starts with '/', it must preserve the Request-URI prefix as
///   mandated by RFC 4918 §8.3, only avoiding duplication when the prefix is
///   already present.
/// - Otherwise, [target] is treated as relative to [baseUrl] while preserving
///   the base collection prefix.
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
      // Fall back to the authority-style URI without modifying the scheme.
      return Uri.parse(trimmed).toString();
    }
    return Uri.parse('$scheme:$trimmed').toString();
  }

  final targetUri = Uri.parse(trimmed);
  final baseSegments = _withoutTrailingEmpty(baseUri.pathSegments);
  final targetSegments = _withoutTrailingEmpty(targetUri.pathSegments);

  final combinedSegments = <String>[];
  if (trimmed.startsWith('/')) {
    if (_segmentsHavePrefix(targetSegments, baseSegments) &&
        targetSegments.isNotEmpty) {
      combinedSegments.addAll(targetSegments);
    } else {
      combinedSegments
        ..addAll(baseSegments)
        ..addAll(targetSegments);
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

/// HASH

String md5Hash(String data) {
  final digest = crypto.md5.convert(utf8.encode(data));
  return hex.encode(digest.bytes);
}

String sha256Hash(String data) {
  final bytes = utf8.encode(data);
  final digest = crypto.sha256.convert(bytes);
  return digest.toString();
}

String sha512Hash(String data) {
  final bytes = utf8.encode(data);
  final digest = crypto.sha512.convert(bytes);
  return digest.toString();
}

String computeNonce() {
  final rnd = Random.secure();
  final values = List<int>.generate(16, (i) => rnd.nextInt(256));
  return hex.encode(values).substring(0, 16);
}

/// PROPERTY NAME RESOLUTION

/// Result of resolving a property name into its XML qualified representation.
class ResolvedPropertyName {
  /// XML qualified element name such as `d:getetag` or `oc:permissions`.
  final String qualifiedName;

  /// Namespace prefix associated with the property.
  final String prefix;

  /// Namespace URI associated with the property.
  final String namespaceUri;

  /// Local element name without prefix.
  final String localName;

  const ResolvedPropertyName({
    required this.qualifiedName,
    required this.prefix,
    required this.namespaceUri,
    required this.localName,
  });
}

/// Resolution outcome including qualified property names and namespace map.
class PropertyResolutionResult {
  /// Ordered list of resolved properties that aligns with the input order.
  final List<ResolvedPropertyName> properties;

  /// Namespace declarations keyed by prefix.
  final Map<String, String> namespaces;

  const PropertyResolutionResult({
    required this.properties,
    required this.namespaces,
  });
}

/// Resolve property identifiers supplied either in prefix or Clark notation.
///
/// The optional [namespaceMap] allows callers to provide explicit mappings for
/// prefixes. If a prefix is not found, a best-effort placeholder namespace is
/// synthesized to maintain backward compatibility with existing behaviour.
PropertyResolutionResult resolvePropertyNames(
  Iterable<String> propertyNames, {
  Map<String, String> namespaceMap = const <String, String>{},
}) {
  final mergedNamespaces = <String, String>{};

  // Ensure the default DAV namespace is always available.
  mergedNamespaces['d'] = _defaultDavNamespace;
  mergedNamespaces['D'] = _defaultDavNamespace;

  for (final entry in namespaceMap.entries) {
    if (entry.key.isEmpty || entry.value.isEmpty) continue;
    mergedNamespaces[entry.key] = entry.value;
  }

  final autoAssignments = <String, String>{}; // namespaceUri -> prefix
  final resolved = <ResolvedPropertyName>[];
  final requiredNamespaces = <String, String>{};
  var autoIndex = 0;

  String obtainAutoPrefix(String namespaceUri) {
    final existing = autoAssignments[namespaceUri];
    if (existing != null) {
      return existing;
    }

    while (true) {
      final candidate = 'ns$autoIndex';
      autoIndex++;
      if (!mergedNamespaces.containsKey(candidate) &&
          !autoAssignments.containsValue(candidate)) {
        autoAssignments[namespaceUri] = candidate;
        mergedNamespaces[candidate] = namespaceUri;
        return candidate;
      }
    }
  }

  for (final rawProperty in propertyNames) {
    final property = rawProperty.trim();
    if (property.isEmpty) {
      throw ArgumentError('Property names must not be empty');
    }

    ResolvedPropertyName resolvedName;

    final clarkMatch = _clarkNotationPattern.firstMatch(property);
    if (clarkMatch != null) {
      final namespaceUri = clarkMatch.group(1)!.trim();
      final localName = clarkMatch.group(2)!.trim();

      // Try to reuse a provided prefix for this namespace.
      String? prefix;
      for (final entry in mergedNamespaces.entries) {
        if (entry.value == namespaceUri) {
          prefix = entry.key;
          break;
        }
      }
      prefix ??= obtainAutoPrefix(namespaceUri);

      resolvedName = ResolvedPropertyName(
        qualifiedName: '$prefix:$localName',
        prefix: prefix,
        namespaceUri: namespaceUri,
        localName: localName,
      );
    } else if (property.contains(':')) {
      final separatorIndex = property.indexOf(':');
      final prefix = property.substring(0, separatorIndex);
      final localName = property.substring(separatorIndex + 1);
      final namespaceUri = mergedNamespaces.putIfAbsent(
        prefix,
        () => 'http://example.com/ns/$prefix',
      );

      resolvedName = ResolvedPropertyName(
        qualifiedName: '$prefix:$localName',
        prefix: prefix,
        namespaceUri: namespaceUri,
        localName: localName,
      );
    } else {
      const prefix = 'd';
      final namespaceUri = mergedNamespaces[prefix] ?? _defaultDavNamespace;

      resolvedName = ResolvedPropertyName(
        qualifiedName: '$prefix:$property',
        prefix: prefix,
        namespaceUri: namespaceUri,
        localName: property,
      );
    }

    resolved.add(resolvedName);
    requiredNamespaces[resolvedName.prefix] = resolvedName.namespaceUri;
  }

  return PropertyResolutionResult(
    properties: resolved,
    namespaces: requiredNamespaces,
  );
}

/// EXT

extension IterX<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final element in this) {
      if (test(element)) {
        return element;
      }
    }
    return null;
  }
}
