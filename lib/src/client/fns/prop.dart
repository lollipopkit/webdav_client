part of '../client.dart';

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
    CancelToken? cancelToken,
  }) async {
    final xmlBuilder = XmlBuilder();
    xmlBuilder.processing('xml', 'version="1.0" encoding="utf-8"');
    xmlBuilder.element('d:propertyupdate', nest: () {
      xmlBuilder.namespace('DAV:', 'd');

      final resolution = resolvePropertyNames(
        properties.keys,
        namespaceMap: namespaces,
      );

      resolution.namespaces.forEach((prefix, uri) {
        if (prefix == 'd') return;
        xmlBuilder.namespace(uri, prefix);
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
    );
    _ensurePropPatchSuccess(resp);
  }

  /// Put a resource according to the conditions
  ///
  /// - [path] of the resource
  /// - [data] to write
  /// - [lockToken] If the resource is locked, the lock token must match
  /// - [etag] If the resource has an etag, it must match the etag in the request
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
    CancelToken? cancelToken,
  }) async {
    final xmlBuilder = XmlBuilder();
    xmlBuilder.processing('xml', 'version="1.0" encoding="utf-8"');
    xmlBuilder.element('d:propertyupdate', nest: () {
      xmlBuilder.namespace('DAV:', 'd');

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
        xmlBuilder.namespace(uri, prefix);
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
    );
    _ensurePropPatchSuccess(resp);
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
