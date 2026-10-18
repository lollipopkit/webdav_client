part of 'client.dart';

final _httpPrefixReg = RegExp('(http|https)://');

/// Thin wrapper around `dio` that injects WebDAV-specific behaviour such as
/// automatic auth retries, base URL resolution and RFC 4918 error translation.
class _WdDio with DioMixin {
  final WebdavClient client;

  /// Configure the underlying dio mixin with sensible defaults (no automatic
  /// redirects, passthrough status validation) while wiring the correct adapter
  /// for the current platform.
  _WdDio({required this.client, BaseOptions? options}) {
    this.options = options ?? BaseOptions();
    this.options.followRedirects = false;

    this.options.validateStatus = (status) => true;

    httpClientAdapter = getAdapter();
  }

  /// Issue an HTTP request using WebDAV-aware defaults.
  ///
  /// - Resolves relative [path] entries against [WebdavClient.url].
  /// - Injects Authorization headers via the configured [Auth] strategy.
  /// - Retries 401 responses once when a Digest challenge is received.
  /// - Preserves the raw [Response] so higher-level helpers can perform
  ///   RFC-specific validation.
  Future<Response<T>> req<T>(
    String method,
    String path, {
    dynamic data,
    Function(Options)? optionsHandler,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
    int redirectCount = 0,
    int authRetryCount = 0,
    bool stripSensitiveRedirectHeaders = false,
  }) async {
    // options
    final options = Options(method: method);
    options.headers ??= {};

    if (optionsHandler != null) {
      optionsHandler(options);
    }

    final headers = options.headers;
    if (headers != null) {
      final hasIfHeader = headers.entries.any(
        (entry) =>
            entry.key.toLowerCase() == 'if' &&
            entry.value != null &&
            entry.value.toString().isNotEmpty,
      );
      if (hasIfHeader) {
        final hasCacheControl = headers.keys.any(
          (key) => key.toLowerCase() == 'cache-control',
        );
        if (!hasCacheControl) {
          headers['Cache-Control'] = 'no-cache';
        }
        final hasPragma = headers.keys.any(
          (key) => key.toLowerCase() == 'pragma',
        );
        if (!hasPragma) {
          headers['Pragma'] = 'no-cache';
        }
      }
    }

    final rawTarget = path.startsWith(_httpPrefixReg)
        ? path
        : resolveAgainstBaseUrl(client.url, path);
    final uri = Uri.parse(rawTarget);

    // authorization
    final requestTarget = _requestTarget(uri);
    final authStr = client.auth.authorize(
      method,
      requestTarget,
      body: _digestBody(data),
    );
    if (authStr != null) {
      options.headers?['authorization'] = authStr;
    }
    if (stripSensitiveRedirectHeaders) {
      _stripSensitiveRedirectHeaders(options.headers);
    }
    final resp = await requestUri<T>(
      uri,
      options: options,
      data: data,
      onSendProgress: onSendProgress,
      onReceiveProgress: onReceiveProgress,
      cancelToken: cancelToken,
    );

    if (resp.statusCode == 401) {
      await _drainResponseData(resp.data);
      final w3AHeaders = resp.headers[Headers.wwwAuthenticateHeader];

      if (w3AHeaders != null && w3AHeaders.isNotEmpty) {
        final challenges = parseAuthChallenges(w3AHeaders);
        final authType = challenges.firstOrNull?.scheme;
        bool offers(String scheme) => challenges.any((c) => c.scheme == scheme);
        switch (client.auth) {
          case final DigestAuth digestAuth:
            final digestHeader = _pickDigestChallenge(challenges);
            if (digestHeader == null && offers('digest')) {
              throw WebdavException(
                message: 'Digest auth failed, no supported algorithm offered',
                statusCode: 401,
                response: resp,
              );
            }
            if (digestHeader != null) {
              if (authRetryCount >= 1) {
                throw WebdavException(
                  message: 'Digest authentication failed after retry',
                  statusCode: 401,
                  response: resp,
                );
              }
              // Create a new DigestAuth instance with the new challenge
              client.auth = DigestAuth(
                user: digestAuth.user,
                pwd: digestAuth.pwd,
                digestParts: DigestParts(digestHeader),
              );

              // Stream bodies cannot be retried.
              if (data is Stream) {
                throw WebdavException(
                  message: 'Cannot retry streamed request after 401; '
                      'use in-memory bytes for PUT requests that may require auth',
                  statusCode: 401,
                  response: resp,
                );
              }
              // Retry the request
              return req(
                method,
                path,
                data: data,
                optionsHandler: optionsHandler,
                onSendProgress: onSendProgress,
                onReceiveProgress: onReceiveProgress,
                cancelToken: cancelToken,
                redirectCount: redirectCount,
                authRetryCount: authRetryCount + 1,
                stripSensitiveRedirectHeaders: stripSensitiveRedirectHeaders,
              );
            }

          case final BasicAuth _:
            // Check if the server supports Basic auth
            if (offers('basic')) {
              throw WebdavException(
                message:
                    'Basic Auth failed, maybe invalid username or password',
                statusCode: 401,
                response: resp,
              );
            } else {
              // Server does not support Basic auth
              throw WebdavException(
                message: 'Basic Auth failed, server requires $authType auth',
                statusCode: 401,
                response: resp,
              );
            }

          case final BearerAuth _:
            if (offers('bearer')) {
              throw WebdavException(
                message: 'Bearer Auth failed, maybe invalid or expired token',
                statusCode: 401,
                response: resp,
              );
            } else {
              throw WebdavException(
                message: 'Bearer Auth failed, server requires $authType auth',
                statusCode: 401,
                response: resp,
              );
            }

          case final NoAuth _:
            throw WebdavException(
              message: 'Auth failed, server requires $authType auth',
              statusCode: 401,
              response: resp,
            );
        }
      }

      throw WebdavException.fromResponse(resp, 'Authentication failed');
    } else if (_isRedirectStatus(resp.statusCode)) {
      final locations = resp.headers['location'];
      if (locations != null && locations.isNotEmpty) {
        if (redirectCount >= 10) {
          await _drainResponseData(resp.data);
          throw WebdavException(
            message: 'Too many redirects',
            statusCode: resp.statusCode,
            statusMessage: resp.statusMessage,
            response: resp,
          );
        }
        final redirectPath = _resolveRedirectLocation(uri, locations.first);
        // An unusable Location is handed back like a missing one.
        if (redirectPath == null) return resp;
        final redirectUri = Uri.parse(redirectPath);
        // A redirect that is not followed keeps its body for the caller.
        if (!_canRedirectTo(
          uri,
          redirectUri,
          resp.statusCode,
          method,
        )) {
          return resp;
        }
        await _drainResponseData(resp.data);
        // 307/308 preserve the request body — streams can't be replayed.
        if (resp.statusCode != 303 && data is Stream) {
          throw WebdavException(
            message: 'Cannot follow redirect with streamed request body; '
                'use in-memory bytes for uploads that may be redirected',
            statusCode: resp.statusCode,
            statusMessage: resp.statusMessage,
            response: resp,
          );
        }
        // RFC 9110 §15.4.4: 303 turns everything but HEAD into a bodyless GET.
        final seeOther = resp.statusCode == 303 && method != 'HEAD';
        return req(
          seeOther ? 'GET' : method,
          redirectPath,
          data: seeOther ? null : data,
          optionsHandler: seeOther
              ? (Options options) {
                  optionsHandler?.call(options);
                  options.headers?.removeWhere(
                    (key, _) => _entityHeaders.contains(key.toLowerCase()),
                  );
                }
              : optionsHandler,
          onSendProgress: onSendProgress,
          onReceiveProgress: onReceiveProgress,
          cancelToken: cancelToken,
          redirectCount: redirectCount + 1,
          authRetryCount: authRetryCount,
          // Once a hop left the origin, later hops must not restore secrets.
          stripSensitiveRedirectHeaders:
              stripSensitiveRedirectHeaders || !_sameOrigin(uri, redirectUri),
        );
      }
      // No Location to follow: hand the response back so callers of the raw
      // `request` escape hatch still see it. High-level verbs turn it into a
      // 'No location header found' error via `_newResponseError`.
    }

    return resp;
  }

  /// Resolve a Location header against the URI that produced the redirect.
  String? _resolveRedirectLocation(Uri sourceUri, String location) {
    final trimmed = location.trim();
    if (trimmed.isEmpty) return null;
    try {
      return sourceUri.resolveUri(Uri.parse(trimmed)).toString();
    } on FormatException {
      return null;
    }
  }

  /// Decide whether an automatic redirect is safe for a WebDAV request.
  bool _canRedirectTo(
    Uri sourceUri,
    Uri targetUri,
    int? statusCode,
    String method,
  ) {
    if (!_isRedirectStatus(statusCode)) {
      return false;
    }
    if (_sameOrigin(sourceUri, targetUri)) {
      return true;
    }
    return client.auth is NoAuth && _isSafeRedirectMethod(method);
  }

  bool _isSafeRedirectMethod(String method) {
    final normalized = method.toUpperCase();
    return normalized == 'GET' || normalized == 'HEAD';
  }

  void _stripSensitiveRedirectHeaders(Map<String, dynamic>? headers) {
    if (headers == null) return;
    headers.removeWhere(
      (key, _) => _sensitiveRedirectHeaders.contains(key.toLowerCase()),
    );
    // Null overrides the client-wide headers that dio merges in later.
    for (final key in _sensitiveRedirectHeaders) {
      headers[key] = null;
    }
  }

  bool _sameOrigin(Uri a, Uri b) {
    final schemeA = a.scheme.toLowerCase();
    final schemeB = b.scheme.toLowerCase();
    if (schemeA != schemeB) {
      return false;
    }
    if (a.host.toLowerCase() != b.host.toLowerCase()) {
      return false;
    }
    int defaultPort(String scheme) {
      switch (scheme) {
        case 'https':
          return 443;
        case 'http':
          return 80;
        default:
          return 0;
      }
    }

    final portA = a.hasPort ? a.port : defaultPort(schemeA);
    final portB = b.hasPort ? b.port : defaultPort(schemeB);
    return portA == portB;
  }

  /// Read an unsuccessful streamed response into a [WebdavException], so the
  /// connection is released and the error carries the body text.
  Future<WebdavException<String>> _streamResponseError(
    Response<ResponseBody> resp,
  ) async {
    final body = resp.data;
    final text = body == null
        ? null
        : await utf8.decoder
            .bind(body.stream)
            .join()
            .catchError((Object _) => '');
    return _newResponseError(
      Response<String>(
        data: text,
        requestOptions: resp.requestOptions,
        statusCode: resp.statusCode,
        statusMessage: resp.statusMessage,
        headers: resp.headers,
        redirects: resp.redirects,
        extra: resp.extra,
      ),
    );
  }

  /// Drain stream response bodies before retrying so connections can be reused.
  Future<void> _drainResponseData(Object? data) async {
    if (data is ResponseBody) {
      await data.stream.drain<void>();
    }
  }

  /// Return true for redirect statuses commonly emitted by WebDAV frontends.
  bool _isRedirectStatus(int? statusCode) {
    return statusCode == 301 ||
        statusCode == 302 ||
        statusCode == 303 ||
        statusCode == 307 ||
        statusCode == 308;
  }

  /// Extract the request-target string (`path?query`) used by auth schemes.
  String _requestTarget(Uri uri) {
    final path = uri.path.isEmpty ? '/' : uri.path;
    if (uri.hasQuery) {
      return '$path?${uri.query}';
    }
    return path;
  }

  String _serializeTimeoutHeader(
    int timeoutSeconds,
    List<LockTimeout> preferences,
  ) {
    if (preferences.isNotEmpty) {
      return preferences
          .map((pref) => pref.headerValue)
          .where((value) => value.isNotEmpty)
          .join(', ');
    }
    if (timeoutSeconds <= 0) {
      return 'Infinite';
    }
    return 'Second-$timeoutSeconds';
  }

  // OPTIONS
  /// Perform an OPTIONS request, preserving non-2xx statuses unless
  /// `allowNotFound` is supplied for discovery flows (RFC 4918 §7.7).
  Future<Response<void>> wdOptions(
    String path, {
    CancelToken? cancelToken,
    bool allowNotFound = false,
    Map<String, dynamic>? headers,
  }) async {
    final resp = await req(
      'OPTIONS',
      path,
      optionsHandler: (options) {
        if (headers != null && headers.isNotEmpty) {
          options.headers?.addAll(headers);
        }
      },
      cancelToken: cancelToken,
    );

    final status = resp.statusCode ?? -1;
    final success = status >= 200 && status < 300;

    if (success || (allowNotFound && status == 404)) {
      return resp;
    }

    throw _newResponseError(resp);
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
  /// PROPFIND per RFC 4918 §9.1 returning the raw XML body for parsing.
  Future<Response<String>> wdPropfind(
    String path,
    PropsDepth depth,
    String dataStr, {
    CancelToken? cancelToken,
    Map<String, dynamic>? headers,
  }) async {
    final resp = await req<String>(
      'PROPFIND',
      path,
      data: dataStr,
      optionsHandler: (options) {
        if (headers != null && headers.isNotEmpty) {
          options.headers?.addAll(headers);
        }
        options.headers?['depth'] = depth.value;
        if (!(options.headers?.keys.any(
              (key) => key.toLowerCase() == Headers.contentTypeHeader,
            ) ??
            false)) {
          options.headers?['content-type'] = 'application/xml;charset=UTF-8';
        }
        options.headers?['accept'] = 'application/xml,text/xml';
        options.headers?['accept-charset'] = 'utf-8';
        options.headers?['accept-encoding'] = '';

        options.responseType = ResponseType.plain;
      },
      cancelToken: cancelToken,
    );

    final status = resp.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw _newResponseError(resp);
    }

    return resp;
  }

  /// MKCOL
  /// Create a new collection per RFC 4918 §9.3, optionally supplying WebDAV
  /// `If` conditions such as lock tokens.
  ///
  /// Per RFC 4918 §9.3.1, MKCOL can accept an XML request body to set
  /// initial properties on the newly created collection.
  Future<Response<void>> wdMkcol(
    String path, {
    dynamic data,
    CancelToken? cancelToken,
    String? ifHeader,
    Map<String, dynamic>? headers,
  }) {
    return req(
      'MKCOL',
      path,
      data: data,
      optionsHandler: (options) {
        if (headers != null && headers.isNotEmpty) {
          options.headers?.addAll(headers);
        }
        if (ifHeader != null && ifHeader.isNotEmpty) {
          options.headers?['If'] = ifHeader;
        }
        if (data != null &&
            !(options.headers?.keys.any(
                  (key) => key.toLowerCase() == Headers.contentTypeHeader,
                ) ??
                false)) {
          options.headers?['Content-Type'] = 'application/xml;charset=UTF-8';
        }
      },
      cancelToken: cancelToken,
    );
  }

  /// HEAD
  /// Retrieve resource metadata without a response body, per RFC 4918 §9.4.
  Future<Response<void>> wdHead(
    String path, {
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) {
    return req<void>(
      'HEAD',
      path,
      optionsHandler: (options) {
        if (headers != null && headers.isNotEmpty) {
          options.headers?.addAll(headers);
        }
      },
      cancelToken: cancelToken,
    );
  }

  /// DELETE
  /// Remove resources as defined in RFC 4918 §9.6, returning raw 207 bodies so
  /// callers can inspect member failures.
  Future<Response<String>> wdDelete(
    String path, {
    CancelToken? cancelToken,
    String? ifHeader,
    Map<String, dynamic>? headers,
  }) {
    return req<String>(
      'DELETE',
      path,
      optionsHandler: (options) {
        options.headers ??= <String, dynamic>{};
        if (headers != null && headers.isNotEmpty) {
          options.headers?.addAll(headers);
        }
        options.headers?['Depth'] = 'infinity'; // RFC 4918 §9.6.1
        if (ifHeader != null && ifHeader.isNotEmpty) {
          options.headers?['If'] = ifHeader;
        }
        options.responseType = ResponseType.plain;
      },
      cancelToken: cancelToken,
    );
  }

  /// COPY or MOVE per RFC 4918 §9.8/§9.9.
  ///
  /// Handles automatic parent creation on 409 responses and inspects 207
  /// Multi-Status bodies to surface child failures inline with SabreDAV.
  Future<void> wdCopyMove(
    String oldPath,
    String newPath,
    bool isCopy,
    bool overwrite, {
    CancelToken? cancelToken,
    PropsDepth depth = PropsDepth.infinity,
    String? ifHeader,
    Map<String, dynamic>? headers,
    bool parentCreated = false,
  }) async {
    final method = isCopy ? 'COPY' : 'MOVE';
    final resp = await req(
      method,
      oldPath,
      optionsHandler: (options) {
        final destinationHeader = resolveAgainstBaseUrl(
          client.url,
          newPath,
        );
        options.headers ??= <String, dynamic>{};
        if (headers != null && headers.isNotEmpty) {
          options.headers?.addAll(headers);
        }
        options.headers?['Destination'] = destinationHeader;
        options.headers?['Overwrite'] = overwrite ? 'T' : 'F';
        options.headers?['Depth'] = depth.value;
        if (ifHeader != null && ifHeader.isNotEmpty) {
          options.headers?['If'] = ifHeader;
        }
        options.responseType = ResponseType.plain;
      },
      cancelToken: cancelToken,
    );

    final status = resp.statusCode ?? -1;
    if (status == 207) {
      final body = resp.data;
      if (body is! String) {
        throw WebdavException(
          message: 'Multi-Status response did not include text body to inspect',
          statusCode: status,
          statusMessage: resp.statusMessage,
          response: resp,
        );
      }
      try {
        final failures = parseMultiStatusFailureMessages(body);
        if (failures.isNotEmpty) {
          throw WebdavException(
            message: failures.join('; '),
            statusCode: status,
            statusMessage: resp.statusMessage,
            response: resp,
          );
        }
      } on XmlException catch (error) {
        throw WebdavException(
          message: 'Unable to parse Multi-Status response: $error',
          statusCode: status,
          statusMessage: resp.statusMessage,
          response: resp,
        );
      }
      return;
    } else if (status >= 200 && status < 300) {
      return;
    } else if (status == 409 && !parentCreated) {
      // The If header and conditions describe the source and destination,
      // not the intermediate collections.
      final createParent = _createParent(
        newPath,
        cancelToken: cancelToken,
        headers: parentMkcolHeaders(headers),
      );
      if (createParent == null) throw _newResponseError(resp);
      await createParent;
      return wdCopyMove(
        oldPath,
        newPath,
        isCopy,
        overwrite,
        cancelToken: cancelToken,
        depth: depth,
        ifHeader: ifHeader,
        headers: headers,
        parentCreated: true,
      );
    } else {
      throw _newResponseError(resp);
    }
  }

  /// Fetch a resource as in-memory bytes, following redirects when necessary.
  Future<Uint8List> wdReadWithBytes(
    String path, {
    Map<String, dynamic>? headers,
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final resp = await req(
      'GET',
      path,
      optionsHandler: (options) {
        if (headers != null && headers.isNotEmpty) {
          options.headers?.addAll(headers);
        }
        options.responseType = ResponseType.bytes;
      },
      onReceiveProgress: onProgress,
      cancelToken: cancelToken,
    );
    if (!_isSuccessfulReadStatus(resp.statusCode)) {
      throw _newResponseError(resp);
    }
    return resp.data as Uint8List;
  }

  /// read a file with stream
  /// Download a resource to [savePath], tracking progress for large responses.
  Future<void> wdReadWithStream(
    String path,
    String savePath, {
    Map<String, dynamic>? headers,
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    // Cancelling is the only way to make dio drop an unread body, so keep a
    // token of our own that follows the caller's.
    final bodyToken = CancelToken();
    cancelToken?.whenCancel.then((e) => bodyToken.cancel(e.error)).ignore();
    final resp = await req<ResponseBody>(
      'GET',
      path,
      optionsHandler: (options) {
        if (headers != null && headers.isNotEmpty) {
          options.headers?.addAll(headers);
        }
        options.responseType = ResponseType.stream;
      },
      cancelToken: bodyToken,
    );
    if (!_isSuccessfulReadStatus(resp.statusCode)) {
      throw await _streamResponseError(resp);
    }

    final respData = resp.data;
    if (respData == null) {
      throw _newResponseError(resp, 'Response data is null');
    }

    resp.headers = Headers.fromMap(respData.headers);

    final file = File(savePath);
    final RandomAccessFile fileReader;
    try {
      await file.create(recursive: true);
      fileReader = await file.open(mode: FileMode.write);
    } catch (_) {
      // Release the connection the unread body would otherwise hold.
      bodyToken.cancel('Local file could not be opened');
      rethrow;
    }

    //Create a Completer to notify the success/error state.
    final completer = Completer<Response<ResponseBody>>();
    final future = completer.future;
    var received = 0;

    // dio already bounds the gap between chunks with receiveTimeout.
    final stream = respData.stream;
    var compressed = false;
    var total = 0;
    final contentEncoding = resp.headers.value(Headers.contentEncodingHeader);
    if (contentEncoding != null) {
      // Any coding but identity changes the length of the decoded stream.
      compressed = contentEncoding
          .split(',')
          .map((coding) => coding.trim().toLowerCase())
          .any((coding) => coding.isNotEmpty && coding != 'identity');
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

    Future<void> closeAndDelete({bool awaitWrite = true}) async {
      if (!closed) {
        closed = true;
        if (awaitWrite) await asyncWrite;
        await fileReader.close();
        try {
          await file.delete();
        } on PathNotFoundException {
          // The caller may have removed the partial download already. This runs
          // from the unawaited `whenCancel` handler, where throwing would
          // surface as an unhandled async error instead of reaching the caller.
        }
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
            // This handler is part of asyncWrite, so it must not await it.
            await closeAndDelete(awaitWrite: false);
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

    // ignore: invalid_use_of_internal_member
    await DioMixin.listenCancelForAsyncTask(cancelToken, future);
  }

  /// write a file with bytes
  /// Ensures the destination parent exists before issuing the PUT so clients
  /// get a single success/failure result rather than partial MKCOL chains.
  Future<void> wdWriteWithBytes(
    String path,
    Uint8List data, {
    Map<String, dynamic>? additionalHeaders,
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    // mkdir
    await _createParent(
      path,
      cancelToken: cancelToken,
      headers: parentMkcolHeaders(additionalHeaders),
    );

    final resp = await req(
      'PUT',
      path,
      data: data,
      optionsHandler: (options) {
        final headers = buildPutHeaders(
          contentLength: data.length,
          additionalHeaders: additionalHeaders,
        );
        options.headers?.addAll(headers);
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
  /// Streamed PUT variant mirroring [wdWriteWithBytes] for large uploads
  /// without loading the entire payload into memory.
  Future<void> wdWriteWithStream(
    String path,
    Stream<List<int>> data,
    int length, {
    Map<String, dynamic>? additionalHeaders,
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    // mkdir
    await _createParent(
      path,
      cancelToken: cancelToken,
      headers: parentMkcolHeaders(additionalHeaders),
    );

    final resp = await req(
      'PUT',
      path,
      data: data,
      optionsHandler: (options) {
        final headers = buildPutHeaders(
          contentLength: length,
          additionalHeaders: additionalHeaders,
        );
        options.headers?.addAll(headers);
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

  /// LOCK per RFC 4918 §9.10, supporting exclusive/shared scopes, timeouts and
  /// conditional refresh via the `If` header.
  Future<Response<String>> wdLock(
    String path,
    String? dataStr, {
    int timeout = 3600,
    List<LockTimeout> timeoutPreferences = const <LockTimeout>[],
    PropsDepth depth = PropsDepth.infinity,
    String? ifHeader,
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final resp = await req<String>(
      'LOCK',
      path,
      data: dataStr,
      optionsHandler: (options) {
        options.headers ??= <String, dynamic>{};
        final requestHeaders = options.headers!;
        if (headers != null && headers.isNotEmpty) {
          requestHeaders.addAll(headers);
        }

        requestHeaders['Timeout'] =
            _serializeTimeoutHeader(timeout, timeoutPreferences);
        if (ifHeader != null) {
          requestHeaders['If'] = ifHeader;
        }

        final hasBody = dataStr != null && dataStr.isNotEmpty;
        if (hasBody) {
          final hasContentType = requestHeaders.keys.any(
            (key) => key.toLowerCase() == Headers.contentTypeHeader,
          );
          if (!hasContentType) {
            requestHeaders['Content-Type'] = 'application/xml;charset=UTF-8';
          }
          requestHeaders['Depth'] = depth.value;
        } else {
          requestHeaders.remove('Content-Type');
          requestHeaders.remove('content-type');
          requestHeaders.remove('Depth');
          requestHeaders.remove('depth');
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

  /// UNLOCK per RFC 4918 §9.11, releasing a previously obtained lock token.
  Future<Response<void>> wdUnlock(
    String path,
    String lockToken, {
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final normalizedToken = client._formatLockTokenHeader(lockToken);
    final resp = await req('UNLOCK', path, optionsHandler: (options) {
      if (headers != null && headers.isNotEmpty) {
        options.headers?.addAll(headers);
      }
      options.headers?['Lock-Token'] = normalizedToken;
      options.headers?.remove('Cache-Control');
      options.headers?.remove('Pragma');
    }, cancelToken: cancelToken);

    final status = resp.statusCode;
    if (status != 204 && status != 200) {
      throw _newResponseError(resp);
    }

    return resp;
  }

  /// PROPPATCH per RFC 4918 §9.2, returning the raw 207 response for higher
  /// level parsing before surfacing aggregated errors.
  Future<Response<String>> wdProppatch(
    String path,
    String dataStr, {
    CancelToken? cancelToken,
    Map<String, dynamic>? headers,
  }) async {
    final resp = await req<String>(
      'PROPPATCH',
      path,
      data: dataStr,
      optionsHandler: (options) {
        if (headers != null && headers.isNotEmpty) {
          options.headers?.addAll(headers);
        }
        if (!(options.headers?.keys.any(
              (key) => key.toLowerCase() == Headers.contentTypeHeader,
            ) ??
            false)) {
          options.headers?['content-type'] = 'application/xml;charset=UTF-8';
        }
        options.headers?['accept'] = 'application/xml,text/xml';

        options.responseType = ResponseType.plain;
      },
      cancelToken: cancelToken,
    );

    final status = resp.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw _newResponseError(resp);
    }

    return resp;
  }
}

/// Compose PUT headers for uploads, merging caller overrides as needed.
Map<String, dynamic> buildPutHeaders({
  required int contentLength,
  Map<String, dynamic>? additionalHeaders,
  bool includeDefaultContentType = true,
}) {
  final headers = <String, dynamic>{
    Headers.contentLengthHeader: contentLength.toString(),
  };

  if (includeDefaultContentType) {
    headers[Headers.contentTypeHeader] = 'application/octet-stream';
  }

  if (additionalHeaders != null && additionalHeaders.isNotEmpty) {
    additionalHeaders.forEach((key, value) {
      final lower = key.toLowerCase();
      if (lower == Headers.contentTypeHeader) {
        headers[Headers.contentTypeHeader] = value;
      } else if (lower == Headers.contentLengthHeader) {
        headers[Headers.contentLengthHeader] = value;
      } else {
        headers[key] = value;
      }
    });
  }

  return headers;
}

/// Return only headers that are safe to reuse for automatic parent MKCOL calls.
///
/// PUT precondition headers describe the target file and must not be evaluated
/// against an intermediate collection created or probed before the PUT.
Map<String, dynamic>? parentMkcolHeaders(Map<String, dynamic>? headers) {
  if (headers == null || headers.isEmpty) {
    return null;
  }

  final filtered = <String, dynamic>{};
  headers.forEach((key, value) {
    if (!_parentMkcolFilteredHeaders.contains(key.toLowerCase())) {
      filtered[key] = value;
    }
  });

  return filtered.isEmpty ? null : filtered;
}

const _putTargetConditionHeaders = <String>{
  'if',
  'if-match',
  'if-none-match',
  'if-modified-since',
  'if-unmodified-since',
  'if-range',
};

const _entityHeaders = <String>{
  'content-length',
  'content-type',
  'content-encoding',
  'content-language',
  'content-range',
  'transfer-encoding',
};

const _parentMkcolFilteredHeaders = <String>{
  ..._putTargetConditionHeaders,
  ..._entityHeaders,
};

const _sensitiveRedirectHeaders = <String>{
  'authorization',
  'cookie',
  'proxy-authorization',
};

bool _isSuccessfulReadStatus(int? statusCode) =>
    statusCode == 200 || statusCode == 206;

extension on _WdDio {
  /// Extract the advertised WWW-Authenticate scheme from a challenge header.
  /// Request body bytes for Digest `auth-int`, which only applies to bodies
  /// held in memory.
  List<int> _digestBody(Object? data) {
    final auth = client.auth;
    if (auth is! DigestAuth || !auth.hashesBody) return const [];
    return switch (data) {
      null => const [],
      final String text => utf8.encode(text),
      final List<int> bytes => bytes,
      _ => throw WebdavException(
          message: 'Digest qop=auth-int needs the request body in memory; '
              'streamed bodies cannot be hashed',
        ),
    };
  }

  /// The parameters of the strongest Digest challenge whose algorithm is
  /// supported (RFC 7616 §3.7), or `null` when none is.
  String? _pickDigestChallenge(List<AuthChallenge> challenges) {
    String? best;
    var bestRank = -1;
    for (final challenge in challenges) {
      if (challenge.scheme != 'digest') continue;
      final rank = DigestAuth.algorithmRank(
        DigestParts(challenge.params).parts['algorithm'],
      );
      if (rank > bestRank) {
        best = challenge.params;
        bestRank = rank;
      }
    }
    return best;
  }

  /// Lazily create intermediate collections for PUT/COPY/MOVE operations.
  ///
  /// Mimics SabreDAV's behaviour by walking up the path, issuing MKCOL as
  /// needed until the target's parent exists, while ensuring we stay within the
  /// original server authority.
  Future<void>? _createParent(
    String path, {
    CancelToken? cancelToken,
    String? ifHeader,
    Map<String, dynamic>? headers,
  }) {
    final baseUri = Uri.parse(client.url);

    Uri? resolvedUri;
    try {
      final resolvedTarget = path.startsWith(_httpPrefixReg)
          ? path
          : resolveAgainstBaseUrl(client.url, path);
      resolvedUri = Uri.parse(resolvedTarget);
    } catch (_) {
      resolvedUri = null;
    }

    if (resolvedUri != null && resolvedUri.hasAuthority) {
      if (_hasAuthority(baseUri) && !_authoritiesMatch(baseUri, resolvedUri)) {
        return null;
      }
      if (!_hasAuthority(baseUri)) {
        return null;
      }
    }

    final effectivePath =
        _encodedPath(resolvedUri) ?? _serverPathFromTarget(path);
    if (effectivePath.isEmpty) {
      return null;
    }

    final normalizedEffective = effectivePath.isEmpty ? '/' : effectivePath;

    final basePathRaw = _encodedPath(baseUri) ?? '/';
    var basePath = basePathRaw;
    if (basePath != '/' && !basePath.endsWith('/')) {
      basePath = '$basePath/';
    }

    if (basePath != '/') {
      final comparisonPath = normalizedEffective.endsWith('/')
          ? normalizedEffective
          : '$normalizedEffective/';
      if (!comparisonPath.startsWith(basePath)) {
        return null;
      }
    }

    final slashIndex = normalizedEffective.lastIndexOf('/');
    if (slashIndex <= 0) {
      return null;
    }
    final parentPath = normalizedEffective.substring(0, slashIndex + 1);
    if (parentPath == '/' || parentPath.isEmpty) {
      return null;
    }
    return client.mkdirAll(
      parentPath,
      cancelToken: cancelToken,
      ifHeader: ifHeader,
      headers: headers,
    );
  }

  /// Return the encoded path, preserving percent-encoded segment semantics.
  String? _encodedPath(Uri? uri) {
    if (uri == null) {
      return null;
    }
    return uri.pathSegments.isEmpty
        ? uri.path
        : '/${uri.pathSegments.map(Uri.encodeComponent).join('/')}';
  }

  /// True when the URI contains authority information (host/port).
  bool _hasAuthority(Uri uri) => uri.host.isNotEmpty || uri.hasAuthority;

  /// Compare two authorities, accounting for implicit default ports.
  bool _authoritiesMatch(Uri a, Uri b) {
    final schemeA = a.scheme.isEmpty ? 'http' : a.scheme;
    final schemeB = b.scheme.isEmpty ? 'http' : b.scheme;
    if (schemeA.toLowerCase() != schemeB.toLowerCase()) {
      return false;
    }
    final hostA = a.host.toLowerCase();
    final hostB = b.host.toLowerCase();
    if (hostA != hostB) {
      return false;
    }
    final portA = a.hasPort ? a.port : _defaultPortForScheme(schemeA);
    final portB = b.hasPort ? b.port : _defaultPortForScheme(schemeB);
    return portA == portB;
  }

  /// Return the conventional port for a scheme when none was provided.
  int _defaultPortForScheme(String scheme) {
    switch (scheme.toLowerCase()) {
      case 'https':
        return 443;
      case 'http':
        return 80;
      default:
        return 0;
    }
  }

  /// Derive the server-relative path from a potentially absolute target.
  String _serverPathFromTarget(String target) {
    final trimmed = target.trim();
    if (trimmed.isEmpty) {
      return '';
    }

    try {
      final uri = Uri.parse(trimmed);
      if (uri.hasScheme && (uri.scheme == 'http' || uri.scheme == 'https')) {
        return uri.path;
      }
      if (!uri.hasScheme) {
        if (uri.path.isNotEmpty) {
          return uri.path;
        }
        if (trimmed.startsWith('/')) {
          return '/';
        }
        return trimmed.split('?').first.split('#').first;
      }
    } catch (_) {
      // Fall through to manual stripping.
    }

    var candidate = trimmed;
    final queryIndex = candidate.indexOf('?');
    if (queryIndex != -1) {
      candidate = candidate.substring(0, queryIndex);
    }
    final fragmentIndex = candidate.indexOf('#');
    if (fragmentIndex != -1) {
      candidate = candidate.substring(0, fragmentIndex);
    }
    return candidate;
  }
}
