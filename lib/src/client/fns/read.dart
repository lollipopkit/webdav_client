part of '../client.dart';

extension WebdavClientRead on WebdavClient {
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
    Map<String, dynamic>? headers,
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
      headers: headers,
    );

    final str = resp.data;
    if (str == null) {
      throw WebdavException(
        message: 'No data returned',
        statusCode: resp.statusCode,
        statusMessage: resp.statusMessage,
        response: resp,
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
    Map<String, dynamic>? headers,
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
      headers: headers,
    );

    final str = resp.data;
    if (str == null) {
      throw WebdavException(
        message: 'No data returned',
        statusCode: resp.statusCode,
        statusMessage: resp.statusMessage,
        response: resp,
      );
    }

    return WebdavFile.parseFiles(path, str, skipSelf: false).firstOrNull;
  }

  /// Read the bytes of a file
  ///
  /// - [path] of the file
  /// - [onProgress] callback for progress
  /// - [cancelToken] for cancelling the request
  Future<Uint8List> read(
    String path, {
    Map<String, dynamic>? headers,
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) {
    return _client.wdReadWithBytes(
      path,
      headers: headers,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  /// Read a file as a response stream without buffering the body in memory.
  ///
  /// The returned Dio [Response] exposes headers and a [ResponseBody.stream].
  /// Callers are responsible for listening to or cancelling the stream.
  Future<Response<ResponseBody>> readStream(
    String path, {
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final resp = await _client.req<ResponseBody>(
      'GET',
      path,
      optionsHandler: (options) {
        if (headers != null && headers.isNotEmpty) {
          options.headers?.addAll(headers);
        }
        options.responseType = ResponseType.stream;
      },
      cancelToken: cancelToken,
    );

    if (resp.statusCode != 200 && resp.statusCode != 206) {
      // Consume the error body so the connection can be reused instead of
      // leaving the stream subscription hanging.
      await resp.data?.stream.drain<void>();
      throw _newResponseError(resp);
    }
    if (resp.data == null) {
      throw _newResponseError(resp, 'Response data is null');
    }
    return resp;
  }
}
