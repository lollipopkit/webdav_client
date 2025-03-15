import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'dart:io' as io;
import 'auth.dart';
import 'file.dart';
import 'utils.dart';
import 'xml.dart';

import 'adapter/adapter_stub.dart'
    if (dart.library.io) 'adapter/adapter_mobile.dart'
    if (dart.library.js) 'adapter/adapter_web.dart';

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
  Future<List<WebdavFile>> readDir(String path,
      [CancelToken? cancelToken]) async {
    path = _fixSlashes(path);
    final resp = await _client.wdPropfind(this, path, true, fileXmlStr,
        cancelToken: cancelToken);

    String str = resp.data;
    return WebdavXml.toFiles(path, str);
  }

  /// Read a single files properties
  Future<WebdavFile?> readProps(String path, [CancelToken? cancelToken]) async {
    // path = _fixSlashes(path);
    final resp = await _client.wdPropfind(this, path, true, fileXmlStr,
        cancelToken: cancelToken);

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
        sub += e + '/';
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
    var resp =
        await _client.wdDelete(this, path, cancelToken: cancelToken);
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
}

String _fixSlashes(String s) {
  if (!s.startsWith('/')) {
    s = '/${s}';
  }
  if (!s.endsWith('/')) {
    return s + '/';
  }
  return s;
}

class _WdDio with DioMixin implements Dio {
  // // Request config
  // BaseOptions? baseOptions;

  _WdDio({BaseOptions? options}) {
    this.options = options ?? BaseOptions();
    // 禁止重定向
    this.options.followRedirects = false;

    // 状态码错误视为成功
    this.options.validateStatus = (status) => true;

    httpClientAdapter = getAdapter();
  }

  // methods-------------------------
  Future<Response<T>> req<T>(
    WebdavClient self,
    String method,
    String path, {
    dynamic data,
    Function(Options)? optionsHandler,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
  }) async {
    // options
    Options options = Options(method: method);
    if (options.headers == null) {
      options.headers = {};
    }

    // 二次处理options
    if (optionsHandler != null) {
      optionsHandler(options);
    }

    // authorization
    String? str = self.auth.authorize(method, path);
    if (str != null) {
      options.headers?['authorization'] = str;
    }

    var resp = await requestUri<T>(
      Uri.parse(
          '${path.startsWith(RegExp(r'(http|https)://')) ? path : _join(self.url, path)}'),
      options: options,
      data: data,
      onSendProgress: onSendProgress,
      onReceiveProgress: onReceiveProgress,
      cancelToken: cancelToken,
    );

    if (resp.statusCode == 401) {
      final w3AHeader = resp.headers.value('www-authenticate');
      final lowerW3AHeader = w3AHeader?.toLowerCase();

      final exception = switch (self.auth) {
        /// TODO: handle this
        final NoAuth _ => () => _newResponseError(resp),
        final DigestAuth digestAuth => () {
            final isStale = lowerW3AHeader?.contains('stale=true') == true;
            if (!isStale) return _newResponseError(resp);
            self.auth = DigestAuth(
                user: digestAuth.user,
                pwd: digestAuth.pwd,
                digestParts: DigestParts(w3AHeader));
          }(),
        _ => _newResponseError(resp),
      };

      if (exception != null) {
        throw exception;
      }

      // retry
      return req<T>(
        self,
        method,
        path,
        data: data,
        optionsHandler: optionsHandler,
        onSendProgress: onSendProgress,
        onReceiveProgress: onReceiveProgress,
        cancelToken: cancelToken,
      );
    } else if (resp.statusCode == 302) {
      // 文件位置被重定向到新路径
      if (resp.headers.map.containsKey('location')) {
        List<String>? list = resp.headers.map['location'];
        if (list != null && list.isNotEmpty) {
          String redirectPath = list[0];
          // retry
          return req<T>(
            self,
            method,
            redirectPath,
            data: data,
            optionsHandler: optionsHandler,
            onSendProgress: onSendProgress,
            onReceiveProgress: onReceiveProgress,
            cancelToken: cancelToken,
          );
        }
      }
    }

    return resp;
  }

  // OPTIONS
  Future<Response> wdOptions(WebdavClient self, String path,
      {CancelToken? cancelToken}) {
    return req(self, 'OPTIONS', path,
        optionsHandler: (options) => options.headers?['depth'] = '0',
        cancelToken: cancelToken);
  }

  // // quota
  // Future<Response> wdQuota(Client self, String dataStr,
  //     {CancelToken cancelToken}) {
  //   return req(self, 'PROPFIND', '/', data: utf8.encode(dataStr),
  //       optionsHandler: (options) {
  //     options.headers['depth'] = '0';
  //     options.headers['accept'] = 'text/plain';
  //   }, cancelToken: cancelToken);
  // }

  // PROPFIND
  Future<Response> wdPropfind(
      WebdavClient self, String path, bool depth, String dataStr,
      {CancelToken? cancelToken}) async {
    var resp = await req(self, 'PROPFIND', path, data: dataStr,
        optionsHandler: (options) {
      options.headers?['depth'] = depth ? '1' : '0';
      options.headers?['content-type'] = 'application/xml;charset=UTF-8';
      options.headers?['accept'] = 'application/xml,text/xml';
      options.headers?['accept-charset'] = 'utf-8';
      options.headers?['accept-encoding'] = '';
    }, cancelToken: cancelToken);

    if (resp.statusCode != 207) {
      throw _newResponseError(resp);
    }

    return resp;
  }

  /// MKCOL
  Future<Response> wdMkcol(WebdavClient self, String path,
      {CancelToken? cancelToken}) {
    return req(self, 'MKCOL', path, cancelToken: cancelToken);
  }

  /// DELETE
  Future<Response> wdDelete(WebdavClient self, String path,
      {CancelToken? cancelToken}) {
    return req(self, 'DELETE', path, cancelToken: cancelToken);
  }

  /// COPY OR MOVE
  Future<void> wdCopyMove(WebdavClient self, String oldPath, String newPath,
      bool isCopy, bool overwrite,
      {CancelToken? cancelToken}) async {
    var method = isCopy == true ? 'COPY' : 'MOVE';
    var resp = await req(self, method, oldPath, optionsHandler: (options) {
      options.headers?['destination'] =
          Uri.encodeFull(_join(self.url, newPath));
      options.headers?['overwrite'] = overwrite == true ? 'T' : 'F';
    }, cancelToken: cancelToken);

    var status = resp.statusCode;
    if (status == 201 || status == 204) {
      return;
    } else if (status == 207) {
      // Handle Multi-Status response (207)
      // Parse the XML response to determine if any critical operations failed
      String responseData = resp.data.toString();
      if (responseData.contains('<status>HTTP/1.1 5')) {
        // If response contains any 5xx errors, consider it a failure
        throw DioException(
          requestOptions: resp.requestOptions,
          response: resp,
          type: DioExceptionType.badResponse,
          error: 'Multi-Status operation partially failed: $responseData',
        );
      }
      // Otherwise, operation was successful enough to proceed
      return;
    } else if (status == 409) {
      await _createParent(self, newPath, cancelToken: cancelToken);
      return wdCopyMove(self, oldPath, newPath, isCopy, overwrite,
          cancelToken: cancelToken);
    } else {
      throw _newResponseError(resp);
    }
  }

  /// create parent folder
  Future<void>? _createParent(WebdavClient self, String path,
      {CancelToken? cancelToken}) {
    var parentPath = path.substring(0, path.lastIndexOf('/') + 1);

    if (parentPath == '' || parentPath == '/') {
      return null;
    }
    return self.mkdirAll(parentPath, cancelToken);
  }

  /// read a file with bytes
  Future<List<int>> wdReadWithBytes(
    WebdavClient self,
    String path, {
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    // fix auth error
    var pResp = await wdOptions(self, path, cancelToken: cancelToken);
    if (pResp.statusCode != 200) {
      throw _newResponseError(pResp);
    }

    var resp = await req(
      self,
      'GET',
      path,
      optionsHandler: (options) => options.responseType = ResponseType.bytes,
      onReceiveProgress: onProgress,
      cancelToken: cancelToken,
    );
    if (resp.statusCode != 200) {
      if (resp.statusCode != null) {
        if (resp.statusCode! >= 300 && resp.statusCode! < 400) {
          return (await req(
            self,
            'GET',
            resp.headers["location"]!.first,
            optionsHandler: (options) =>
                options.responseType = ResponseType.bytes,
            onReceiveProgress: onProgress,
            cancelToken: cancelToken,
          ))
              .data;
        }
      }
      throw _newResponseError(resp);
    }
    return resp.data;
  }

  /// read a file with stream
  Future<void> wdReadWithStream(
    WebdavClient self,
    String path,
    String savePath, {
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    // fix auth error
    var pResp = await wdOptions(self, path, cancelToken: cancelToken);
    if (pResp.statusCode != 200) {
      throw _newResponseError(pResp);
    }

    Response<ResponseBody> resp;

    // Reference Dio download
    // request
    try {
      resp = await req(
        self,
        'GET',
        path,
        optionsHandler: (options) => options.responseType = ResponseType.stream,
        // onReceiveProgress: onProgress,
        cancelToken: cancelToken,
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.badResponse) {
        if (e.response!.requestOptions.receiveDataWhenStatusError == true) {
          var res = await transformer.transformResponse(
            e.response!.requestOptions..responseType = ResponseType.json,
            e.response!.data as ResponseBody,
          );
          e.response!.data = res;
        } else {
          e.response!.data = null;
        }
      }
      rethrow;
    }
    if (resp.statusCode != 200) {
      throw _newResponseError(resp);
    }

    resp.headers = Headers.fromMap(resp.data!.headers);

    // If directory (or file) doesn't exist yet, the entire method fails
    final file = File(savePath);
    await file.create(recursive: true);

    var raf = await file.open(mode: FileMode.write);

    //Create a Completer to notify the success/error state.
    final completer = Completer<Response>();
    var future = completer.future;
    var received = 0;

    // Stream<Uint8List>
    final stream = resp.data!.stream;
    var compressed = false;
    var total = 0;
    final contentEncoding = resp.headers.value(Headers.contentEncodingHeader);
    if (contentEncoding != null) {
      compressed = ['gzip', 'deflate', 'compress'].contains(contentEncoding);
    }
    if (compressed) {
      total = -1;
    } else {
      final contentLength = resp.headers.value(Headers.contentLengthHeader);
      if (contentLength != null) {
        final parsed = int.tryParse(contentLength);
        if (parsed != null) {
          total = parsed;
        }
      } else {
        total = -1;
      }
    }

    late StreamSubscription subscription;
    Future? asyncWrite;
    var closed = false;
    Future _closeAndDelete() async {
      if (!closed) {
        closed = true;
        await asyncWrite;
        await raf.close();
        await file.delete();
      }
    }

    subscription = stream.listen(
      (data) {
        subscription.pause();
        // Write file asynchronously
        asyncWrite = raf.writeFrom(data).then((_raf) {
          // Notify progress
          received += data.length;

          onProgress?.call(received, total);

          raf = _raf;
          if (cancelToken == null || !cancelToken.isCancelled) {
            subscription.resume();
          }
        }).catchError((err) async {
          try {
            await subscription.cancel();
          } finally {
            completer.completeError(DioException(
              requestOptions: resp.requestOptions,
              error: err,
            ));
          }
        });
      },
      onDone: () async {
        try {
          await asyncWrite;
          closed = true;
          await raf.close();
          completer.complete(resp);
        } catch (err) {
          completer.completeError(DioException(
            requestOptions: resp.requestOptions,
            error: err,
          ));
        }
      },
      onError: (e) async {
        try {
          await _closeAndDelete();
        } finally {
          completer.completeError(DioException(
            requestOptions: resp.requestOptions,
            error: e,
          ));
        }
      },
      cancelOnError: true,
    );

    // ignore: unawaited_futures
    cancelToken?.whenCancel.then((_) async {
      await subscription.cancel();
      await _closeAndDelete();
    });

    if (resp.requestOptions.receiveTimeout != null &&
        resp.requestOptions.receiveTimeout!
                .compareTo(Duration(milliseconds: 0)) >
            0) {
      future = future
          .timeout(resp.requestOptions.receiveTimeout!)
          .catchError((Object err) async {
        await subscription.cancel();
        await _closeAndDelete();
        if (err is TimeoutException) {
          throw DioException(
            requestOptions: resp.requestOptions,
            error:
                'Receiving data timeout[${resp.requestOptions.receiveTimeout}ms]',
            type: DioExceptionType.receiveTimeout,
          );
        } else {
          throw err;
        }
      });
    }
    // ignore: invalid_use_of_internal_member
    await DioMixin.listenCancelForAsyncTask(cancelToken, future);
  }

  /// write a file with bytes
  Future<void> wdWriteWithBytes(
    WebdavClient self,
    String path,
    Uint8List data, {
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    // fix auth error
    var pResp = await wdOptions(self, path, cancelToken: cancelToken);
    if (pResp.statusCode != 200) {
      throw _newResponseError(pResp);
    }

    // mkdir
    await _createParent(self, path, cancelToken: cancelToken);

    var resp = await req(
      self,
      'PUT',
      path,
      data: Stream.fromIterable(data.map((e) => [e])),
      optionsHandler: (options) =>
          options.headers?['content-length'] = data.length,
      onSendProgress: onProgress,
      cancelToken: cancelToken,
    );
    var status = resp.statusCode;
    if (status == 200 || status == 201 || status == 204) {
      return;
    }
    throw _newResponseError(resp);
  }

  /// write a file with stream
  Future<void> wdWriteWithStream(
    WebdavClient self,
    String path,
    Stream<List<int>> data,
    int length, {
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    // fix auth error
    var pResp = await wdOptions(self, path, cancelToken: cancelToken);
    if (pResp.statusCode != 200) {
      throw _newResponseError(pResp);
    }

    // mkdir
    await _createParent(self, path, cancelToken: cancelToken);

    var resp = await req(
      self,
      'PUT',
      path,
      data: data,
      optionsHandler: (options) {
        options.headers?['content-length'] = length;
        options.headers?['content-type'] = 'application/octet-stream';
      },
      onSendProgress: onProgress,
      cancelToken: cancelToken,
    );
    var status = resp.statusCode;
    if (status == 200 || status == 201 || status == 204) {
      return;
    }
    throw _newResponseError(resp);
  }
}

// create response error
DioException _newResponseError(Response resp) {
  return DioException(
      requestOptions: resp.requestOptions,
      response: resp,
      type: DioExceptionType.badResponse,
      error: resp.statusMessage);
}

String _join(String path0, String path1) {
  return rtrim(path0, '/') + '/' + ltrim(path1, '/');
}
