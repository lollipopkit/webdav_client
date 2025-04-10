part of 'client.dart';

final _httpPrefixReg = RegExp(r'(http|https)://');

class _WdDio with DioMixin {
  final WebdavClient client;

  _WdDio({required this.client, BaseOptions? options}) {
    this.options = options ?? BaseOptions();
    this.options.followRedirects = false;

    this.options.validateStatus = (status) => true;

    httpClientAdapter = getAdapter();
  }

  Future<Response<T>> req<T>(
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

    if (optionsHandler != null) {
      optionsHandler(options);
    }

    // authorization
    final authStr = client.auth.authorize(method, path);
    if (authStr != null) {
      options.headers?['authorization'] = authStr;
    }

    final uri = Uri.parse(
        path.startsWith(_httpPrefixReg) ? path : joinPath(client.url, path));
    final resp = await requestUri<T>(
      uri,
      options: options,
      data: data,
      onSendProgress: onSendProgress,
      onReceiveProgress: onReceiveProgress,
      cancelToken: cancelToken,
    );

    if (resp.statusCode == 401) {
      final w3AHeaders = resp.headers[Headers.wwwAuthenticateHeader];

      if (w3AHeaders != null && w3AHeaders.isNotEmpty) {
        switch (client.auth) {
          case final DigestAuth digestAuth:
            // Find the digest challenge header
            final digestHeader = w3AHeaders.firstWhereOrNull(
              (header) => header.toLowerCase().contains('digest'),
            );
            if (digestHeader != null) {
              // Create a new DigestAuth instance with the new challenge
              client.auth = DigestAuth(
                user: digestAuth.user,
                pwd: digestAuth.pwd,
                digestParts: DigestParts(digestHeader),
              );

              // Retry the request
              return req(
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
            // Check if the server supports Basic auth
            final basicHeader = w3AHeaders.firstWhereOrNull(
              (header) => header.toLowerCase().contains('basic'),
            );
            if (basicHeader != null) {
              throw WebdavException(
                message:
                    'Basic Auth failed, maybe invalid username or password',
                statusCode: 401,
                response: resp,
              );
            } else {
              // Server does not support Basic auth
              final authType = _extractAuthType(w3AHeaders.first);
              throw WebdavException(
                message: 'Basic Auth failed, server requires $authType auth',
                statusCode: 401,
                response: resp,
              );
            }

          case final BearerAuth _:
            final bearerHeader = w3AHeaders.firstWhereOrNull(
              (header) => header.toLowerCase().contains('bearer'),
            );
            if (bearerHeader != null) {
              throw WebdavException(
                message: 'Bearer Auth failed, maybe invalid or expired token',
                statusCode: 401,
                response: resp,
              );
            } else {
              final authType = _extractAuthType(w3AHeaders.first);
              throw WebdavException(
                message: 'Bearer Auth failed, server requires $authType auth',
                statusCode: 401,
                response: resp,
              );
            }

          case final NoAuth _:
            final authType = _extractAuthType(w3AHeaders.first);
            throw WebdavException(
              message: 'Auth failed, server requires $authType auth',
              statusCode: 401,
              response: resp,
            );
        }
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
    String path, {
    CancelToken? cancelToken,
  }) {
    return req(
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
  Future<Response<String>> wdPropfind(
    String path,
    PropsDepth depth,
    String dataStr, {
    CancelToken? cancelToken,
  }) async {
    final resp = await req<String>(
      'PROPFIND',
      path,
      data: dataStr,
      optionsHandler: (options) {
        options.headers?['depth'] = depth.value;
        options.headers?['content-type'] = 'application/xml;charset=UTF-8';
        options.headers?['accept'] = 'application/xml,text/xml';
        options.headers?['accept-charset'] = 'utf-8';
        options.headers?['accept-encoding'] = '';

        options.responseType = ResponseType.plain;
      },
      cancelToken: cancelToken,
    );

    if (resp.statusCode != 207) {
      throw _newResponseError(resp);
    }

    return resp;
  }

  /// MKCOL
  Future<Response<void>> wdMkcol(String path, {CancelToken? cancelToken}) {
    return req('MKCOL', path, cancelToken: cancelToken);
  }

  /// DELETE
  Future<Response<void>> wdDelete(String path, {CancelToken? cancelToken}) {
    return req('DELETE', path, cancelToken: cancelToken);
  }

  /// COPY OR MOVE
  Future<void> wdCopyMove(
    String oldPath,
    String newPath,
    bool isCopy,
    bool overwrite, {
    CancelToken? cancelToken,
    PropsDepth depth = PropsDepth.infinity,
  }) async {
    final method = isCopy == true ? 'COPY' : 'MOVE';
    final resp = await req(
      method,
      oldPath,
      optionsHandler: (options) {
        options.headers?['destination'] =
            Uri.encodeFull(joinPath(client.url, newPath));
        options.headers?['overwrite'] = overwrite == true ? 'T' : 'F';
        options.headers?['depth'] = depth.value;
      },
      cancelToken: cancelToken,
    );

    final status = resp.statusCode;
    if (status == 201 || status == 204) {
      return;
    } else if (status == 207) {
      // Handle Multi-Status response (207)
      // Parse the XML response to determine if any critical operations failed
      final responseData = resp.data.toString();
      if (responseData.contains('<status>HTTP/1.1 5')) {
        // If response contains any 5xx errors, consider it a failure
        throw WebdavException(
          message: 'Multi-Status operation partially failed: $responseData',
          statusCode: resp.statusCode,
          statusMessage: resp.statusMessage,
          response: resp,
        );
      }
      // Otherwise, operation was successful enough to proceed
      return;
    } else if (status == 409) {
      await _createParent(newPath, cancelToken: cancelToken);
      return wdCopyMove(oldPath, newPath, isCopy, overwrite,
          cancelToken: cancelToken);
    } else {
      throw _newResponseError(resp);
    }
  }

  /// read a file with bytes
  Future<Uint8List> wdReadWithBytes(
    String path, {
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    // fix auth error
    var pResp = await wdOptions(path, cancelToken: cancelToken);
    if (pResp.statusCode != 200) {
      throw _newResponseError(pResp);
    }

    final resp = await req(
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
            'GET',
            locationHeaders.first,
            optionsHandler: (options) =>
                options.responseType = ResponseType.bytes,
            onReceiveProgress: onProgress,
            cancelToken: cancelToken,
          );
          return ret.data as Uint8List;
        }

        throw WebdavException(
          message: 'No location header found',
          statusCode: resp.statusCode,
          statusMessage: resp.statusMessage,
          response: resp,
        );
      }
      throw _newResponseError(resp);
    }
    return resp.data as Uint8List;
  }

  /// read a file with stream
  Future<void> wdReadWithStream(
    String path,
    String savePath, {
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    // Check if the file exists
    final pResp = await wdOptions(path, cancelToken: cancelToken);
    if (pResp.statusCode != 200) {
      throw _newResponseError(pResp);
    }

    final Response<ResponseBody> resp;

    // Reference Dio download
    // request
    try {
      resp = await req<ResponseBody>(
        'GET',
        path,
        optionsHandler: (options) => options.responseType = ResponseType.stream,
        // onReceiveProgress: onProgress,
        cancelToken: cancelToken,
      );
    } on WebdavException catch (e) {
      if (e.response!.requestOptions.receiveDataWhenStatusError == true) {
        final res = await transformer.transformResponse(
          e.response!.requestOptions..responseType = ResponseType.json,
          e.response!.data as ResponseBody,
        );
        e.response!.data = res;
      } else {
        e.response!.data = null;
      }
      rethrow;
    }
    if (resp.statusCode != 200) {
      throw _newResponseError(resp);
    }

    final respData = resp.data;
    if (respData == null) {
      throw _newResponseError(resp, 'Response data is null');
    }

    resp.headers = Headers.fromMap(respData.headers);

    // If directory (or file) doesn't exist yet, the entire method fails
    final file = File(savePath);
    await file.create(recursive: true);

    final fileReader = await file.open(mode: FileMode.write);

    //Create a Completer to notify the success/error state.
    final completer = Completer<Response<ResponseBody>>();
    var future = completer.future;
    var received = 0;

    // Stream<Uint8List>
    final stream = respData.stream;
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

    late StreamSubscription<Uint8List> subscription;
    Future<Null>? asyncWrite;
    var closed = false;

    Future<void> closeAndDelete() async {
      if (!closed) {
        closed = true;
        await asyncWrite;
        await fileReader.close();
        await file.delete();
      }
    }

    subscription = stream.listen(
      (data) {
        subscription.pause();
        // Write file asynchronously
        asyncWrite = fileReader.writeFrom(data).then((raf) {
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
            completer.completeError(WebdavException(
              message: err.toString(),
              statusCode: resp.statusCode,
              statusMessage: resp.statusMessage,
              response: resp,
            ));
          }
        });
      },
      onDone: () async {
        try {
          await asyncWrite;
          closed = true;
          await fileReader.close();
          completer.complete(resp);
        } catch (err) {
          completer.completeError(WebdavException(
            message: err.toString(),
            statusCode: resp.statusCode,
            statusMessage: resp.statusMessage,
            response: resp,
          ));
        }
      },
      onError: (e) async {
        try {
          await closeAndDelete();
        } finally {
          completer.completeError(WebdavException(
            message: e.toString(),
            statusCode: resp.statusCode,
            statusMessage: resp.statusMessage,
            response: resp,
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

    final recvTimeout = resp.requestOptions.receiveTimeout;
    const zeroDuration = Duration(milliseconds: 0);
    if (recvTimeout != null && recvTimeout.compareTo(zeroDuration) > 0) {
      future = future
          .timeout(resp.requestOptions.receiveTimeout!)
          .catchError((Object err) async {
        await subscription.cancel();
        await closeAndDelete();
        if (err is TimeoutException) {
          throw WebdavException(
            message: 'Receiving data timeout $recvTimeout ms',
            statusCode: resp.statusCode,
            statusMessage: resp.statusMessage,
            response: resp,
          );
        }
        throw err;
      });
    }
    // ignore: invalid_use_of_internal_member
    await DioMixin.listenCancelForAsyncTask(cancelToken, future);
  }

  /// write a file with bytes
  Future<void> wdWriteWithBytes(
    String path,
    Uint8List data, {
    Map<String, dynamic>? additionalHeaders,
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final pResp = await wdOptions(path, cancelToken: cancelToken);
    if (pResp.statusCode != 200) {
      throw _newResponseError(pResp);
    }

    // mkdir
    await _createParent(path, cancelToken: cancelToken);

    final resp = await req(
      'PUT',
      path,
      data: data,
      optionsHandler: (options) {
        options.headers?['content-length'] = data.length;

        if (additionalHeaders != null) {
          options.headers?.addAll(additionalHeaders);
        }
      },
      onSendProgress: onProgress,
      cancelToken: cancelToken,
    );

    final status = resp.statusCode;
    if (status == 200 || status == 201 || status == 204) {
      return;
    }
    throw _newResponseError(resp);
  }

  /// write a file with stream
  Future<void> wdWriteWithStream(
    String path,
    Stream<List<int>> data,
    int length, {
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    // fix auth error
    final pResp = await wdOptions(path, cancelToken: cancelToken);
    if (pResp.statusCode != 200) {
      throw _newResponseError(pResp);
    }

    // mkdir
    await _createParent(path, cancelToken: cancelToken);

    final resp = await req(
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
    final status = resp.statusCode;
    if (status == 200 || status == 201 || status == 204) {
      return;
    }
    throw _newResponseError(resp);
  }

  Future<Response<String>> wdLock(
    String path,
    String? dataStr, {
    int timeout = 3600,
    PropsDepth depth = PropsDepth.infinity,
    String? ifHeader,
    CancelToken? cancelToken,
  }) async {
    final resp = await req<String>(
      'LOCK',
      path,
      data: dataStr,
      optionsHandler: (options) {
        options.headers?['content-type'] = 'application/xml;charset=UTF-8';
        options.headers?['Timeout'] = 'Second-$timeout';
        options.headers?['Depth'] = depth.value;

        if (ifHeader != null) {
          options.headers?['If'] = ifHeader;
        }

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
    String path,
    String lockToken, {
    CancelToken? cancelToken,
  }) async {
    final resp = await req('UNLOCK', path, optionsHandler: (options) {
      options.headers?['Lock-Token'] = '<$lockToken>';
    }, cancelToken: cancelToken);

    final status = resp.statusCode;
    if (status != 204 && status != 200) {
      throw _newResponseError(resp);
    }

    return resp;
  }

  Future<Response<String>> wdProppatch(
    String path,
    String dataStr, {
    CancelToken? cancelToken,
  }) async {
    final resp = await req<String>(
      'PROPPATCH',
      path,
      data: dataStr,
      optionsHandler: (options) {
        options.headers?['content-type'] = 'application/xml;charset=UTF-8';
        options.headers?['accept'] = 'application/xml,text/xml';

        options.responseType = ResponseType.plain;
      },
      cancelToken: cancelToken,
    );

    if (resp.statusCode != 207) {
      throw _newResponseError(resp);
    }

    return resp;
  }
}

extension on _WdDio {
  /// Used in [req].
  String? _extractAuthType(String authHeader) {
    final parts = authHeader.split(' ');
    if (parts.isNotEmpty) {
      final authType = parts[0].replaceAll(',', '');
      return authType.isNotEmpty ? authType : null;
    }
    return null;
  }

  /// create parent folder
  Future<void>? _createParent(String path, {CancelToken? cancelToken}) {
    final parentPath = path.substring(0, path.lastIndexOf('/') + 1);

    if (parentPath == '' || parentPath == '/') {
      return null;
    }
    return client.mkdirAll(parentPath, cancelToken: cancelToken);
  }
}
