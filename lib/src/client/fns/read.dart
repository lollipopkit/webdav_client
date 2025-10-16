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
    Map<String, String> namespaces = const <String, String>{},
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
}
