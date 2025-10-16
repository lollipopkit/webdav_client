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
    final authStr = client.auth.authorize(method, requestTarget);
    if (authStr != null) {
      options.headers?['authorization'] = authStr;
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

  /// Extract the request-target string (`path?query`) used by auth schemes.
  String _requestTarget(Uri uri) {
    final path = uri.path.isEmpty ? '/' : uri.path;
    if (uri.hasQuery) {
      return '$path?${uri.query}';
    }
    return path;
  }

  // OPTIONS
  /// Perform an OPTIONS request, preserving non-2xx statuses unless
  /// `allowNotFound` is supplied for discovery flows (RFC 4918 §7.7).
  Future<Response<void>> wdOptions(
    String path, {
    CancelToken? cancelToken,
    bool allowNotFound = false,
  }) async {
    final resp = await req(
      'OPTIONS',
      path,
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

    final status = resp.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw _newResponseError(resp);
    }

    return resp;
  }

  /// MKCOL
  /// Create a new collection per RFC 4918 §9.3, optionally supplying WebDAV
  /// `If` conditions such as lock tokens.
  Future<Response<void>> wdMkcol(
    String path, {
    CancelToken? cancelToken,
    String? ifHeader,
  }) {
    return req(
      'MKCOL',
      path,
      optionsHandler: (options) {
        if (ifHeader != null && ifHeader.isNotEmpty) {
          options.headers?['If'] = ifHeader;
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
  }) {
    return req<String>(
      'DELETE',
      path,
      optionsHandler: (options) {
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
      await _createParent(
        newPath,
        cancelToken: cancelToken,
        ifHeader: ifHeader,
      );
      return wdCopyMove(
        oldPath,
        newPath,
        isCopy,
        overwrite,
        cancelToken: cancelToken,
        depth: depth,
        ifHeader: ifHeader,
      );
    } else {
      throw _newResponseError(resp);
    }
  }

  /// Fetch a resource as in-memory bytes, following redirects when necessary.
  Future<Uint8List> wdReadWithBytes(
    String path, {
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
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
  /// Download a resource to [savePath], tracking progress for large responses.
  Future<void> wdReadWithStream(
    String path,
    String savePath, {
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
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
    await _createParent(path, cancelToken: cancelToken);

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
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    // mkdir
    await _createParent(path, cancelToken: cancelToken);

    final resp = await req(
      'PUT',
      path,
      data: data,
      optionsHandler: (options) {
        final headers = buildPutHeaders(
          contentLength: length,
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
    PropsDepth depth = PropsDepth.infinity,
    String? ifHeader,
    CancelToken? cancelToken,
  }) async {
    final resp = await req<String>(
      'LOCK',
      path,
      data: dataStr,
      optionsHandler: (options) {
        options.headers ??= <String, dynamic>{};
        final headers = options.headers!;

        headers['Timeout'] = 'Second-$timeout';
        if (ifHeader != null) {
          headers['If'] = ifHeader;
        }

        final hasBody = dataStr != null && dataStr.isNotEmpty;
        if (hasBody) {
          headers['Content-Type'] = 'application/xml;charset=UTF-8';
          headers['Depth'] = depth.value;
        } else {
          headers.remove('Content-Type');
          headers.remove('content-type');
          headers.remove('Depth');
          headers.remove('depth');
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

  /// PROPPATCH per RFC 4918 §9.2, returning the raw 207 response for higher
  /// level parsing before surfacing aggregated errors.
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

    final effectivePath = resolvedUri?.path ?? _serverPathFromTarget(path);
    if (effectivePath.isEmpty) {
      return null;
    }

    final normalizedEffective = effectivePath.isEmpty ? '/' : effectivePath;

    final basePathRaw = baseUri.path.isEmpty ? '/' : baseUri.path;
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
    );
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
