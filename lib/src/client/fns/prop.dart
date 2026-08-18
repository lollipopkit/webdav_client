part of '../client.dart';

/// One ordered RFC 4918 PROPPATCH instruction.
///
/// Servers must process PROPPATCH instructions in document order (§9.2). Use
/// this type with [WebdavClientPropfind.propPatch] when ordering matters.
class PropPatchOperation {
  /// Property name in DAV local-name, prefixed (`oc:permissions`) or Clark
  /// (`{DAV:}displayname`) notation.
  final String property;

  /// Text value for set operations. Ignored for remove operations.
  final String? value;

  /// Raw XML children for set operations that need structured property values.
  final String? xmlValue;

  /// Whether this operation removes the property instead of setting it.
  final bool remove;

  const PropPatchOperation._({
    required this.property,
    required this.remove,
    this.value,
    this.xmlValue,
  });

  /// Create a `set` instruction with text content.
  const factory PropPatchOperation.set(String property, String value) =
      _SetPropPatchOperation;

  /// Create a `set` instruction with raw XML child content.
  const factory PropPatchOperation.setXml(String property, String xmlValue) =
      _SetXmlPropPatchOperation;

  /// Create a `remove` instruction.
  const factory PropPatchOperation.remove(String property) =
      _RemovePropPatchOperation;
}

class _SetPropPatchOperation extends PropPatchOperation {
  const _SetPropPatchOperation(String property, String value)
      : super._(property: property, value: value, remove: false);
}

class _SetXmlPropPatchOperation extends PropPatchOperation {
  const _SetXmlPropPatchOperation(String property, String xmlValue)
      : super._(property: property, xmlValue: xmlValue, remove: false);
}

class _RemovePropPatchOperation extends PropPatchOperation {
  const _RemovePropPatchOperation(String property)
      : super._(property: property, remove: true);
}

extension WebdavClientPropfind on WebdavClient {
  /// Check if a resource exists
  ///
  /// - [path] of the resource
  /// - [cancelToken] for cancelling the request
  Future<bool> exists(String path, {CancelToken? cancelToken}) async {
    try {
      await readProps(path, cancelToken: cancelToken);
      return true;
    } on WebdavException<Object> catch (e) {
      if (e.response?.statusCode == 404) {
        return false;
      }
      rethrow;
    }
  }

  /// Set properties of a resource
  /// - [path] of the resource
  /// - [properties] is a map of key-value pairs
  /// - [cancelToken] for cancelling the request
  Future<void> setProps(
    String path,
    Map<String, String> properties, {
    Map<String, String> namespaces = const <String, String>{},
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final xmlBuilder = XmlBuilder();
    xmlBuilder.processing('xml', 'version="1.0" encoding="utf-8"');
    xmlBuilder.element('d:propertyupdate', nest: () {
      xmlBuilder.namespaceUri('d', 'DAV:');

      final resolution = resolvePropertyNames(
        properties.keys,
        namespaceMap: namespaces,
      );

      resolution.namespaces.forEach((prefix, uri) {
        if (prefix == 'd') return;
        xmlBuilder.namespaceUri(prefix, uri);
      });

      xmlBuilder.element('d:set', nest: () {
        xmlBuilder.element('d:prop', nest: () {
          final entries = properties.entries.toList();
          for (var i = 0; i < resolution.properties.length; i++) {
            final prop = resolution.properties[i];
            final value = entries[i].value;
            xmlBuilder.element(prop.qualifiedName, nest: value);
          }
        });
      });
    });

    final xmlString = xmlBuilder.buildDocument().toString();
    final resp = await _client.wdProppatch(
      path,
      xmlString,
      cancelToken: cancelToken,
      headers: headers,
    );
    _ensurePropPatchSuccess(resp);
  }

  /// Put a resource according to the conditions
  ///
  /// - [path] of the resource
  /// - [data] to write
  /// - [lockToken] If the resource is locked, the lock token must match
  /// - [etag] If the resource has an etag, it must match the etag in the request
  /// - [notTag] When true, negates the supplied [etag] per RFC 4918 §10.4.5
  Future<void> conditionalPut(
    String path,
    Uint8List data, {
    String? lockToken,
    String? etag,
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
    Map<String, dynamic>? headers,
    bool notTag = false,
  }) async {
    // RFC 4918 10.4.2
    final requestHeaders = headers != null
        ? Map<String, dynamic>.from(headers)
        : <String, dynamic>{};

    // Construct the If header
    if (lockToken != null || etag != null) {
      final ifHeader = _buildIfHeader(url, path, lockToken, etag, notTag);
      if (ifHeader.isNotEmpty) {
        requestHeaders['If'] = ifHeader;
      }
    }

    await _client.wdWriteWithBytes(
      path,
      data,
      additionalHeaders: requestHeaders,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  /// Create a resource only if it does not already exist.
  ///
  /// Sends `If-None-Match: *` as defined by HTTP conditional requests and used
  /// by WebDAV clients for collision-safe creates.
  Future<void> create(
    String path,
    Uint8List data, {
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
    Map<String, dynamic>? headers,
  }) {
    final requestHeaders = headers != null
        ? Map<String, dynamic>.from(headers)
        : <String, dynamic>{};
    requestHeaders['If-None-Match'] = '*';

    return _client.wdWriteWithBytes(
      path,
      data,
      additionalHeaders: requestHeaders,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  /// Replace a resource only if the current entity tag matches [etag].
  Future<void> updateIfMatch(
    String path,
    Uint8List data,
    String etag, {
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
    Map<String, dynamic>? headers,
  }) {
    final requestHeaders = headers != null
        ? Map<String, dynamic>.from(headers)
        : <String, dynamic>{};
    requestHeaders['If-Match'] = _formatEntityTag(etag);

    return _client.wdWriteWithBytes(
      path,
      data,
      additionalHeaders: requestHeaders,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  /// Modify properties of a resource
  ///
  /// - [path] of the resource
  /// - [setProps] is a map of key-value pairs to set
  /// - [removeProps] is a list of keys to remove
  /// - [cancelToken] for cancelling the request
  Future<void> modifyProps(
    String path, {
    Map<String, String>? setProps,
    List<String>? removeProps,
    Map<String, String> namespaces = const <String, String>{},
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final xmlBuilder = XmlBuilder();
    xmlBuilder.processing('xml', 'version="1.0" encoding="utf-8"');
    xmlBuilder.element('d:propertyupdate', nest: () {
      xmlBuilder.namespaceUri('d', 'DAV:');

      final setResolution = (setProps != null && setProps.isNotEmpty)
          ? resolvePropertyNames(
              setProps.keys,
              namespaceMap: namespaces,
            )
          : null;
      final removeResolution = (removeProps != null && removeProps.isNotEmpty)
          ? resolvePropertyNames(
              removeProps,
              namespaceMap: namespaces,
            )
          : null;

      final namespaceDeclarations = <String, String>{};
      if (setResolution != null) {
        namespaceDeclarations.addAll(setResolution.namespaces);
      }
      if (removeResolution != null) {
        namespaceDeclarations.addAll(removeResolution.namespaces);
      }

      namespaceDeclarations.forEach((prefix, uri) {
        if (prefix == 'd') return;
        xmlBuilder.namespaceUri(prefix, uri);
      });

      if (setResolution != null) {
        final entries = setProps!.entries.toList();
        xmlBuilder.element('d:set', nest: () {
          xmlBuilder.element('d:prop', nest: () {
            for (var i = 0; i < setResolution.properties.length; i++) {
              final prop = setResolution.properties[i];
              final value = entries[i].value;
              xmlBuilder.element(prop.qualifiedName, nest: value);
            }
          });
        });
      }

      if (removeResolution != null) {
        xmlBuilder.element('d:remove', nest: () {
          xmlBuilder.element('d:prop', nest: () {
            for (final prop in removeResolution.properties) {
              xmlBuilder.element(prop.qualifiedName);
            }
          });
        });
      }
    });

    final xmlString = xmlBuilder.buildDocument().toString();
    final resp = await _client.wdProppatch(
      path,
      xmlString,
      cancelToken: cancelToken,
      headers: headers,
    );
    _ensurePropPatchSuccess(resp);
  }

  /// Apply ordered property mutations with PROPPATCH.
  ///
  /// Unlike [modifyProps], this preserves caller-specified set/remove ordering
  /// as required by RFC 4918 §9.2.
  Future<void> propPatch(
    String path,
    List<PropPatchOperation> operations, {
    Map<String, String> namespaces = const <String, String>{},
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    if (operations.isEmpty) {
      return;
    }

    final resolution = resolvePropertyNames(
      operations.map((operation) => operation.property),
      namespaceMap: namespaces,
    );

    final xmlBuilder = XmlBuilder();
    xmlBuilder.processing('xml', 'version="1.0" encoding="utf-8"');
    xmlBuilder.element('d:propertyupdate', nest: () {
      xmlBuilder.namespaceUri('d', 'DAV:');
      resolution.namespaces.forEach((prefix, uri) {
        if (prefix == 'd') return;
        xmlBuilder.namespaceUri(prefix, uri);
      });

      for (var i = 0; i < operations.length; i++) {
        final operation = operations[i];
        final prop = resolution.properties[i];
        xmlBuilder.element(operation.remove ? 'd:remove' : 'd:set', nest: () {
          xmlBuilder.element('d:prop', nest: () {
            if (operation.remove) {
              xmlBuilder.element(prop.qualifiedName);
            } else if (operation.xmlValue != null) {
              xmlBuilder.element(prop.qualifiedName, nest: () {
                xmlBuilder.xml(operation.xmlValue!);
              });
            } else {
              xmlBuilder.element(
                prop.qualifiedName,
                nest: operation.value ?? '',
              );
            }
          });
        });
      }
    });

    final resp = await _client.wdProppatch(
      path,
      xmlBuilder.buildDocument().toString(),
      cancelToken: cancelToken,
      headers: headers,
    );
    _ensurePropPatchSuccess(resp);
  }

  /// Discover the authenticated user's principal URL (RFC 5397 / RFC 3744).
  Future<String?> currentUserPrincipal({
    String path = '/',
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final props = await propFind(
      path,
      properties: const ['current-user-principal'],
      headers: headers,
      cancelToken: cancelToken,
    );
    final principal = props['{DAV:}current-user-principal'];
    return _firstHrefText(principal);
  }

  /// Discover principal collection set hrefs (RFC 3744 §5.8).
  Future<List<String>> principalCollectionSet({
    String path = '/',
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final props = await propFind(
      path,
      properties: const ['principal-collection-set'],
      headers: headers,
      cancelToken: cancelToken,
    );
    return _hrefList(props['{DAV:}principal-collection-set']);
  }

  /// Discover the owner principal URL for a resource (RFC 3744 §5.1).
  Future<String?> ownerPrincipal({
    String path = '/',
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final props = await propFind(
      path,
      properties: const ['owner'],
      headers: headers,
      cancelToken: cancelToken,
    );
    return _firstHrefText(props['{DAV:}owner']);
  }

  /// Discover group membership hrefs for a principal (RFC 3744 §5.4).
  Future<List<String>> groupMembership({
    String path = '/',
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final props = await propFind(
      path,
      properties: const ['group-membership'],
      headers: headers,
      cancelToken: cancelToken,
    );
    final element = props['{DAV:}group-membership'];
    return _hrefList(element);
  }

  /// Discover ACL restrictions for [path] (RFC 3744 §5.5.1).
  Future<XmlElement?> aclRestrictions({
    String path = '/',
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final props = await propFind(
      path,
      properties: const ['acl-restrictions'],
      headers: headers,
      cancelToken: cancelToken,
    );
    return props['{DAV:}acl-restrictions'];
  }

  /// Discover group member set hrefs for a principal (RFC 3744 §4.4).
  Future<List<String>> groupMemberSet({
    String path = '/',
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final props = await propFind(
      path,
      properties: const ['group-member-set'],
      headers: headers,
      cancelToken: cancelToken,
    );
    return _hrefList(props['{DAV:}group-member-set']);
  }

  /// Discover current-user-privilege-set values for [path] (RFC 3744 §5.5).
  Future<List<String>> currentUserPrivilegeSet({
    String path = '/',
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final props = await propFind(
      path,
      properties: const ['current-user-privilege-set'],
      headers: headers,
      cancelToken: cancelToken,
    );
    final element = props['{DAV:}current-user-privilege-set'];
    if (element == null) {
      return const <String>[];
    }

    return element
        .findAllElements('privilege', namespaceUri: '*')
        .expand((privilege) => privilege.childElements)
        .map(_formatPropertyName)
        .toList(growable: false);
  }

  /// Read the DAV:acl property and return its ACE elements (RFC 3744 §5.7).
  Future<List<XmlElement>> accessControlList({
    String path = '/',
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final props = await propFind(
      path,
      properties: const ['acl'],
      headers: headers,
      cancelToken: cancelToken,
    );
    final acl = props['{DAV:}acl'];
    if (acl == null) {
      return const <XmlElement>[];
    }
    return acl.findElements('ace', namespaceUri: '*').toList(growable: false);
  }

  /// Discover inherited ACL set hrefs for [path] (RFC 3744 §5.6).
  Future<List<String>> inheritedAclSet({
    String path = '/',
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final props = await propFind(
      path,
      properties: const ['inherited-acl-set'],
      headers: headers,
      cancelToken: cancelToken,
    );
    return _hrefList(props['{DAV:}inherited-acl-set']);
  }

  /// Discover alternate URI set values for a principal (RFC 3744 §4.2).
  Future<List<String>> alternateUriSet({
    String path = '/',
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final props = await propFind(
      path,
      properties: const ['alternate-URI-set'],
      headers: headers,
      cancelToken: cancelToken,
    );
    return _hrefList(props['{DAV:}alternate-URI-set']);
  }

  /// Discover principal URL values for a principal resource (RFC 3744 §4.3).
  Future<List<String>> principalUrl({
    String path = '/',
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final props = await propFind(
      path,
      properties: const ['principal-URL'],
      headers: headers,
      cancelToken: cancelToken,
    );
    return _hrefList(props['{DAV:}principal-URL']);
  }

  /// Discover the workspace collection set hrefs (RFC 3253 §6.2).
  Future<List<String>> workspaceCollectionSet({
    String path = '/',
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final props = await propFind(
      path,
      properties: const ['workspace-collection-set'],
      headers: headers,
      cancelToken: cancelToken,
    );
    return _hrefList(props['{DAV:}workspace-collection-set']);
  }

  /// Discover the activity collection set hrefs (RFC 3253 §13.5).
  Future<List<String>> activityCollectionSet({
    String path = '/',
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final props = await propFind(
      path,
      properties: const ['activity-collection-set'],
      headers: headers,
      cancelToken: cancelToken,
    );
    return _hrefList(props['{DAV:}activity-collection-set']);
  }

  /// Discover creation user display name (RFC 3253 §3.1.1).
  Future<String?> creatorDisplayName({
    String path = '/',
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final props = await propFind(
      path,
      properties: const ['creator-displayname'],
      headers: headers,
      cancelToken: cancelToken,
    );
    final text = props['{DAV:}creator-displayname']?.innerText.trim();
    return text == null || text.isEmpty ? null : text;
  }

  /// Discover DAV:comment text (RFC 3253 §3.1.2).
  Future<String?> comment({
    String path = '/',
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final props = await propFind(
      path,
      properties: const ['comment'],
      headers: headers,
      cancelToken: cancelToken,
    );
    final text = props['{DAV:}comment']?.innerText.trim();
    return text == null || text.isEmpty ? null : text;
  }

  /// Discover source hrefs for a resource (RFC 4918 §15.7).
  Future<List<String>> source({
    String path = '/',
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final props = await propFind(
      path,
      properties: const ['source'],
      headers: headers,
      cancelToken: cancelToken,
    );
    return _hrefList(props['{DAV:}source']);
  }

  /// Discover the checked-in version href for a version-controlled resource.
  Future<String?> checkedIn({
    String path = '/',
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final props = await propFind(
      path,
      properties: const ['checked-in'],
      headers: headers,
      cancelToken: cancelToken,
    );
    return _firstHrefText(props['{DAV:}checked-in']);
  }

  /// Discover the checked-out version href for a version-controlled resource.
  Future<String?> checkedOut({
    String path = '/',
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final props = await propFind(
      path,
      properties: const ['checked-out'],
      headers: headers,
      cancelToken: cancelToken,
    );
    return _firstHrefText(props['{DAV:}checked-out']);
  }

  /// Discover the version-history href for a version-controlled resource.
  Future<String?> versionHistory({
    String path = '/',
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final props = await propFind(
      path,
      properties: const ['version-history'],
      headers: headers,
      cancelToken: cancelToken,
    );
    return _firstHrefText(props['{DAV:}version-history']);
  }

  /// Discover predecessor version hrefs for a version resource.
  Future<List<String>> predecessorSet({
    String path = '/',
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final props = await propFind(
      path,
      properties: const ['predecessor-set'],
      headers: headers,
      cancelToken: cancelToken,
    );
    return _hrefList(props['{DAV:}predecessor-set']);
  }

  /// Discover successor version hrefs for a version resource.
  Future<List<String>> successorSet({
    String path = '/',
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final props = await propFind(
      path,
      properties: const ['successor-set'],
      headers: headers,
      cancelToken: cancelToken,
    );
    return _hrefList(props['{DAV:}successor-set']);
  }

  /// Discover supported method names for [path] (RFC 3253 §3.1.3).
  Future<List<String>> supportedMethods({
    String path = '/',
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final props = await propFind(
      path,
      properties: const ['supported-method-set'],
      headers: headers,
      cancelToken: cancelToken,
    );
    final supported = props['{DAV:}supported-method-set'];
    if (supported == null) {
      return const <String>[];
    }
    return supported
        .findAllElements('supported-method', namespaceUri: '*')
        .map((element) => element.getAttribute('name')?.trim())
        .whereType<String>()
        .where((name) => name.isNotEmpty)
        .toList(growable: false);
  }

  /// Discover supported live property names for [path] (RFC 3253 §3.1.4).
  Future<List<String>> supportedLiveProperties({
    String path = '/',
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final props = await propFind(
      path,
      properties: const ['supported-live-property-set'],
      headers: headers,
      cancelToken: cancelToken,
    );
    final supported = props['{DAV:}supported-live-property-set'];
    if (supported == null) {
      return const <String>[];
    }
    return supported
        .findAllElements('supported-live-property', namespaceUri: '*')
        .map((element) => element.childElements.firstOrNull)
        .whereType<XmlElement>()
        .map(_formatPropertyName)
        .toList(growable: false);
  }

  /// Perform a PROPFIND and return successful properties for the requested path.
  ///
  /// Mirrors SabreDAV's `Client::propFind` convenience helper by filtering the
  /// RFC 4918 Multi-Status response to the 2xx property set for [path]. Use
  /// [propFindRaw] when callers need per-status diagnostics.
  Future<Map<String, XmlElement>> propFind(
    String path, {
    PropsDepth depth = PropsDepth.zero,
    List<String> properties = PropfindType.defaultFindProperties,
    PropfindType findType = PropfindType.prop,
    Map<String, String> namespaces = const <String, String>{},
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final raw = await propFindRaw(
      path,
      depth: depth,
      properties: properties,
      findType: findType,
      namespaces: namespaces,
      headers: headers,
      cancelToken: cancelToken,
    );

    final normalizedTarget = _normalizeHrefForPropFind(path);
    var statusMap = raw[path];
    statusMap ??= raw[normalizedTarget];
    statusMap ??= raw[_normalizeHrefForPropFind(normalizedTarget)];
    statusMap ??= raw.entries
        .firstWhereOrNull(
          (entry) => _normalizeHrefForPropFind(entry.key) == normalizedTarget,
        )
        ?.value;

    if (statusMap == null && raw.length == 1) {
      statusMap = raw.values.single;
    }
    if (statusMap == null) {
      return const <String, XmlElement>{};
    }

    final result = <String, XmlElement>{};
    statusMap.forEach((status, props) {
      if (status >= 200 && status < 300) {
        result.addAll(props);
      }
    });
    return result;
  }

  /// Perform an `allprop` PROPFIND and return successful properties.
  Future<Map<String, XmlElement>> propFindAll(
    String path, {
    PropsDepth depth = PropsDepth.zero,
    List<String> include = const <String>[],
    Map<String, String> namespaces = const <String, String>{},
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) {
    return propFind(
      path,
      depth: depth,
      properties: include,
      findType: PropfindType.allprop,
      namespaces: namespaces,
      headers: headers,
      cancelToken: cancelToken,
    );
  }

  /// Perform a `propname` PROPFIND and return successful property names.
  Future<List<String>> propFindNames(
    String path, {
    PropsDepth depth = PropsDepth.zero,
    Map<String, String> namespaces = const <String, String>{},
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final props = await propFind(
      path,
      depth: depth,
      properties: const <String>[],
      findType: PropfindType.propname,
      namespaces: namespaces,
      headers: headers,
      cancelToken: cancelToken,
    );
    return props.keys.toList(growable: false);
  }

  /// Perform a depth PROPFIND and return successful properties keyed by href.
  ///
  /// This mirrors SabreDAV's `propFind` depth traversal convenience while
  /// preserving all matching resources instead of filtering to a single href.
  Future<Map<String, Map<String, XmlElement>>> propFindDepth(
    String path, {
    PropsDepth depth = PropsDepth.one,
    List<String> properties = PropfindType.defaultFindProperties,
    PropfindType findType = PropfindType.prop,
    Map<String, String> namespaces = const <String, String>{},
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final raw = await propFindRaw(
      path,
      depth: depth,
      properties: properties,
      findType: findType,
      namespaces: namespaces,
      headers: headers,
      cancelToken: cancelToken,
    );

    final result = <String, Map<String, XmlElement>>{};
    raw.forEach((href, statusMap) {
      final props = <String, XmlElement>{};
      statusMap.forEach((status, statusProps) {
        if (status >= 200 && status < 300) {
          props.addAll(statusProps);
        }
      });
      if (props.isNotEmpty) {
        result[href] = props;
      }
    });
    return result;
  }

  /// Perform a PROPFIND request and return raw Multi-Status propstat data.
  ///
  /// Mirrors SabreDAV's [`Client::propFindUnfiltered`](dav/lib/DAV/Client.php:230)
  /// so callers can inspect per-property HTTP statuses as required by
  /// RFC 4918 §9.1.2.
  Future<Map<String, Map<int, Map<String, XmlElement>>>> propFindRaw(
    String path, {
    PropsDepth depth = PropsDepth.zero,
    List<String> properties = PropfindType.defaultFindProperties,
    PropfindType findType = PropfindType.prop,
    Map<String, String> namespaces = const <String, String>{},
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final xmlStr = findType.buildXmlStr(
      properties,
      namespaceMap: namespaces,
    );

    final resp = await _client.wdPropfind(
      path,
      depth,
      xmlStr,
      cancelToken: cancelToken,
      headers: headers,
    );

    final str = resp.data;
    if (str == null) {
      throw WebdavException(
        message: 'No data returned',
        statusCode: resp.statusCode,
      );
    }

    final rawMap = parseMultiStatusToMap(str);
    if (rawMap.isEmpty) {
      return const {};
    }

    final normalized = <String, Map<int, Map<String, XmlElement>>>{};
    rawMap.forEach((href, statuses) {
      final key = href.isNotEmpty ? href : path;
      final statusMap =
          normalized.putIfAbsent(key, () => <int, Map<String, XmlElement>>{});

      statuses.forEach((statusCode, properties) {
        statusMap.update(
          statusCode,
          (existing) {
            final merged = Map<String, XmlElement>.from(existing);
            merged.addAll(properties);
            return merged;
          },
          ifAbsent: () => Map<String, XmlElement>.from(properties),
        );
      });
    });

    return normalized;
  }
}

String? _firstHrefText(XmlElement? element) {
  return _hrefList(element).firstOrNull;
}

List<String> _hrefList(XmlElement? element) {
  if (element == null) {
    return const <String>[];
  }
  return element
      .findAllElements('href', namespaceUri: '*')
      .map((href) => href.innerText.trim())
      .where((href) => href.isNotEmpty)
      .toList(growable: false);
}

String _normalizeHrefForPropFind(String href) {
  if (href.isEmpty) {
    return href;
  }
  try {
    final uri = Uri.parse(href);
    final path =
        uri.hasScheme || uri.hasAuthority || uri.hasQuery || uri.hasFragment
            ? uri.path
            : href;
    return _decodePropFindHref(path);
  } on FormatException {
    return _decodePropFindHref(href);
  }
}

String _decodePropFindHref(String href) {
  try {
    return Uri.decodeFull(href);
  } on FormatException {
    return href;
  }
}
