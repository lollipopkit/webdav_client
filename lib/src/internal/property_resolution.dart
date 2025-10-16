const _defaultDavNamespace = 'DAV:';
final RegExp _clarkNotationPattern = RegExp(r'^\{([^}]+)\}(.+)$');

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
PropertyResolutionResult resolvePropertyNames(
  Iterable<String> propertyNames, {
  Map<String, String> namespaceMap = const <String, String>{},
}) {
  final mergedNamespaces = <String, String>{};

  mergedNamespaces['d'] = _defaultDavNamespace;
  mergedNamespaces['D'] = _defaultDavNamespace;

  for (final entry in namespaceMap.entries) {
    if (entry.key.isEmpty || entry.value.isEmpty) continue;
    mergedNamespaces[entry.key] = entry.value;
  }

  final autoAssignments = <String, String>{};
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
      if (localName.isEmpty) {
        throw ArgumentError('Property name "$property" is not valid');
      }
      final namespaceUri = mergedNamespaces[prefix];
      if (namespaceUri == null) {
        throw ArgumentError(
          'Namespace prefix "$prefix" is not defined. Provide it via the '
          '`namespaces` map or use Clark notation.',
        );
      }

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
