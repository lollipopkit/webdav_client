import 'dart:async';
import 'dart:io' as io;
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:webdav_client_plus/src/adapter/adapter_stub.dart'
    if (dart.library.io) 'adapter/adapter_mobile.dart'
    if (dart.library.js) 'adapter/adapter_web.dart';
import 'package:webdav_client_plus/src/auth.dart';
import 'package:webdav_client_plus/src/enums.dart';
import 'package:webdav_client_plus/src/file.dart';
import 'package:webdav_client_plus/src/utils.dart';
import 'package:xml/xml.dart';

part 'dio.dart';
part 'error.dart';

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
  Future<void> ping([CancelToken? cancelToken]) async {
    final resp = await _client.wdOptions('/', cancelToken: cancelToken);
    final status = resp.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw _newResponseError(resp);
    }
  }

  /// Discover DAV capabilities advertised by the server via the `DAV` header.
  ///
  /// Returns an ordered list of feature tokens, mirroring SabreDAV's
  /// [Client::options] helper (see `dav/lib/DAV/Client.php:371`) and
  /// complying with RFC 4918 §7.7.
  Future<List<String>> options({
    String path = '/',
    bool allowNotFound = false,
    CancelToken? cancelToken,
  }) async {
    final resp = await _client.wdOptions(
      path,
      cancelToken: cancelToken,
      allowNotFound: allowNotFound,
    );
    final davHeader = resp.headers.value('dav');
    if (davHeader == null || davHeader.trim().isEmpty) {
      return const [];
    }
    return davHeader
        .split(',')
        .map((feature) => feature.trim())
        .where((feature) => feature.isNotEmpty)
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

  /// Get the quota of the server
  ///
  /// - [cancelToken] for cancelling the request
  Future<(double percent, String size)> quota({
    CancelToken? cancelToken,
  }) async {
    final resp = await _client.wdPropfind(
      '/',
      PropsDepth.zero,
      PropfindType.prop.buildXmlStr([
        'quota-available-bytes',
        'quota-used-bytes',
      ]),
      cancelToken: cancelToken,
    );

    final str = resp.data as String;
    final file = WebdavFile.parseFiles('/', str, skipSelf: false).firstOrNull;
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

  /// Read all files in a folder
  ///
  /// - [path] of the folder
  /// - [depth] of the PROPFIND request
  /// - [properties] is a list of properties to read
  /// - [cancelToken] for cancelling the request
  /// - [findType] is the type of PROPFIND request
  Future<List<WebdavFile>> readDir(
    String path, {
    PropsDepth depth = PropsDepth.one,
    List<String> properties = PropfindType.defaultFindProperties,
    Map<String, String> namespaces = const <String, String>{},
    CancelToken? cancelToken,
    PropfindType findType = PropfindType.prop,
  }) async {
    path = _fixCollectionPath(path);

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

    return WebdavFile.parseFiles(path, str);
  }

  /// Read a single files properties
  ///
  /// - [path] of the file
  /// - [properties] is a list of properties to read
  /// - [cancelToken] for cancelling the request
  /// - [findType] is the type of PROPFIND request
  Future<WebdavFile?> readProps(
    String path, {
    CancelToken? cancelToken,
    PropfindType findType = PropfindType.prop,
    List<String> properties = PropfindType.defaultFindProperties,
    Map<String, String> namespaces = const <String, String>{},
  }) async {
    // path = _fixSlashes(path);

    final xmlStr = findType.buildXmlStr(
      properties,
      namespaceMap: namespaces,
    );

    final resp = await _client.wdPropfind(
      path,
      PropsDepth.zero,
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

    return WebdavFile.parseFiles(path, str, skipSelf: false).firstOrNull;
  }

  /// Create a folder
  ///
  /// - [path] of the folder
  /// - [cancelToken] for cancelling the request
  /// - [ifHeader] supplies preconditions such as lock tokens via an HTTP If header
  Future<void> mkdir(
    String path, {
    CancelToken? cancelToken,
    String? ifHeader,
  }) async {
    path = _fixCollectionPath(path);
    final resp = await _client.wdMkcol(
      path,
      cancelToken: cancelToken,
      ifHeader: ifHeader,
    );
    var status = resp.statusCode;
    if (status != 201 && status != 405) {
      throw _newResponseError(resp);
    }
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
  }) async {
    path = _fixCollectionPath(path);
    final resp = await _client.wdMkcol(
      path,
      cancelToken: cancelToken,
      ifHeader: ifHeader,
    );
    final status = resp.statusCode;
    if (status == 201 || status == 405) {
      return;
    }
    if (status == 409) {
      final paths = path.split('/');
      var sub = '/';
      for (var e in paths) {
        if (e == '') {
          continue;
        }
        sub += '$e/';
        final resp = await _client.wdMkcol(
          sub,
          cancelToken: cancelToken,
          ifHeader: ifHeader,
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

  /// Remove a folder or file
  /// If you remove the folder, some webdav services require a '/' at the end of the path.
  ///
  /// - [path] of the resource
  /// - [cancelToken] for cancelling the request
  /// - [ifHeader] supplies preconditions such as lock tokens via an HTTP If header
  Future<void> remove(
    String path, {
    CancelToken? cancelToken,
    String? ifHeader,
  }) {
    return removeAll(
      path,
      cancelToken: cancelToken,
      ifHeader: ifHeader,
    );
  }

  /// Remove files
  ///
  /// - [path] of the resource
  /// - [cancelToken] for cancelling the request
  /// - [ifHeader] supplies preconditions such as lock tokens via an HTTP If header
  Future<void> removeAll(
    String path, {
    CancelToken? cancelToken,
    String? ifHeader,
  }) async {
    final resp = await _client.wdDelete(
      path,
      cancelToken: cancelToken,
      ifHeader: ifHeader,
    );
    final status = resp.statusCode ?? -1;
    if (status == 200 || status == 202 || status == 204 || status == 404) {
      return;
    }
    if (status == 207) {
      final body = resp.data;
      if (body is! String || body.isEmpty) {
        throw WebdavException(
          message:
              'DELETE returned 207 Multi-Status without an XML response body to inspect',
          statusCode: status,
          statusMessage: resp.statusMessage,
          response: resp,
        );
      }
      try {
        final failures = parseMultiStatusFailureMessages(body);
        if (failures.isEmpty) {
          // RFC 4918 §8.7 requires Multi-Status to describe at least one member.
          throw WebdavException(
            message: 'DELETE reported Multi-Status but no member failures',
            statusCode: status,
            statusMessage: resp.statusMessage,
            response: resp,
          );
        }
        throw WebdavException(
          message: failures.join('; '),
          statusCode: status,
          statusMessage: resp.statusMessage,
          response: resp,
        );
      } on XmlException catch (error) {
        throw WebdavException(
          message: 'Unable to parse DELETE Multi-Status response: $error',
          statusCode: status,
          statusMessage: resp.statusMessage,
          response: resp,
        );
      }
    }
    throw _newResponseError(resp);
  }

  /// Rename a folder or file
  /// If you rename the folder, some webdav services require a '/' at the end of the path.
  ///
  /// {@template webdav_client_rename}
  /// - [oldPath] of the resource
  /// - [newPath] of the resource
  /// - [overwrite] If true, the destination will be overwritten
  /// - [cancelToken] for cancelling the request
  /// - [depth] of the PROPFIND request
  /// - [ifHeader] supplies preconditions such as lock tokens via an HTTP If header
  /// {@endtemplate}
  Future<void> rename(
    String oldPath,
    String newPath, {
    bool overwrite = false,
    CancelToken? cancelToken,
    PropsDepth? depth,
    String? ifHeader,
  }) {
    if (depth != null &&
        depth != PropsDepth.infinity &&
        oldPath.endsWith('/')) {
      // If endpoint is a collection, depth must be infinity
      depth = PropsDepth.infinity;
    }

    return _client.wdCopyMove(
      oldPath,
      newPath,
      false,
      overwrite,
      cancelToken: cancelToken,
      depth: depth ?? PropsDepth.infinity,
      ifHeader: ifHeader,
    );
  }

  /// Move a folder or file
  /// If you move the folder, some webdav services require a '/' at the end of the path.
  ///
  /// - [oldPath] of the resource
  /// - [newPath] of the resource
  /// - [overwrite] If true, the destination will be overwritten
  /// - [cancelToken] for cancelling the request
  /// - [ifHeader] supplies preconditions such as lock tokens via an HTTP If header
  /// - [depth] of the PROPFIND request
  ///
  /// {@macro webdav_client_rename}
  Future<void> move(
    String oldPath,
    String newPath, {
    bool overwrite = false,
    CancelToken? cancelToken,
    PropsDepth? depth,
    String? ifHeader,
  }) {
    return rename(
      oldPath,
      newPath,
      overwrite: overwrite,
      cancelToken: cancelToken,
      depth: depth,
      ifHeader: ifHeader,
    );
  }

  /// Copy a file / folder.
  ///
  /// - [oldPath] of the resource
  /// - [newPath] of the resource
  /// - [overwrite] If true, the destination will be overwritten
  /// - [cancelToken] for cancelling the request
  /// - [ifHeader] supplies preconditions such as lock tokens via an HTTP If header
  ///
  /// **Warning:**
  /// If copied the folder (A > B), it will copy all the contents of folder A to folder B.
  /// Some webdav services have been tested and found to **delete** the original contents of the B folder.
  Future<void> copy(
    String oldPath,
    String newPath, {
    bool overwrite = false,
    CancelToken? cancelToken,
    String? ifHeader,
  }) {
    return _client.wdCopyMove(
      oldPath,
      newPath,
      true,
      overwrite,
      cancelToken: cancelToken,
      ifHeader: ifHeader,
    );
  }

  /// Read the bytes of a file
  ///
  /// - [path] of the file
  /// - [onProgress] callback for progress
  /// - [cancelToken] for cancelling the request
  Future<Uint8List> read(
    String path, {
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) {
    return _client.wdReadWithBytes(
      path,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  /// Read the bytes of a file with stream and write to a local file
  ///
  /// - [remotePath] of the file
  /// - [localPath] of the local file
  /// - [onProgress] callback for progress
  /// - [cancelToken] for cancelling the request
  Future<void> readFile(
    String remotePath,
    String localPath, {
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    await _client.wdReadWithStream(
      remotePath,
      localPath,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  /// Write the bytes to remote path
  ///
  /// - [path] of the file
  /// - [data] to write
  /// - [onProgress] callback for progress
  /// - [cancelToken] for cancelling the request
  Future<void> write(
    String path,
    Uint8List data, {
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) {
    return _client.wdWriteWithBytes(
      path,
      data,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  /// Read local file stream and write to remote file
  ///
  /// - [localPath] of the local file
  /// - [remotePath] of the remote file
  /// - [onProgress] callback for progress
  /// - [cancelToken] for cancelling the request
  Future<void> writeFile(
    String localPath,
    String remotePath, {
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    var file = io.File(localPath);
    return _client.wdWriteWithStream(
      remotePath,
      file.openRead(),
      file.lengthSync(),
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

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

  /// Lock a resource
  ///
  /// - [path] of the resource
  /// - [exclusive] If true, the lock is exclusive; if false, the lock is shared
  /// - [timeout] of the lock in seconds
  ///
  /// Returns the lock token
  Future<String> lock(
    String path, {
    bool exclusive = true,
    int timeout = 3600,
    String? owner,
    PropsDepth depth = PropsDepth.infinity,
    String? ifHeader,
    bool refreshLock = false,
    CancelToken? cancelToken,
  }) async {
    if (depth == PropsDepth.one) {
      throw ArgumentError(
        'LOCK depth must be 0 or infinity per RFC 4918 §9.10.3',
      );
    }

    if (refreshLock) {
      if (ifHeader == null) {
        throw WebdavException(
          message: '`If` header is required for lock refresh',
          statusCode: 400,
        );
      }

      // Extract the lock token from the If header so we have it even if the server doesn't return it in the response
      final existingLockToken = _extractLockTokenFromIfHeader(ifHeader);
      if (existingLockToken == null) {
        throw WebdavException(
          message: 'Valid lock token not found in If header',
          statusCode: 400,
        );
      }

      final resp = await _client.wdLock(
        path,
        null, // Empty body for lock refresh
        depth: depth,
        timeout: timeout,
        cancelToken: cancelToken,
        ifHeader: ifHeader,
      );

      if (resp.statusCode != 200) {
        throw _newResponseError(resp);
      }

      // RFC 4918 9.10.2
      // Returns the same lock token if the lock was successfully refreshed
      return existingLockToken;
    }

    final xmlBuilder = XmlBuilder();
    xmlBuilder.processing('xml', 'version="1.0" encoding="utf-8"');
    xmlBuilder.element('d:lockinfo', nest: () {
      xmlBuilder.namespace('DAV:', 'd');
      xmlBuilder.element('d:lockscope', nest: () {
        xmlBuilder.element(exclusive ? 'd:exclusive' : 'd:shared');
      });
      xmlBuilder.element('d:locktype', nest: () {
        xmlBuilder.element('d:write');
      });
      if (owner != null) {
        // RFC 4918 14.17
        // The owner XML can contain any XML content, so we need to handle URLs
        xmlBuilder.element('d:owner', nest: () {
          // If the owner is a URL, it must be wrapped in a <d:href> tag
          if (owner.startsWith('http://') || owner.startsWith('https://')) {
            xmlBuilder.element('d:href', nest: owner);
          } else {
            xmlBuilder.text(owner);
          }
        });
      }
    });

    final xmlString = xmlBuilder.buildDocument().toString();
    final resp = await _client.wdLock(
      path,
      xmlString,
      depth: depth,
      timeout: timeout,
      cancelToken: cancelToken,
      ifHeader: ifHeader,
    );

    // Check if the lock was successful
    final status = resp.statusCode;
    if (status != 200 && status != 201) {
      throw _newResponseError(resp);
    }

    final str = resp.data as String;
    return _extractLockToken(str);
  }

  /// Unlock a resource
  ///
  /// - [path] of the resource
  /// - [lockToken] of the resource
  /// - [cancelToken] for cancelling the request
  Future<void> unlock(
    String path,
    String lockToken, {
    CancelToken? cancelToken,
  }) async {
    await _client.wdUnlock(path, lockToken, cancelToken: cancelToken);
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
    final requestHeaders = headers ?? <String, dynamic>{};

    // Construct the If header
    if (lockToken != null || etag != null) {
      requestHeaders['If'] = _buildIfHeader(url, path, lockToken, etag, notTag);
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
}

/// Result of parsing a WebDAV Multi-Status response.
class MultiStatusResponse {
  /// The decoded href of the resource the response applies to.
  final String href;

  /// Top-level HTTP status code (outside of propstat blocks), if present.
  final int? statusCode;

  /// Raw status text as transmitted by the server for the top-level status.
  final String? rawStatus;

  /// Detailed propstat blocks grouped by status code.
  final List<MultiStatusPropstat> propstats;

  const MultiStatusResponse({
    required this.href,
    required this.propstats,
    this.statusCode,
    this.rawStatus,
  });
}

/// A single propstat block within a Multi-Status response.
class MultiStatusPropstat {
  /// HTTP status code parsed from the propstat status line, if available.
  final int? statusCode;

  /// Raw status text as transmitted by the server.
  final String? rawStatus;

  /// Properties reported for this status, keyed by Clark notation
  /// (e.g. `{DAV:}getetag`). Values expose the original XML element so callers
  /// can inspect complex content if needed.
  final Map<String, XmlElement> properties;

  const MultiStatusPropstat({
    required this.properties,
    this.statusCode,
    this.rawStatus,
  });
}

/// Parse an RFC 4918 Multi-Status XML body into structured responses, closely
/// following the behaviour of SabreDAV's `Client::parseMultiStatus`.
List<MultiStatusResponse> parseMultiStatus(String xmlString) {
  final document = XmlDocument.parse(xmlString);
  final responses = <MultiStatusResponse>[];

  for (final responseElement in findAllElements(document, 'response')) {
    final href = getElementText(responseElement, 'href');
    final decodedHref =
        href != null && href.isNotEmpty ? Uri.decodeFull(href) : '';

    final overallStatusElement = responseElement.childElements.firstWhereOrNull(
      (element) =>
          element.name.local == 'status' &&
          element.parentElement == responseElement,
    );
    final overallStatusText = overallStatusElement?.innerText;
    final overallStatusCode =
        overallStatusText != null ? _parseStatusCode(overallStatusText) : null;

    final propstats = <MultiStatusPropstat>[];
    for (final propstatElement in findElements(responseElement, 'propstat')) {
      final statusElement = findElements(propstatElement, 'status').firstOrNull;
      final statusText = statusElement?.innerText;
      final statusCode =
          statusText != null ? _parseStatusCode(statusText) : null;

      final propElement = findElements(propstatElement, 'prop').firstOrNull;
      final properties = <String, XmlElement>{};
      if (propElement != null) {
        for (final prop in propElement.childElements) {
          final namespaceUri = prop.name.namespaceUri ?? '';
          final key = namespaceUri.isEmpty
              ? prop.name.local
              : '{$namespaceUri}${prop.name.local}';
          properties[key] = prop;
        }
      }

      propstats.add(
        MultiStatusPropstat(
          properties: properties,
          statusCode: statusCode,
          rawStatus: statusText,
        ),
      );
    }

    responses.add(
      MultiStatusResponse(
        href: decodedHref,
        propstats: propstats,
        statusCode: overallStatusCode,
        rawStatus: overallStatusText,
      ),
    );
  }

  return responses;
}

List<String> parsePropPatchFailureMessages(String xmlString) {
  final responses = parseMultiStatus(xmlString);
  final failures = <String>[];

  for (final response in responses) {
    for (final propstat in response.propstats) {
      final status = propstat.statusCode;
      if (status != null && status >= 400) {
        final propNames = propstat.properties.values
            .map(_formatPropertyName)
            .toList();
        final statusText = propstat.rawStatus ?? 'HTTP status $status';
        failures.add(
          'Failed to update properties for ${response.href}: '
          '$statusText. Failed props: $propNames',
        );
      }
    }
  }

  return failures;
}

List<String> parseMultiStatusFailureMessages(String xmlString) {
  final responses = parseMultiStatus(xmlString);
  final failures = <String>[];

  for (final response in responses) {
    final status = response.statusCode;
    if (status != null && status >= 400) {
      final statusText = response.rawStatus ?? 'HTTP status $status';
      failures.add('Failed to process ${response.href}: $statusText');
    }

    for (final propstat in response.propstats) {
      final statusCode = propstat.statusCode;
      if (statusCode == null || statusCode < 400) {
        continue;
      }
      final statusText = propstat.rawStatus ?? 'HTTP status $statusCode';
      final props = propstat.properties.values
          .map(_formatPropertyName)
          .toList();
      final propsSuffix = props.isEmpty ? '' : '. Props: $props';
      failures.add(
        'Failed to process ${response.href}: $statusText$propsSuffix',
      );
    }
  }

  return failures;
}

String _formatPropertyName(XmlElement element) {
  final prefix = element.name.prefix;
  if (prefix != null && prefix.isNotEmpty) {
    return '$prefix:${element.name.local}';
  }

  final namespace = element.name.namespaceUri;
  if (namespace != null && namespace.isNotEmpty) {
    return '{$namespace}${element.name.local}';
  }

  return element.name.local;
}

extension _Utils on WebdavClient {
  // Extract the lock token from the response
  String _extractLockToken(String xmlString) {
    final document = XmlDocument.parse(xmlString);

    // First, try activelock/locktoken/href
    final activeLockElements =
        document.findAllElements('activelock', namespace: '*');
    for (final activeLock in activeLockElements) {
      final lockTokenElements =
          activeLock.findElements('locktoken', namespace: '*');
      for (final lockToken in lockTokenElements) {
        final href = lockToken.findElements('href', namespace: '*').firstOrNull;
        if (href != null && href.innerText.isNotEmpty) {
          return href.innerText;
        }
      }
    }

    // Fall back to locktoken/href
    final lockTokenElements =
        document.findAllElements('locktoken', namespace: '*');
    for (final lockToken in lockTokenElements) {
      final href = lockToken.findElements('href', namespace: '*').firstOrNull;
      if (href != null && href.innerText.isNotEmpty) {
        return href.innerText;
      }
    }

    // Try
    final hrefElements = document.findAllElements('href', namespace: '*');
    for (final href in hrefElements) {
      final text = href.innerText;
      if (text.startsWith('urn:uuid:') || text.startsWith('opaquelocktoken:')) {
        return text;
      }
    }

    throw WebdavException(
      message: 'No lock token found in response',
      statusCode: 500,
    );
  }

  String? _extractLockTokenFromIfHeader(String ifHeader) {
    final regex = RegExp(r'<([^>]+)>');
    final matches = regex.allMatches(ifHeader);
    for (final match in matches) {
      final token = match.group(1);
      if (token != null &&
          (token.startsWith('urn:uuid:') ||
              token.startsWith('opaquelocktoken:'))) {
        return token;
      }
    }
    return null;
  }

  String _buildIfHeader(
    String url,
    String path,
    String? lockToken,
    String? etag,
    bool notTag,
  ) {
    if (lockToken == null && etag == null) return '';

    final conditions = <String>[];
    final resourceTag = resolveAgainstBaseUrl(url, path);

    // 确保资源标记是完整的 URL
    final taggedList = StringBuffer('<$resourceTag>');

    final resourceConditions = <String>[];
    if (lockToken != null) {
      // 确保锁令牌格式正确
      final formattedLockToken =
          lockToken.startsWith('<') ? lockToken : '<$lockToken>';
      resourceConditions
          .add(notTag ? '(Not $formattedLockToken)' : '($formattedLockToken)');
    }

    if (etag != null) {
      final formattedEtag = _formatEntityTag(etag);
      resourceConditions
          .add(notTag ? '(Not [$formattedEtag])' : '([$formattedEtag])');
    }

    if (resourceConditions.isNotEmpty) {
      taggedList.write(' ${resourceConditions.join(' ')}');
      conditions.add(taggedList.toString());
    }

    return conditions.join(' ');
  }

  String _formatEntityTag(String etag) {
    var trimmed = etag.trim();
    var isWeak = false;

    if (trimmed.startsWith('W/')) {
      isWeak = true;
      trimmed = trimmed.substring(2).trim();
    }

    final normalized = _ensureQuoted(trimmed);
    return isWeak ? 'W/$normalized' : normalized;
  }

  String _ensureQuoted(String value) {
    var result = value.trim();
    if (!result.startsWith('"')) {
      result = '"$result';
    }
    if (!result.endsWith('"')) {
      result = '$result"';
    }
    return result;
  }

  String _fixCollectionPath(String path) {
    if (!path.startsWith('/')) {
      path = '/$path';
    }
    if (!path.endsWith('/')) {
      return '$path/';
    }
    return path;
  }

  void _ensurePropPatchSuccess(Response<String> resp) {
    final status = resp.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw _newResponseError(resp);
    }

    if (status != 207) {
      // RFC 4918 §9.2 allows other 2xx statuses for high-level responses.
      return;
    }

    final xmlString = resp.data;
    if (xmlString == null || xmlString.isEmpty) {
      throw WebdavException(
        message:
            'PROPPATCH response did not include a multi-status body to inspect',
        statusCode: resp.statusCode,
        statusMessage: resp.statusMessage,
        response: resp,
      );
    }

    try {
      final failures = parsePropPatchFailureMessages(xmlString);
      if (failures.isNotEmpty) {
        throw WebdavException(
          message: failures.join('; '),
          statusCode: 422,
          statusMessage: resp.statusMessage,
          response: resp,
        );
      }
    } on XmlException catch (error) {
      throw WebdavException(
        message: 'Unable to parse PROPPATCH response: $error',
        statusCode: resp.statusCode,
        statusMessage: resp.statusMessage,
        response: resp,
      );
    }
  }
}

int? _parseStatusCode(String statusText) {
  final match = RegExp(r'\b(\d{3})\b').firstMatch(statusText);
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}
