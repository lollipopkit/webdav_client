part of 'client.dart';

final _httpPrefixReg = RegExp(r'(http|https)://');

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
  /// - Resolves relative [path] entries against [client.url].
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
    // Credentials are only attached when the resolved target shares the
    // configured base origin; a raw absolute target pointing at a different
    // authority must not receive the client's Authorization header.
    final baseUri = Uri.tryParse(client.url);
    final sameOrigin =
        baseUri != null && uri.hasAuthority && _sameOrigin(baseUri, uri);
    if (sameOrigin) {
      final requestTarget = _requestTarget(uri);
      final authStr = client.auth.authorize(method, requestTarget);
      if (authStr != null) {
        options.headers?['authorization'] = authStr;
      }
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
        switch (client.auth) {
          case final DigestAuth digestAuth:
            // Find the digest challenge header
            final digestHeader = w3AHeaders.firstWhereOrNull(
              (header) => header.toLowerCase().contains('digest'),
            );
            if (digestHeader != null) {
              if (authRetryCount >= 1) {
                throw WebdavException(
                  message: 'Digest authentication failed after retry',
                  statusCode: 401,
                  statusMessage: resp.statusMessage,
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
                  statusMessage: resp.statusMessage,
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
                statusMessage: resp.statusMessage,
                response: resp,
              );
            } else {
              // Server does not support Basic auth
              final authType = _extractAuthType(w3AHeaders.first);
              throw WebdavException(
                message: 'Basic Auth failed, server requires $authType auth',
                statusCode: 401,
                statusMessage: resp.statusMessage,
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
                statusMessage: resp.statusMessage,
                response: resp,
              );
            } else {
              final authType = _extractAuthType(w3AHeaders.first);
              throw WebdavException(
                message: 'Bearer Auth failed, server requires $authType auth',
                statusCode: 401,
                statusMessage: resp.statusMessage,
                response: resp,
              );
            }

          case final NoAuth _:
            final authType = _extractAuthType(w3AHeaders.first);
            throw WebdavException(
              message: 'Auth failed, server requires $authType auth',
              statusCode: 401,
              statusMessage: resp.statusMessage,
              response: resp,
            );
        }
      }

      throw WebdavException.fromResponse(resp, 'Authentication failed');
    } else if (_isRedirectStatus(resp.statusCode)) {
      final locations = resp.headers['location'];
      if (locations != null && locations.isNotEmpty) {
        if (redirectCount >= 10) {
          throw WebdavException(
            message: 'Too many redirects',
            statusCode: resp.statusCode,
            statusMessage: resp.statusMessage,
            response: resp,
          );
        }
        await _drainResponseData(resp.data);
        final redirectPath = _resolveRedirectLocation(uri, locations.first);
        final redirectUri = Uri.parse(redirectPath);
        if (!_canRedirectTo(
          uri,
          redirectUri,
          resp.statusCode,
          method,
        )) {
          return resp;
        }
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
        final redirectMethod = resp.statusCode == 303 ? 'GET' : method;
        return req(
          redirectMethod,
          redirectPath,
          data: resp.statusCode == 303 ? null : data,
          optionsHandler: optionsHandler,
          onSendProgress: onSendProgress,
          onReceiveProgress: onReceiveProgress,
          cancelToken: cancelToken,
          redirectCount: redirectCount + 1,
          authRetryCount: authRetryCount,
          stripSensitiveRedirectHeaders: !_sameOrigin(uri, redirectUri),
        );
      }
    }

    return resp;
  }

  /// Resolve a Location header against the URI that produced the redirect.
  String _resolveRedirectLocation(Uri sourceUri, String location) {
    final trimmed = location.trim();
    if (trimmed.isEmpty) {
      return sourceUri.toString();
    }
    try {
      final target = Uri.parse(trimmed);
      return sourceUri.resolveUri(target).toString();
    } on FormatException {
      return sourceUri.toString();
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
    headers?.removeWhere((key, _) => _sensitiveRedirectHeaders.contains(
          key.toLowerCase(),
        ));
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
        options.headers ??= <String, dynamic>{};
        final requestHeaders = options.headers!;
        if (headers != null && headers.isNotEmpty) {
          requestHeaders.addAll(headers);
        }
        if (!_hasHeader(requestHeaders, 'depth')) {
          requestHeaders['Depth'] = depth.value;
        }
        if (!requestHeaders.keys.any(
              (key) => key.toLowerCase() == Headers.contentTypeHeader,
            )) {
          requestHeaders['content-type'] = 'application/xml;charset=UTF-8';
        }
        if (!_hasHeader(requestHeaders, Headers.acceptHeader)) {
          requestHeaders['accept'] = 'application/xml,text/xml';
        }
        if (!_hasHeader(requestHeaders, 'accept-charset')) {
          requestHeaders['accept-charset'] = 'utf-8';
        }
        if (!_hasHeader(requestHeaders, 'accept-encoding')) {
          requestHeaders['accept-encoding'] = '';
        }

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
        options.headers ??= <String, dynamic>{};
        if (headers != null && headers.isNotEmpty) {
          options.headers?.addAll(headers);
        }
        if (ifHeader != null && ifHeader.isNotEmpty) {
          options.headers?['If'] = ifHeader;
        }
        final hasEntity = data != null && data.toString().isNotEmpty;
        if (hasEntity &&
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
        if (!_hasHeader(options.headers!, 'depth')) {
          options.headers?['Depth'] = 'infinity'; // RFC 4918 §9.6.1
        }
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
    int parentCreateAttempts = 0,
  }) async {
    final method = isCopy == true ? 'COPY' : 'MOVE';
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
        options.headers?['Overwrite'] = overwrite == true ? 'T' : 'F';
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
    } else if (status == 409) {
      if (parentCreateAttempts >= 1) {
        // A second 409 after parent creation means the conflict is unrelated
        // to a missing destination parent — surface the original response
        // instead of recursing indefinitely.
        throw _newResponseError(resp);
      }
      await _createParent(
        newPath,
        cancelToken: cancelToken,
        ifHeader: ifHeader,
        headers: headers,
      );
      return wdCopyMove(
        oldPath,
        newPath,
        isCopy,
        overwrite,
        cancelToken: cancelToken,
        depth: depth,
        ifHeader: ifHeader,
        headers: headers,
        parentCreateAttempts: parentCreateAttempts + 1,
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

        if (!_hasHeader(requestHeaders, 'timeout')) {
          requestHeaders['Timeout'] =
              _serializeTimeoutHeader(timeout, timeoutPreferences);
        }
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
        if (!_hasHeader(options.headers!, Headers.acceptHeader)) {
          options.headers?['accept'] = 'application/xml,text/xml';
        }

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

/// Return `true` when [headers] contains [name] (case-insensitively).
bool _hasHeader(Map<String, dynamic>? headers, String name) {
  if (headers == null) return false;
  final lower = name.toLowerCase();
  return headers.keys.any((key) => key.toLowerCase() == lower);
}

extension on _WdDio {
  /// Extract the advertised WWW-Authenticate scheme from a challenge header.
  String? _extractAuthType(String authHeader) {
    final parts = authHeader.split(' ');
    if (parts.isNotEmpty) {
      final authType = parts[0].replaceAll(',', '');
      return authType.isNotEmpty ? authType : null;
    }
    return null;
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
