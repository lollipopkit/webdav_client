part of 'client.dart';

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
  Future<Response> req(
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
    final options = Options(method: method);
    options.headers ??= {};

    // 二次处理options
    if (optionsHandler != null) {
      optionsHandler(options);
    }

    // authorization
    final authStr = self.auth.authorize(method, path);
    if (authStr != null) {
      options.headers?['authorization'] = authStr;
    }

    final resp = await requestUri(
      Uri.parse(path.startsWith(RegExp(r'(http|https)://'))
          ? path
          : joinPath(self.url, path)),
      options: options,
      data: data,
      onSendProgress: onSendProgress,
      onReceiveProgress: onReceiveProgress,
      cancelToken: cancelToken,
    );

    if (resp.statusCode == 401) {
      final w3AHeader = resp.headers.value('www-authenticate');
      final lowerW3AHeader = w3AHeader?.toLowerCase();

      switch (self.auth) {
        case final DigestAuth digestAuth:
          final isDigestChallenge = lowerW3AHeader?.contains('digest') == true;
          if (isDigestChallenge) {
            // Create a new DigestAuth instance with the new challenge
            self.auth = DigestAuth(
              user: digestAuth.user,
              pwd: digestAuth.pwd,
              digestParts: DigestParts(w3AHeader),
            );

            // 重试请求
            return req(
              self,
              method,
              path,
              data: data,
              optionsHandler: optionsHandler,
              onSendProgress: onSendProgress,
              onReceiveProgress: onReceiveProgress,
              cancelToken: cancelToken,
            );
          }
          break;
        case final BasicAuth _:
        case final NoAuth _:
        case final BearerAuth _:
          // TODO: handle this case
          break;
      }

      throw WebdavException.fromResponse(resp, 'Authentication failed');
    } else if (resp.statusCode == 302) {
      // Redirect
      if (resp.headers.map.containsKey('location')) {
        List<String>? list = resp.headers.map['location'];
        if (list != null && list.isNotEmpty) {
          String redirectPath = list[0];
          // retry
          return req(
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
  Future<Response<void>> wdOptions(
    WebdavClient self,
    String path, {
    CancelToken? cancelToken,
  }) {
    return req(
      self,
      'OPTIONS',
      path,
      optionsHandler: (options) => options.headers?['depth'] = '0',
      cancelToken: cancelToken,
    );
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
    WebdavClient self,
    String path,
    ReadPropsDepth depth,
    String dataStr, {
    CancelToken? cancelToken,
  }) async {
    var resp = await req(
      self,
      'PROPFIND',
      path,
      data: dataStr,
      optionsHandler: (options) {
        options.headers?['depth'] = depth.value;
        options.headers?['content-type'] = 'application/xml;charset=UTF-8';
        options.headers?['accept'] = 'application/xml,text/xml';
        options.headers?['accept-charset'] = 'utf-8';
        options.headers?['accept-encoding'] = '';
      },
      cancelToken: cancelToken,
    );

    if (resp.statusCode != 207) {
      throw _newResponseError(resp);
    }

    return resp;
  }

  /// MKCOL
  Future<Response<void>> wdMkcol(WebdavClient self, String path,
      {CancelToken? cancelToken}) {
    return req(self, 'MKCOL', path, cancelToken: cancelToken);
  }

  /// DELETE
  Future<Response<void>> wdDelete(WebdavClient self, String path,
      {CancelToken? cancelToken}) {
    return req(self, 'DELETE', path, cancelToken: cancelToken);
  }

  /// COPY OR MOVE
  Future<void> wdCopyMove(WebdavClient self, String oldPath, String newPath,
      bool isCopy, bool overwrite,
      {CancelToken? cancelToken}) async {
    final method = isCopy == true ? 'COPY' : 'MOVE';
    final resp = await req(self, method, oldPath, optionsHandler: (options) {
      options.headers?['destination'] = Uri.encodeFull(joinPath(self.url, newPath));
      options.headers?['overwrite'] = overwrite == true ? 'T' : 'F';
    }, cancelToken: cancelToken);

    final status = resp.statusCode;
    if (status == 201 || status == 204) {
      return;
    } else if (status == 207) {
      // Handle Multi-Status response (207)
      // Parse the XML response to determine if any critical operations failed
      final responseData = resp.data.toString();
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
      if (resp.statusCode != null &&
          resp.statusCode! >= 300 &&
          resp.statusCode! < 400) {
        final locationHeaders = resp.headers['location'];
        if (locationHeaders != null && locationHeaders.isNotEmpty) {
          final ret = await req(
            self,
            'GET',
            locationHeaders.first,
            optionsHandler: (options) =>
                options.responseType = ResponseType.bytes,
            onReceiveProgress: onProgress,
            cancelToken: cancelToken,
          );
          return ret.data as List<int>;
        }

        throw DioException(
          requestOptions: resp.requestOptions,
          response: resp,
          type: DioExceptionType.badResponse,
          error: 'No location header found',
        );
      }
      throw _newResponseError(resp);
    }
    return resp.data as List<int>;
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
      final ret = await req(
        self,
        'GET',
        path,
        optionsHandler: (options) => options.responseType = ResponseType.stream,
        // onReceiveProgress: onProgress,
        cancelToken: cancelToken,
      );
      resp = ret as Response<ResponseBody>;
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
    final stream = resp.data!.stream as Stream<List<int>>;
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
    Future closeAndDelete() async {
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
        asyncWrite = raf.writeFrom(data).then((raf) {
          // Notify progress
          received += data.length;

          onProgress?.call(received, total);

          raf = raf;
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
          await closeAndDelete();
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
      await closeAndDelete();
    });

    if (resp.requestOptions.receiveTimeout != null &&
        resp.requestOptions.receiveTimeout!
                .compareTo(const Duration(milliseconds: 0)) >
            0) {
      future = future
          .timeout(resp.requestOptions.receiveTimeout!)
          .catchError((Object err) async {
        await subscription.cancel();
        await closeAndDelete();
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
    Map<String, dynamic>? additionalHeaders,
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
      optionsHandler: (options) {
        options.headers?['content-length'] = data.length;

        if (additionalHeaders != null) {
          options.headers?.addAll(additionalHeaders);
        }
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

  Future<Response> wdLock(
    WebdavClient self,
    String path,
    String dataStr, {
    int timeout = 3600,
    ReadPropsDepth depth = ReadPropsDepth.infinity,
    CancelToken? cancelToken,
  }) async {
    var resp = await req(
      self,
      'LOCK',
      path,
      data: dataStr,
      optionsHandler: (options) {
        options.headers?['content-type'] = 'application/xml;charset=UTF-8';
        options.headers?['Timeout'] = 'Second-$timeout';
        options.headers?['Depth'] = depth.value;

        options.responseType = ResponseType.plain;
      },
      cancelToken: cancelToken,
    );

    final status = resp.statusCode;
    if (status != 200 && status != 201) {
      throw _newResponseError(resp);
    }

    return resp;
  }

  Future<Response<void>> wdUnlock(
    WebdavClient self,
    String path,
    String lockToken, {
    CancelToken? cancelToken,
  }) async {
    var resp = await req(self, 'UNLOCK', path, optionsHandler: (options) {
      options.headers?['Lock-Token'] = '<$lockToken>';
    }, cancelToken: cancelToken);

    var status = resp.statusCode;
    if (status != 204 && status != 200) {
      throw _newResponseError(resp);
    }

    return resp;
  }

  Future<Response> wdProppatch(
    WebdavClient self,
    String path,
    String dataStr, {
    CancelToken? cancelToken,
  }) async {
    var resp = await req(
      self,
      'PROPPATCH',
      path,
      data: dataStr,
      optionsHandler: (options) {
        options.headers?['content-type'] = 'application/xml;charset=UTF-8';
        options.headers?['accept'] = 'application/xml,text/xml';
      },
      cancelToken: cancelToken,
    );

    if (resp.statusCode != 207) {
      throw _newResponseError(resp);
    }

    return resp;
  }
}
