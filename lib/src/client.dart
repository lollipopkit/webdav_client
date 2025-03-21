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
import 'package:webdav_client_plus/src/xml.dart';
import 'package:xml/xml.dart';

part 'dio.dart';
part 'error.dart';

/// WebDav Client
class WebdavClient {
  /// WebDAV url
  final String url;

  /// Wrapped http client
  final _client = _WdDio();

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
    var resp = await _client.wdOptions(this, '/', cancelToken: cancelToken);
    if (resp.statusCode != 200) {
      throw _newResponseError(resp);
    }
  }

  // Future<void> getQuota([CancelToken cancelToken]) async {
  //   var resp = await c.wdQuota(this, quotaXmlStr, cancelToken: cancelToken);
  //   print(resp);
  // }

  /// Read all files in a folder
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
      this,
      path,
      depth,
      xmlStr,
      cancelToken: cancelToken,
    );

    final str = resp.data as String;
    return WebdavXml.toFiles(path, str);
  }

  /// Read a single files properties
  Future<WebdavFile?> readProps(
    String path, {
    CancelToken? cancelToken,
    PropfindType findType = PropfindType.prop,
    List<String> properties = PropfindType.defaultFindProperties,
  }) async {
    // path = _fixSlashes(path);

    final xmlStr = findType.buildXmlStr(properties);

    final resp = await _client.wdPropfind(
      this,
      path,
      PropsDepth.zero,
      xmlStr,
      cancelToken: cancelToken,
    );

    final str = resp.data as String;
    return WebdavXml.toFiles(path, str, skipSelf: false).firstOrNull;
  }

  /// Create a folder
  Future<void> mkdir(String path, [CancelToken? cancelToken]) async {
    path = _fixCollectionPath(path);
    var resp = await _client.wdMkcol(this, path, cancelToken: cancelToken);
    var status = resp.statusCode;
    if (status != 201 && status != 405) {
      throw _newResponseError(resp);
    }
  }

  /// Recursively create folders
  Future<void> mkdirAll(String path, [CancelToken? cancelToken]) async {
    path = _fixCollectionPath(path);
    var resp = await _client.wdMkcol(this, path, cancelToken: cancelToken);
    var status = resp.statusCode;
    if (status == 201 || status == 405) {
      return;
    } else if (status == 409) {
      var paths = path.split('/');
      var sub = '/';
      for (var e in paths) {
        if (e == '') {
          continue;
        }
        sub += '$e/';
        resp = await _client.wdMkcol(this, sub, cancelToken: cancelToken);
        status = resp.statusCode;
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
  Future<void> remove(String path, [CancelToken? cancelToken]) {
    return removeAll(path, cancelToken);
  }

  /// Remove files
  Future<void> removeAll(String path, [CancelToken? cancelToken]) async {
    final resp = await _client.wdDelete(this, path, cancelToken: cancelToken);
    if (resp.statusCode == 200 ||
        resp.statusCode == 204 ||
        resp.statusCode == 404) {
      return;
    }
    throw _newResponseError(resp);
  }

  /// Rename a folder or file
  /// If you rename the folder, some webdav services require a '/' at the end of the path.
  Future<void> rename(
    String oldPath,
    String newPath, {
    bool overwrite = false,
    CancelToken? cancelToken,
  }) {
    return _client.wdCopyMove(
      this,
      oldPath,
      newPath,
      false,
      overwrite,
      cancelToken: cancelToken,
    );
  }

  /// Copy a file / folder from A to B.
  ///
  /// If copied the folder (A > B), it will copy all the contents of folder A to folder B.
  ///
  /// **Warning:**
  /// Some webdav services have been tested and found to **delete** the original contents of the B folder!!!
  Future<void> copy(
    String oldPath,
    String newPath, {
    bool overwrite = false,
    CancelToken? cancelToken,
  }) {
    return _client.wdCopyMove(
      this,
      oldPath,
      newPath,
      true,
      overwrite,
      cancelToken: cancelToken,
    );
  }

  /// Read the bytes of a file
  /// It is best not to open debug mode, otherwise the byte data is too large and the output results in IDE cards, 😄
  Future<List<int>> read(
    String path, {
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) {
    return _client.wdReadWithBytes(
      this,
      path,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  /// Read the bytes of a file with stream and write to a local file
  Future<void> readFile(
    String remotePath,
    String localPath, {
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    await _client.wdReadWithStream(
      this,
      remotePath,
      localPath,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  /// Write the bytes to remote path
  Future<void> write(
    String path,
    Uint8List data, {
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) {
    return _client.wdWriteWithBytes(
      this,
      path,
      data,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  /// Read local file stream and write to remote file
  Future<void> writeFile(
    String localPath,
    String remotePath, {
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    var file = io.File(localPath);
    return _client.wdWriteWithStream(
      this,
      remotePath,
      file.openRead(),
      file.lengthSync(),
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  /// Check if a resource exists
  Future<bool> exists(String path, {CancelToken? cancelToken}) async {
    try {
      await readProps(path, cancelToken: cancelToken);
      return true;
    } on WebdavException catch (e) {
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
          message: 'If header is required for lock refresh',
          statusCode: 400,
        );
      }

      final resp = await _client.wdLock(
        this,
        path,
        null, // Refresh lock does not require a lockinfo XML body
        depth: depth,
        timeout: timeout,
        cancelToken: cancelToken,
        ifHeader: ifHeader,
      );

      // RFC 4918 Section 9.10.2
      // We need to get the new lock token from the response
      final str = resp.data as String;
      try {
        return _extractLockToken(str);
      } catch (e) {
        // If can't extract the lock token, try to get it from the ifHeader
        final lockToken = _extractLockTokenFromIfHeader(ifHeader);
        if (lockToken != null) {
          return lockToken;
        }
        rethrow;
      }
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
      this,
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

  /// Unlock a resource
  Future<void> unlock(String path, String lockToken,
      [CancelToken? cancelToken]) async {
    await _client.wdUnlock(this, path, lockToken, cancelToken: cancelToken);
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
    await _client.wdProppatch(this, path, xmlString, cancelToken: cancelToken);
  }

  /// Put a resource according to the conditions
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
      final conditions = <String>[];
      final resourceTag = Uri.encodeFull(joinPath(url, path));
      final taggedList = StringBuffer('<$resourceTag>');

      final resourceConditions = <String>[];
      if (lockToken != null) {
        resourceConditions
            .add(notTag ? '(Not <$lockToken>)' : '(<$lockToken>)');
      }

      if (etag != null) {
        resourceConditions.add(notTag ? '(Not ["$etag"])' : '(["$etag"])');
      }

      if (taggedList.isNotEmpty) {
        taggedList.write(' ${resourceConditions.join(' ')}');
        conditions.add(taggedList.toString());
      }

      requestHeaders['If'] = conditions.join(' ');
    }

    await _client.wdWriteWithBytes(
      this,
      path,
      data,
      additionalHeaders: headers,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  /// Modify properties of a resource
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
    final resp = await _client.wdProppatch(this, path, xmlString,
        cancelToken: cancelToken);

    // Check if any properties failed to update
    if (resp.statusCode == 207) {
      final xmlDocument = XmlDocument.parse(resp.data as String);
      final responseElements =
          WebdavXml.findAllElements(xmlDocument, 'response');

      for (final response in responseElements) {
        final propstatElements = WebdavXml.findElements(response, 'propstat');
        for (final propstat in propstatElements) {
          final statusElement =
              WebdavXml.findElements(propstat, 'status').firstOrNull;
          if (statusElement != null) {
            final statusText = statusElement.innerText;
            // Check non-200 status codes
            if (!statusText.contains('200') && !statusText.contains('204')) {
              final href = WebdavXml.getElementText(response, 'href') ?? '';

              // Get the prop names that failed for better error messages
              final failedProps = <String>[];
              final propElement =
                  WebdavXml.findElements(propstat, 'prop').firstOrNull;
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

// Extract the lock token from the response
String _extractLockToken(String xmlString) {
  final document = XmlDocument.parse(xmlString);

  // Try to find the lock token in a locktoken element
  final lockTokenElements =
      document.findAllElements('locktoken', namespace: '*');
  for (final lockToken in lockTokenElements) {
    final href = lockToken.findElements('href', namespace: '*').firstOrNull;
    if (href != null) {
      final text = href.innerText;
      if (text.isNotEmpty) {
        return text;
      }
    }
  }

  // If the lock token is not in a locktoken element, try to find it in a href element
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

String _fixCollectionPath(String path) {
  if (!path.startsWith('/')) {
    path = '/$path';
  }
  if (!path.endsWith('/')) {
    return '$path/';
  }
  return path;
}
