part of '../client.dart';

extension WebdavClientMk on WebdavClient {
  /// Create a folder
  ///
  /// Per RFC 4918 §9.3.1, MKCOL can accept an XML request body to set
  /// initial properties on the newly created collection.
  ///
  /// - [path] of the folder
  /// - [body] optional XML body per RFC 4918 §9.3.1 to set initial properties
  /// - [cancelToken] for cancelling the request
  /// - [ifHeader] supplies preconditions such as lock tokens via an HTTP If header
  Future<void> mkdir(
    String path, {
    dynamic body,
    CancelToken? cancelToken,
    String? ifHeader,
    Map<String, dynamic>? headers,
  }) async {
    path = _fixCollectionPath(path);
    final resp = await _client.wdMkcol(
      path,
      data: body,
      cancelToken: cancelToken,
      ifHeader: ifHeader,
      headers: headers,
    );
    final status = resp.statusCode;
    if (status != 201 && status != 405) {
      throw _newResponseError(resp);
    }
  }

  /// Create a collection with initial dead properties using an RFC 4918
  /// extended MKCOL request body.
  Future<void> mkdirWithProps(
    String path,
    Map<String, String> properties, {
    Map<String, String> namespaces = const <String, String>{},
    CancelToken? cancelToken,
    String? ifHeader,
    Map<String, dynamic>? headers,
  }) {
    final resolution = resolvePropertyNames(
      properties.keys,
      namespaceMap: namespaces,
    );
    final entries = properties.entries.toList(growable: false);

    final xmlBuilder = XmlBuilder();
    xmlBuilder.processing('xml', 'version="1.0" encoding="utf-8"');
    xmlBuilder.element('d:mkcol', nest: () {
      xmlBuilder.namespaceUri('d', 'DAV:');
      resolution.namespaces.forEach((prefix, uri) {
        if (prefix == 'd') return;
        xmlBuilder.namespaceUri(prefix, uri);
      });
      xmlBuilder.element('d:set', nest: () {
        xmlBuilder.element('d:prop', nest: () {
          for (var i = 0; i < resolution.properties.length; i++) {
            xmlBuilder.element(
              resolution.properties[i].qualifiedName,
              nest: entries[i].value,
            );
          }
        });
      });
    });

    return mkdir(
      path,
      body: xmlBuilder.buildDocument().toString(),
      cancelToken: cancelToken,
      ifHeader: ifHeader,
      headers: headers,
    );
  }

  /// Recursively create folders
  ///
  /// - [path] of the folder
  /// - [cancelToken] for cancelling the request
  /// - [ifHeader] supplies preconditions such as lock tokens via an HTTP If header
  Future<void> mkdirAll(
    String path, {
    CancelToken? cancelToken,
    String? ifHeader,
    Map<String, dynamic>? headers,
  }) async {
    path = _fixCollectionPath(path);
    final resp = await _client.wdMkcol(
      path,
      cancelToken: cancelToken,
      ifHeader: ifHeader,
      headers: headers,
    );
    final status = resp.statusCode;
    if (status == 201 || status == 405) {
      return;
    }
    if (status == 409) {
      final pathOnly = path.split('?').first.split('#').first;
      final paths = pathOnly.split('/').where((segment) => segment.isNotEmpty);
      final sub = StringBuffer('/');
      for (final e in paths) {
        sub.write('$e/');
        final resp = await _client.wdMkcol(
          sub.toString(),
          cancelToken: cancelToken,
          ifHeader: ifHeader,
          headers: headers,
        );
        final status = resp.statusCode;
        if (status != 201 && status != 405) {
          throw _newResponseError(resp);
        }
      }
      return;
    }
    throw _newResponseError(resp);
  }
}
