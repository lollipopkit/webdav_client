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
    if (resp.statusCode != 200) {
      throw _newResponseError(resp);
    }
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

    final percent = quotaUsed / quotaAvailable;
    return (
      percent,
      '${quotaUsed / 1024 / 1024}M/${quotaAvailable / 1024 / 1024}M'
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
    CancelToken? cancelToken,
    PropfindType findType = PropfindType.prop,
  }) async {
    path = _fixCollectionPath(path);

    final xmlStr = findType.buildXmlStr(properties);

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
  }) async {
    // path = _fixSlashes(path);

    final xmlStr = findType.buildXmlStr(properties);

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
  Future<void> mkdir(String path, {CancelToken? cancelToken}) async {
    path = _fixCollectionPath(path);
    var resp = await _client.wdMkcol(path, cancelToken: cancelToken);
    var status = resp.statusCode;
    if (status != 201 && status != 405) {
      throw _newResponseError(resp);
    }
  }

  /// Recursively create folders
  ///
  /// - [path] of the folder
  /// - [cancelToken] for cancelling the request
  Future<void> mkdirAll(String path, {CancelToken? cancelToken}) async {
    path = _fixCollectionPath(path);
    final resp = await _client.wdMkcol(path, cancelToken: cancelToken);
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
        final resp = await _client.wdMkcol(sub, cancelToken: cancelToken);
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
  Future<void> remove(String path, {CancelToken? cancelToken}) {
    return removeAll(path, cancelToken: cancelToken);
  }

  /// Remove files
  ///
  /// - [path] of the resource
  /// - [cancelToken] for cancelling the request
  Future<void> removeAll(String path, {CancelToken? cancelToken}) async {
    final resp = await _client.wdDelete(path, cancelToken: cancelToken);
    if (resp.statusCode == 200 ||
        resp.statusCode == 204 ||
        resp.statusCode == 404) {
      return;
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
  /// {@endtemplate}
  Future<void> rename(
    String oldPath,
    String newPath, {
    bool overwrite = false,
    CancelToken? cancelToken,
    PropsDepth? depth,
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
    );
  }

  /// Move a folder or file
  /// If you move the folder, some webdav services require a '/' at the end of the path.
  ///
  /// - [oldPath] of the resource
  /// - [newPath] of the resource
  /// - [overwrite] If true, the destination will be overwritten
  /// - [cancelToken] for cancelling the request
  /// - [depth] of the PROPFIND request
  ///
  /// {@macro webdav_client_rename}
  Future<void> move(
    String oldPath,
    String newPath, {
    bool overwrite = false,
    CancelToken? cancelToken,
    PropsDepth? depth,
  }) {
    return rename(
      oldPath,
      newPath,
      overwrite: overwrite,
      cancelToken: cancelToken,
      depth: depth,
    );
  }

  /// Copy a file / folder.
  ///
  /// - [oldPath] of the resource
  /// - [newPath] of the resource
  /// - [overwrite] If true, the destination will be overwritten
  /// - [cancelToken] for cancelling the request
  ///
  /// **Warning:**
  /// If copied the folder (A > B), it will copy all the contents of folder A to folder B.
  /// Some webdav services have been tested and found to **delete** the original contents of the B folder.
  Future<void> copy(
    String oldPath,
    String newPath, {
    bool overwrite = false,
    CancelToken? cancelToken,
  }) {
    return _client.wdCopyMove(
      oldPath,
      newPath,
      true,
      overwrite,
      cancelToken: cancelToken,
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
      xmlBuilder.namespace('d', 'DAV:');
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
    CancelToken? cancelToken,
  }) async {
    final xmlBuilder = XmlBuilder();
    xmlBuilder.processing('xml', 'version="1.0" encoding="utf-8"');
    xmlBuilder.element('d:propertyupdate', nest: () {
      xmlBuilder.namespace('d', 'DAV:');
      xmlBuilder.element('d:set', nest: () {
        xmlBuilder.element('d:prop', nest: () {
          properties.forEach((key, value) {
            final parts = key.split(':');
            if (parts.length == 2) {
              final prefix = parts[0];
              final propName = parts[1];
              xmlBuilder.element('$prefix:$propName', nest: value);
            } else {
              xmlBuilder.element('d:$key', nest: value);
            }
          });
        });
      });
    });

    final xmlString = xmlBuilder.buildDocument().toString();
    await _client.wdProppatch(path, xmlString, cancelToken: cancelToken);
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
    CancelToken? cancelToken,
  }) async {
    final xmlBuilder = XmlBuilder();
    xmlBuilder.processing('xml', 'version="1.0" encoding="utf-8"');
    xmlBuilder.element('d:propertyupdate', nest: () {
      xmlBuilder.namespace('d', 'DAV:');

      // Add common namespace declarations for all custom properties
      final allProps = <String>{};
      if (setProps != null) allProps.addAll(setProps.keys);
      if (removeProps != null) allProps.addAll(removeProps);

      final namespaces = <String>{};
      for (final prop in allProps) {
        final parts = prop.split(':');
        if (parts.length == 2 && parts[0] != 'd') {
          namespaces.add(parts[0]);
        }
      }

      // Register all namespaces at the root level
      for (final ns in namespaces) {
        xmlBuilder.namespace(ns, 'http://example.com/ns/$ns');
      }

      // Set properties
      if (setProps != null && setProps.isNotEmpty) {
        xmlBuilder.element('d:set', nest: () {
          xmlBuilder.element('d:prop', nest: () {
            setProps.forEach((key, value) {
              final parts = key.split(':');
              if (parts.length == 2) {
                final prefix = parts[0];
                final propName = parts[1];
                xmlBuilder.element('$prefix:$propName', nest: value);
              } else {
                xmlBuilder.element('d:$key', nest: value);
              }
            });
          });
        });
      }

      // Delete properties
      if (removeProps != null && removeProps.isNotEmpty) {
        xmlBuilder.element('d:remove', nest: () {
          xmlBuilder.element('d:prop', nest: () {
            for (final key in removeProps) {
              final parts = key.split(':');
              if (parts.length == 2) {
                final prefix = parts[0];
                final propName = parts[1];
                xmlBuilder.element('$prefix:$propName');
              } else {
                xmlBuilder.element('d:$key');
              }
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

    // Check if any properties failed to update
    if (resp.statusCode == 207) {
      final xmlDocument = XmlDocument.parse(resp.data as String);
      final responseElements = findAllElements(xmlDocument, 'response');

      for (final response in responseElements) {
        final propstatElements = findElements(response, 'propstat');
        for (final propstat in propstatElements) {
          final statusElement = findElements(propstat, 'status').firstOrNull;
          if (statusElement != null) {
            final statusText = statusElement.innerText;
            // Check non-200 status codes
            if (!statusText.contains('200') && !statusText.contains('204')) {
              final href = getElementText(response, 'href') ?? '';

              // Get the prop names that failed for better error messages
              final failedProps = <String>[];
              final propElement = findElements(propstat, 'prop').firstOrNull;
              if (propElement != null) {
                for (var prop in propElement.childElements) {
                  failedProps.add(prop.name.qualified);
                }
              }

              throw WebdavException(
                message:
                    'Failed to update properties for $href: $statusText. Failed props: $failedProps',
                statusCode: 422,
              );
            }
          }
        }
      }
    } else if (resp.statusCode != 200) {
      throw _newResponseError(resp);
    }
  }
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
    final resourceTag = Uri.encodeFull(joinPath(url, path));

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
      // 确保 ETag 格式正确
      resourceConditions.add(notTag ? '(Not ["$etag"])' : '(["$etag"])');
    }

    if (resourceConditions.isNotEmpty) {
      taggedList.write(' ${resourceConditions.join(' ')}');
      conditions.add(taggedList.toString());
    }

    return conditions.join(' ');
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
}
