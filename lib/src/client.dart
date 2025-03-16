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
    ReadPropsDepth depth = ReadPropsDepth.one,
    CancelToken? cancelToken,
  }) async {
    path = _fixSlashes(path);
    final resp = await _client.wdPropfind(
      this,
      path,
      depth,
      fileXmlStr,
      cancelToken: cancelToken,
    );

    String str = resp.data;
    return WebdavXml.toFiles(path, str);
  }

  /// Read a single files properties
  Future<WebdavFile?> readProps(String path, [CancelToken? cancelToken]) async {
    // path = _fixSlashes(path);
    final resp = await _client.wdPropfind(
      this,
      path,
      ReadPropsDepth.zero,
      fileXmlStr,
      cancelToken: cancelToken,
    );

    final str = resp.data;
    return WebdavXml.toFiles(path, str, skipSelf: false).firstOrNull;
  }

  /// Create a folder
  Future<void> mkdir(String path, [CancelToken? cancelToken]) async {
    path = _fixSlashes(path);
    var resp = await _client.wdMkcol(this, path, cancelToken: cancelToken);
    var status = resp.statusCode;
    if (status != 201 && status != 405) {
      throw _newResponseError(resp);
    }
  }

  /// Recursively create folders
  Future<void> mkdirAll(String path, [CancelToken? cancelToken]) async {
    path = _fixSlashes(path);
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

  Future<bool> exists(String path, [CancelToken? cancelToken]) async {
    try {
      await readProps(path, cancelToken);
      return true;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return false;
      }
      rethrow;
    }
  }

  /// Lock a resource
  ///
  /// - [exclusive] If true, the lock is exclusive; if false, the lock is shared
  /// - [timeout] of the lock in seconds
  ///
  /// Returns the lock token
  Future<String> lock(
    String path, {
    bool exclusive = true,
    int timeout = 3600,
    String? owner,
    ReadPropsDepth depth = ReadPropsDepth.infinity,
    CancelToken? cancelToken,
  }) async {
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
        xmlBuilder.element('d:owner', nest: () {
          xmlBuilder.element('d:href', nest: owner);
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
    );

    return _extractLockToken(resp.data);
  }

  /// Unlock a resource
  Future<void> unlock(String path, String lockToken,
      [CancelToken? cancelToken]) async {
    await _client.wdUnlock(this, path, lockToken, cancelToken: cancelToken);
  }

  /// Set properties of a resource
  /// - [properties] is a map of key-value pairs
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

  /// 使用条件头执行PUT操作
  /// [lockToken] - 资源的锁令牌
  /// [etag] - 资源的ETag，用于确保只有在资源匹配时才更新
  Future<void> conditionalPut(
    String path,
    Uint8List data, {
    String? lockToken,
    String? etag,
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final headers = <String, dynamic>{};

    // 构建If头
    if (lockToken != null || etag != null) {
      final conditions = <String>[];

      if (lockToken != null) {
        conditions.add('(<$lockToken>)');
      }

      if (etag != null) {
        conditions.add('([$etag])');
      }

      headers['If'] = conditions.join(' ');
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
}

// Extract the lock token from the response
String _extractLockToken(String xmlString) {
  final document = XmlDocument.parse(xmlString);
  final hrefElements = document.findAllElements('href', namespace: '*');

  for (final href in hrefElements) {
    final text = href.innerText;
    if (text.startsWith('urn:uuid:') || text.startsWith('opaquelocktoken:')) {
      return text;
    }
  }

  throw Exception('No lock token found in response');
}

String _fixSlashes(String s) {
  if (!s.startsWith('/')) {
    s = '/$s';
  }
  if (!s.endsWith('/')) {
    return '$s/';
  }
  return s;
}
