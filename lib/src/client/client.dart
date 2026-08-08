import 'dart:async';
import 'dart:io' as io;
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:webdav_client_plus/src/adapter/adapter_stub.dart'
    if (dart.library.io) 'package:webdav_client_plus/src/adapter/adapter_mobile.dart'
    if (dart.library.js) 'package:webdav_client_plus/src/adapter/adapter_web.dart';
import 'package:webdav_client_plus/src/auth.dart';
import 'package:webdav_client_plus/src/enums.dart';
import 'package:webdav_client_plus/src/internal/iterable_extensions.dart';
import 'package:webdav_client_plus/src/internal/path_utils.dart';
import 'package:webdav_client_plus/src/internal/property_resolution.dart';
import 'package:webdav_client_plus/src/internal/xml_utils.dart';
import 'package:webdav_client_plus/src/models/webdav_file.dart';
import 'package:xml/xml.dart';

part 'dio.dart';
part 'error.dart';
part 'utils.dart';

part 'fns/mk.dart';
part 'fns/read.dart';
part 'fns/prop.dart';
part 'fns/lock.dart';
part 'fns/copy_move.dart';
part 'fns/write.dart';
part 'fns/rm.dart';

/// One property requested by an RFC 3253 expand-property REPORT.
class ExpandProperty {
  /// Property name in DAV local-name, prefixed or Clark notation.
  final String name;

  /// Nested properties to expand below [name].
  final List<ExpandProperty> children;

  const ExpandProperty(this.name, [this.children = const <ExpandProperty>[]]);
}

/// Webdav Client
class WebdavClient {
  /// WebDAV url
  final String url;

  /// Wrapped http client
  late final _client = _WdDio(client: this);

  /// Auth Mode (noAuth/basic/digest/bearer)
  Auth auth;

  /// Create a client with username and password
  WebdavClient({
    required this.url,
    this.auth = const NoAuth(),
  });

  /// Create a client with basic auth
  WebdavClient.basicAuth({
    required this.url,
    required String user,
    required String pwd,
  }) : auth = BasicAuth(user: user, pwd: pwd);

  /// Create a client with bearer token
  WebdavClient.bearerToken({
    required this.url,
    required String token,
  }) : auth = BearerAuth(token: token);

  /// Create a client with no authentication
  WebdavClient.noAuth({
    required this.url,
  }) : auth = const NoAuth();

  // methods--------------------------------

  /// Set the public request headers
  void setHeaders(Map<String, dynamic> headers) =>
      _client.options.headers = headers;

  /// Set the connection server timeout time in milliseconds.
  void setConnectTimeout(int timeout) =>
      _client.options.connectTimeout = Duration(milliseconds: timeout);

  /// Set send data timeout time in milliseconds.
  void setSendTimeout(int timeout) =>
      _client.options.sendTimeout = Duration(milliseconds: timeout);

  /// Set transfer data time in milliseconds.
  void setReceiveTimeout(int timeout) =>
      _client.options.receiveTimeout = Duration(milliseconds: timeout);

  /// Test whether the service can connect
  Future<void> ping([
    CancelToken? cancelToken,
    Map<String, dynamic>? headers,
  ]) async {
    final resp = await _client.wdOptions(
      '/',
      cancelToken: cancelToken,
      headers: headers,
    );
    final status = resp.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw _newResponseError(resp);
    }
  }

  /// Retrieve resource metadata without a response body per RFC 4918 §9.4.
  ///
  /// Returns the raw [Response] so callers can inspect headers such as
  /// `ETag`, `Content-Length`, `Content-Type`, and `Last-Modified`.
  Future<Response<void>> head(
    String path, {
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) {
    return _client.wdHead(
      path,
      headers: headers,
      cancelToken: cancelToken,
    );
  }

  /// Resolve a relative WebDAV target against this client's base URL.
  ///
  /// Mirrors SabreDAV's `Client::getAbsoluteUrl` helper and uses the same
  /// collection-prefix preserving resolver as the request pipeline.
  String absoluteUrl(String target) => resolveAgainstBaseUrl(url, target);

  /// Discover DAV capabilities advertised by the server via the `DAV` header.
  ///
  /// Returns an ordered list of feature tokens, mirroring SabreDAV's
  /// [Client::options] helper (see `dav/lib/DAV/Client.php:371`) and
  /// complying with RFC 4918 §7.7.
  Future<List<String>> options({
    String path = '/',
    bool allowNotFound = false,
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final resp = await _client.wdOptions(
      path,
      cancelToken: cancelToken,
      allowNotFound: allowNotFound,
      headers: headers,
    );
    final davHeaders = resp.headers['dav'];
    if (davHeaders == null || davHeaders.isEmpty) {
      return const [];
    }
    return davHeaders
        .expand((header) => header.split(','))
        .map((feature) => feature.trim())
        .where((feature) => feature.isNotEmpty)
        .toList(growable: false);
  }

  /// Discover HTTP methods advertised by the server via the `Allow` header.
  Future<List<String>> allowedMethods({
    String path = '/',
    bool allowNotFound = false,
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final resp = await _client.wdOptions(
      path,
      cancelToken: cancelToken,
      allowNotFound: allowNotFound,
      headers: headers,
    );
    final allowHeaders = resp.headers['allow'];
    if (allowHeaders == null || allowHeaders.isEmpty) {
      return const <String>[];
    }
    return allowHeaders
        .expand((header) => header.split(','))
        .map((method) => method.trim())
        .where((method) => method.isNotEmpty)
        .toList(growable: false);
  }

  /// Send a raw WebDAV request while reusing the client's authentication
  /// pipeline and base URL resolution.
  ///
  /// Mirrors SabreDAV's [`Client::request`](dav/lib/DAV/Client.php:419) so
  /// advanced extensions (REPORT, SEARCH, etc.) can be exercised without
  /// reimplementing Digest handling.
  Future<Response<T>> request<T>(
    String method, {
    String target = '',
    dynamic data,
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
    void Function(Options options)? configure,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
  }) {
    return _client.req<T>(
      method,
      target,
      data: data,
      optionsHandler: (options) {
        if (headers != null && headers.isNotEmpty) {
          options.headers ??= <String, dynamic>{};
          headers.forEach((key, value) {
            options.headers?[key] = value;
          });
        }
        if (configure != null) {
          configure(options);
        }
      },
      onSendProgress: onSendProgress,
      onReceiveProgress: onReceiveProgress,
      cancelToken: cancelToken,
    );
  }

  /// Create a new binding in [collectionPath] for [href] (RFC 5842 §4).
  Future<Response<String>> bind(
    String collectionPath, {
    required String segment,
    required String href,
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) {
    final xmlBuilder = XmlBuilder();
    xmlBuilder.processing('xml', 'version="1.0" encoding="utf-8"');
    xmlBuilder.element('d:bind', nest: () {
      xmlBuilder.namespaceUri('d', 'DAV:');
      xmlBuilder.element('d:segment', nest: segment);
      xmlBuilder.element('d:href', nest: href);
    });
    return _xmlExtensionRequest(
      'BIND',
      collectionPath,
      xmlBuilder.buildDocument().toString(),
      headers: headers,
      cancelToken: cancelToken,
    );
  }

  /// Remove a binding from [collectionPath] (RFC 5842 §5).
  Future<Response<String>> unbind(
    String collectionPath, {
    required String segment,
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) {
    final xmlBuilder = XmlBuilder();
    xmlBuilder.processing('xml', 'version="1.0" encoding="utf-8"');
    xmlBuilder.element('d:unbind', nest: () {
      xmlBuilder.namespaceUri('d', 'DAV:');
      xmlBuilder.element('d:segment', nest: segment);
    });
    return _xmlExtensionRequest(
      'UNBIND',
      collectionPath,
      xmlBuilder.buildDocument().toString(),
      headers: headers,
      cancelToken: cancelToken,
    );
  }

  /// Atomically move a binding into [collectionPath] (RFC 5842 §6).
  Future<Response<String>> rebind(
    String collectionPath, {
    required String segment,
    required String href,
    bool overwrite = false,
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) {
    final xmlBuilder = XmlBuilder();
    xmlBuilder.processing('xml', 'version="1.0" encoding="utf-8"');
    xmlBuilder.element('d:rebind', nest: () {
      xmlBuilder.namespaceUri('d', 'DAV:');
      xmlBuilder.element('d:segment', nest: segment);
      xmlBuilder.element('d:href', nest: href);
    });
    final requestHeaders = <String, dynamic>{
      'Overwrite': overwrite ? 'T' : 'F',
      if (headers != null) ...headers,
    };
    return _xmlExtensionRequest(
      'REBIND',
      collectionPath,
      xmlBuilder.buildDocument().toString(),
      headers: requestHeaders,
      cancelToken: cancelToken,
    );
  }

  /// Subscribe to Microsoft Exchange WebDAV notifications for a resource.
  Future<Response<String>> subscribe(
    String path, {
    String? callback,
    String? subscriptionId,
    int? lifetimeSeconds,
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) {
    final requestHeaders = <String, dynamic>{
      if (callback != null) 'Call-Back': callback,
      if (subscriptionId != null) 'Subscription-ID': subscriptionId,
      if (lifetimeSeconds != null) 'Subscription-Lifetime': lifetimeSeconds,
      if (headers != null) ...headers,
    };
    return request<String>(
      'SUBSCRIBE',
      target: path,
      headers: requestHeaders,
      configure: (options) => options.responseType = ResponseType.plain,
      cancelToken: cancelToken,
    );
  }

  /// Remove a Microsoft Exchange WebDAV notification subscription.
  Future<Response<String>> unsubscribe(
    String path, {
    required String subscriptionId,
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) {
    final requestHeaders = <String, dynamic>{
      'Subscription-ID': subscriptionId,
      if (headers != null) ...headers,
    };
    return request<String>(
      'UNSUBSCRIBE',
      target: path,
      headers: requestHeaders,
      configure: (options) => options.responseType = ResponseType.plain,
      cancelToken: cancelToken,
    );
  }

  /// Synchronize collection changes using WebDAV Sync REPORT (RFC 6578).
  Future<Response<String>> syncCollection(
    String path, {
    String? syncToken,
    PropsDepth depth = PropsDepth.one,
    List<String> properties = PropfindType.defaultFindProperties,
    Map<String, String> namespaces = const <String, String>{},
    int? limit,
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) {
    if (depth == PropsDepth.zero) {
      throw ArgumentError(
        'sync-collection only supports Depth "1" or "infinite" per RFC 6578',
      );
    }
    final xmlBuilder = XmlBuilder();
    xmlBuilder.processing('xml', 'version="1.0" encoding="utf-8"');
    xmlBuilder.element('d:sync-collection', nest: () {
      xmlBuilder.namespaceUri('d', 'DAV:');
      xmlBuilder.element('d:sync-token', nest: syncToken ?? '');
      final syncLevel = depth == PropsDepth.infinity ? 'infinite' : depth.value;
      xmlBuilder.element('d:sync-level', nest: syncLevel);
      if (limit != null) {
        xmlBuilder.element('d:limit', nest: () {
          xmlBuilder.element('d:nresults', nest: limit.toString());
        });
      }
      final resolution = resolvePropertyNames(
        properties,
        namespaceMap: namespaces,
      );
      resolution.namespaces.forEach((prefix, uri) {
        if (prefix == 'd') return;
        xmlBuilder.namespaceUri(prefix, uri);
      });
      xmlBuilder.element('d:prop', nest: () {
        for (final prop in resolution.properties) {
          xmlBuilder.element(prop.qualifiedName);
        }
      });
    });

    return report(
      path,
      xmlBuilder.buildDocument().toString(),
      depth: depth,
      headers: headers,
      cancelToken: cancelToken,
    );
  }

  /// Send an RFC 5323 SEARCH request with DAV:basicsearch XML.
  Future<Response<T>> basicSearch<T>(
    String path,
    String query, {
    PropsDepth depth = PropsDepth.infinity,
    Map<String, String> namespaces = const <String, String>{},
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) {
    final xmlBuilder = XmlBuilder();
    xmlBuilder.processing('xml', 'version="1.0" encoding="utf-8"');
    xmlBuilder.element('d:basicsearch', nest: () {
      xmlBuilder.namespaceUri('d', 'DAV:');
      namespaces.forEach((prefix, uri) {
        if (prefix == 'd') return;
        xmlBuilder.namespaceUri(prefix, uri);
      });
      xmlBuilder.xml(query);
    });
    return search(
      path,
      xmlBuilder.buildDocument().toString(),
      depth: depth,
      headers: headers,
      cancelToken: cancelToken,
    );
  }

  /// Discover DAV:resourcetype values for [path].
  Future<List<String>> resourceTypes({
    String path = '/',
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final props = await propFind(
      path,
      properties: const ['resourcetype'],
      headers: headers,
      cancelToken: cancelToken,
    );
    final resourceType = props['{DAV:}resourcetype'];
    if (resourceType == null) {
      return const <String>[];
    }
    return resourceType.childElements.map(_formatPropertyName).toList(
          growable: false,
        );
  }

  /// Discover supported REPORT names on [path] (RFC 3253 §3.1.5).
  Future<List<String>> supportedReports({
    String path = '/',
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final props = await propFind(
      path,
      properties: const ['supported-report-set'],
      headers: headers,
      cancelToken: cancelToken,
    );
    final supported = props['{DAV:}supported-report-set'];
    if (supported == null) {
      return const <String>[];
    }

    return supported
        .findAllElements('report', namespaceUri: '*')
        .expand((report) => report.childElements)
        .map(_formatPropertyName)
        .toList(growable: false);
  }

  /// Put a resource under version control (RFC 3253 §3.5).
  Future<Response<String>> versionControl(
    String path, {
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) {
    return _emptyExtensionRequest(
      'VERSION-CONTROL',
      path,
      headers: headers,
      cancelToken: cancelToken,
    );
  }

  /// Check out a version-controlled resource (RFC 3253 §4.3).
  Future<Response<String>> checkout(
    String path, {
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) {
    return _emptyExtensionRequest(
      'CHECKOUT',
      path,
      headers: headers,
      cancelToken: cancelToken,
    );
  }

  /// Check in a checked-out resource (RFC 3253 §4.4).
  Future<Response<String>> checkin(
    String path, {
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) {
    return _emptyExtensionRequest(
      'CHECKIN',
      path,
      headers: headers,
      cancelToken: cancelToken,
    );
  }

  /// Cancel a checkout (RFC 3253 §4.5).
  Future<Response<String>> uncheckout(
    String path, {
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) {
    return _emptyExtensionRequest(
      'UNCHECKOUT',
      path,
      headers: headers,
      cancelToken: cancelToken,
    );
  }

  /// Report a version tree for a version resource (RFC 3253 §3.7).
  Future<Response<String>> versionTree(
    String path, {
    List<String> properties = PropfindType.defaultFindProperties,
    Map<String, String> namespaces = const <String, String>{},
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) {
    return _deltaVPropertyReport(
      'version-tree',
      path,
      properties: properties,
      namespaces: namespaces,
      headers: headers,
      cancelToken: cancelToken,
    );
  }

  /// Report all versions reachable from a version-controlled resource.
  Future<Response<String>> versionHistoryReport(
    String path, {
    List<String> properties = PropfindType.defaultFindProperties,
    Map<String, String> namespaces = const <String, String>{},
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) {
    return _deltaVPropertyReport(
      'version-history',
      path,
      properties: properties,
      namespaces: namespaces,
      headers: headers,
      cancelToken: cancelToken,
    );
  }

  Future<Response<String>> _deltaVPropertyReport(
    String reportName,
    String path, {
    required List<String> properties,
    required Map<String, String> namespaces,
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) {
    final resolution =
        resolvePropertyNames(properties, namespaceMap: namespaces);
    final xmlBuilder = XmlBuilder();
    xmlBuilder.processing('xml', 'version="1.0" encoding="utf-8"');
    xmlBuilder.element('d:$reportName', nest: () {
      xmlBuilder.namespaceUri('d', 'DAV:');
      resolution.namespaces.forEach((prefix, uri) {
        if (prefix == 'd') return;
        xmlBuilder.namespaceUri(prefix, uri);
      });
      xmlBuilder.element('d:prop', nest: () {
        for (final prop in resolution.properties) {
          xmlBuilder.element(prop.qualifiedName);
        }
      });
    });

    return report(
      path,
      xmlBuilder.buildDocument().toString(),
      headers: headers,
      cancelToken: cancelToken,
    );
  }

  /// Update a label on a version resource (RFC 3253 §8.2).
  Future<Response<String>> label(
    String path, {
    required String labelName,
    String action = 'set',
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) {
    if (action != 'set' && action != 'add' && action != 'remove') {
      throw ArgumentError.value(action, 'action', 'must be set, add or remove');
    }
    final xmlBuilder = XmlBuilder();
    xmlBuilder.processing('xml', 'version="1.0" encoding="utf-8"');
    xmlBuilder.element('d:label', nest: () {
      xmlBuilder.namespaceUri('d', 'DAV:');
      xmlBuilder.element('d:$action', nest: () {
        xmlBuilder.element('d:label-name', nest: labelName);
      });
    });
    return _xmlExtensionRequest(
      'LABEL',
      path,
      xmlBuilder.buildDocument().toString(),
      headers: headers,
      cancelToken: cancelToken,
    );
  }

  /// Create an activity resource (RFC 3253 §13.5).
  Future<Response<String>> mkactivity(
    String path, {
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) {
    return _emptyExtensionRequest(
      'MKACTIVITY',
      path,
      headers: headers,
      cancelToken: cancelToken,
    );
  }

  /// Put a version-controlled collection under baseline control (RFC 3253 §12).
  Future<Response<String>> baselineControl(
    String path, {
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) {
    return _emptyExtensionRequest(
      'BASELINE-CONTROL',
      path,
      headers: headers,
      cancelToken: cancelToken,
    );
  }

  /// Create a working resource from a version (RFC 3253 §6.3).
  Future<Response<String>> mkworkspace(
    String path, {
    String? sourceHref,
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) {
    if (sourceHref == null) {
      return _emptyExtensionRequest(
        'MKWORKSPACE',
        path,
        headers: headers,
        cancelToken: cancelToken,
      );
    }

    final xmlBuilder = XmlBuilder();
    xmlBuilder.processing('xml', 'version="1.0" encoding="utf-8"');
    xmlBuilder.element('d:mkworkspace', nest: () {
      xmlBuilder.namespaceUri('d', 'DAV:');
      xmlBuilder.element('d:source', nest: () {
        xmlBuilder.element('d:href', nest: sourceHref);
      });
    });
    return _xmlExtensionRequest(
      'MKWORKSPACE',
      path,
      xmlBuilder.buildDocument().toString(),
      headers: headers,
      cancelToken: cancelToken,
    );
  }

  /// Merge a checked-in version into a target resource (RFC 3253 §11.2).
  Future<Response<String>> merge(
    String path,
    String sourceHref, {
    bool noAutoMerge = false,
    bool noCheckout = false,
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) {
    final xmlBuilder = XmlBuilder();
    xmlBuilder.processing('xml', 'version="1.0" encoding="utf-8"');
    xmlBuilder.element('d:merge', nest: () {
      xmlBuilder.namespaceUri('d', 'DAV:');
      xmlBuilder.element('d:source', nest: () {
        xmlBuilder.element('d:href', nest: sourceHref);
      });
      if (noAutoMerge) {
        xmlBuilder.element('d:no-auto-merge');
      }
      if (noCheckout) {
        xmlBuilder.element('d:no-checkout');
      }
    });
    return _xmlExtensionRequest(
      'MERGE',
      path,
      xmlBuilder.buildDocument().toString(),
      headers: headers,
      cancelToken: cancelToken,
    );
  }

  /// Expand nested properties using RFC 3253 expand-property REPORT.
  Future<Response<String>> expandProperty(
    String path,
    List<ExpandProperty> properties, {
    PropsDepth depth = PropsDepth.zero,
    Map<String, String> namespaces = const <String, String>{},
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) {
    final xmlBuilder = XmlBuilder();
    xmlBuilder.processing('xml', 'version="1.0" encoding="utf-8"');
    xmlBuilder.element('d:expand-property', nest: () {
      xmlBuilder.namespaceUri('d', 'DAV:');
      void writeProperty(ExpandProperty property) {
        final resolved = resolvePropertyNames(
          [property.name],
          namespaceMap: namespaces,
        ).properties.single;
        final attributes = <String, String>{'name': resolved.localName};
        if (resolved.namespaceUri != 'DAV:') {
          attributes['namespace'] = resolved.namespaceUri;
        }
        xmlBuilder.element('d:property', attributes: attributes, nest: () {
          for (final child in property.children) {
            writeProperty(child);
          }
        });
      }

      for (final property in properties) {
        writeProperty(property);
      }
    });

    return report(
      path,
      xmlBuilder.buildDocument().toString(),
      depth: depth,
      headers: headers,
      cancelToken: cancelToken,
    );
  }

  /// Poll a resource for asynchronous Microsoft Exchange WebDAV notifications.
  Future<Response<String>> poll(
    String path, {
    String? subscriptionId,
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) {
    final requestHeaders = <String, dynamic>{
      if (subscriptionId != null) 'Subscription-ID': subscriptionId,
      if (headers != null) ...headers,
    };
    return request<String>(
      'POLL',
      target: path,
      headers: requestHeaders,
      configure: (options) => options.responseType = ResponseType.plain,
      cancelToken: cancelToken,
    );
  }

  /// Order members of a collection (RFC 3648 Ordered Collections).
  Future<Response<String>> orderpatch(
    String path,
    String body, {
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) {
    return _xmlExtensionRequest(
      'ORDERPATCH',
      path,
      body,
      headers: headers,
      cancelToken: cancelToken,
    );
  }

  /// Match principals related to a resource (RFC 3744 §9.3).
  Future<Response<String>> principalMatch(
    String path, {
    bool self = false,
    String? property,
    List<String> properties = PropfindType.defaultFindProperties,
    Map<String, String> namespaces = const <String, String>{},
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) {
    if (!self && property == null) {
      throw ArgumentError('Either self must be true or property must be set');
    }

    final returnProperties = resolvePropertyNames(
      properties,
      namespaceMap: namespaces,
    );
    final matchResolution = property == null
        ? null
        : resolvePropertyNames([property], namespaceMap: namespaces);
    final matchProperty = matchResolution?.properties.single;
    final namespaceDeclarations = <String, String>{
      ...returnProperties.namespaces,
      if (matchResolution != null) ...matchResolution.namespaces,
    };

    final xmlBuilder = XmlBuilder();
    xmlBuilder.processing('xml', 'version="1.0" encoding="utf-8"');
    xmlBuilder.element('d:principal-match', nest: () {
      xmlBuilder.namespaceUri('d', 'DAV:');
      namespaceDeclarations.forEach((prefix, uri) {
        if (prefix == 'd') return;
        xmlBuilder.namespaceUri(prefix, uri);
      });
      if (self) {
        xmlBuilder.element('d:self');
      }
      if (matchProperty != null) {
        xmlBuilder.element('d:principal-property', nest: () {
          xmlBuilder.element('d:prop', nest: () {
            xmlBuilder.element(matchProperty.qualifiedName);
          });
        });
      }
      xmlBuilder.element('d:prop', nest: () {
        for (final prop in returnProperties.properties) {
          xmlBuilder.element(prop.qualifiedName);
        }
      });
    });

    return report(
      path,
      xmlBuilder.buildDocument().toString(),
      headers: headers,
      cancelToken: cancelToken,
    );
  }

  /// Search principals by property value (RFC 3744 §9.4).
  Future<Response<String>> principalPropertySearch(
    String path, {
    required String property,
    required String match,
    List<String> properties = PropfindType.defaultFindProperties,
    Map<String, String> namespaces = const <String, String>{},
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) {
    final searchProperty = resolvePropertyNames(
      [property],
      namespaceMap: namespaces,
    );
    final searchPropertyName = searchProperty.properties.single;
    final returnProperties = resolvePropertyNames(
      properties,
      namespaceMap: namespaces,
    );
    final namespaceDeclarations = <String, String>{
      ...returnProperties.namespaces,
      ...searchProperty.namespaces,
    };

    final xmlBuilder = XmlBuilder();
    xmlBuilder.processing('xml', 'version="1.0" encoding="utf-8"');
    xmlBuilder.element('d:principal-property-search', nest: () {
      xmlBuilder.namespaceUri('d', 'DAV:');
      namespaceDeclarations.forEach((prefix, uri) {
        if (prefix == 'd') return;
        xmlBuilder.namespaceUri(prefix, uri);
      });
      xmlBuilder.element('d:property-search', nest: () {
        xmlBuilder.element('d:prop', nest: () {
          xmlBuilder.element(searchPropertyName.qualifiedName);
        });
        xmlBuilder.element('d:match', nest: match);
      });
      xmlBuilder.element('d:prop', nest: () {
        for (final prop in returnProperties.properties) {
          xmlBuilder.element(prop.qualifiedName);
        }
      });
    });

    return report(
      path,
      xmlBuilder.buildDocument().toString(),
      headers: headers,
      cancelToken: cancelToken,
    );
  }

  /// List searchable principal properties (RFC 3744 §9.5).
  Future<Response<String>> principalSearchPropertySet(
    String path, {
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) {
    final xmlBuilder = XmlBuilder();
    xmlBuilder.processing('xml', 'version="1.0" encoding="utf-8"');
    xmlBuilder.element('d:principal-search-property-set', nest: () {
      xmlBuilder.namespaceUri('d', 'DAV:');
    });
    return report(
      path,
      xmlBuilder.buildDocument().toString(),
      headers: headers,
      cancelToken: cancelToken,
    );
  }

  /// Send an ACL request as defined by WebDAV ACL (RFC 3744 §8.1).
  Future<Response<String>> acl(
    String path,
    String body, {
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) {
    final requestHeaders = <String, dynamic>{
      Headers.contentTypeHeader: 'application/xml;charset=UTF-8',
      Headers.acceptHeader: 'application/xml,text/xml',
      if (headers != null) ...headers,
    };

    return request<String>(
      'ACL',
      target: path,
      data: body,
      headers: requestHeaders,
      configure: (options) => options.responseType = ResponseType.plain,
      cancelToken: cancelToken,
    );
  }

  /// Send a REPORT request for WebDAV extensions such as CalDAV/CardDAV.
  Future<Response<T>> report<T>(
    String path,
    String body, {
    PropsDepth depth = PropsDepth.zero,
    Map<String, dynamic>? headers,
    ResponseType responseType = ResponseType.plain,
    CancelToken? cancelToken,
  }) {
    return _xmlExtensionRequest<T>(
      'REPORT',
      path,
      body,
      depth: depth,
      headers: headers,
      responseType: responseType,
      cancelToken: cancelToken,
    );
  }

  /// Send a SEARCH request as defined by WebDAV SEARCH extensions.
  Future<Response<T>> search<T>(
    String path,
    String body, {
    PropsDepth depth = PropsDepth.zero,
    Map<String, dynamic>? headers,
    ResponseType responseType = ResponseType.plain,
    CancelToken? cancelToken,
  }) {
    return _xmlExtensionRequest<T>(
      'SEARCH',
      path,
      body,
      depth: depth,
      headers: headers,
      responseType: responseType,
      cancelToken: cancelToken,
    );
  }

  Future<Response<String>> _emptyExtensionRequest(
    String method,
    String path, {
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) {
    return request<String>(
      method,
      target: path,
      headers: headers,
      configure: (options) => options.responseType = ResponseType.plain,
      cancelToken: cancelToken,
    );
  }

  Future<Response<T>> _xmlExtensionRequest<T>(
    String method,
    String path,
    String body, {
    PropsDepth? depth,
    Map<String, dynamic>? headers,
    ResponseType responseType = ResponseType.plain,
    CancelToken? cancelToken,
  }) {
    final requestHeaders = <String, dynamic>{
      if (depth != null) 'Depth': depth.value,
      Headers.contentTypeHeader: 'application/xml;charset=UTF-8',
      Headers.acceptHeader: 'application/xml,text/xml',
      if (headers != null) ...headers,
    };

    return request<T>(
      method,
      target: path,
      data: body,
      headers: requestHeaders,
      configure: (options) => options.responseType = responseType,
      cancelToken: cancelToken,
    );
  }

  /// Get raw quota byte counts for [path].
  Future<(int usedBytes, int availableBytes)> quotaBytes({
    String path = '/',
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final resp = await _client.wdPropfind(
      path,
      PropsDepth.zero,
      PropfindType.prop.buildXmlStr([
        'quota-available-bytes',
        'quota-used-bytes',
      ]),
      cancelToken: cancelToken,
      headers: headers,
    );

    final str = resp.data as String;
    final file = WebdavFile.parseFiles(path, str, skipSelf: false).firstOrNull;
    if (file == null) {
      throw WebdavException(
        message: 'Quota not found',
        statusCode: 404,
      );
    }

    final quotaAvailable = file.quotaAvailableBytes;
    final quotaUsed = file.quotaUsedBytes;
    if (quotaAvailable == null || quotaUsed == null) {
      throw WebdavException(
        message: 'Quota not found',
        statusCode: 404,
      );
    }

    return (quotaUsed, quotaAvailable);
  }

  /// Get quota information for [path] (defaults to the WebDAV root).
  ///
  /// - [cancelToken] for cancelling the request
  Future<(double percent, String size)> quota({
    String path = '/',
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final (quotaUsed, quotaAvailable) = await quotaBytes(
      path: path,
      headers: headers,
      cancelToken: cancelToken,
    );

    String formatSize(int bytes) {
      final mb = bytes / 1024 / 1024;
      return '${mb.toStringAsFixed(2)}M';
    }

    if (quotaAvailable < 0) {
      return (
        double.nan,
        '${formatSize(quotaUsed)}/unlimited',
      );
    }

    final total = quotaUsed + quotaAvailable;
    if (total <= 0) {
      return (0.0, '0M/0M');
    }

    final percent = quotaUsed / total;
    return (
      percent,
      '${formatSize(quotaUsed)}/${formatSize(total)}',
    );
  }
}
