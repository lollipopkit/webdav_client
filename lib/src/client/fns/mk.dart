part of '../client.dart';

extension WebdavClientMk on WebdavClient {
  /// Create a folder
  ///
  /// - [path] of the folder
  /// - [cancelToken] for cancelling the request
  /// - [ifHeader] supplies preconditions such as lock tokens via an HTTP If header
  Future<void> mkdir(
    String path, {
    CancelToken? cancelToken,
    String? ifHeader,
  }) async {
    path = _fixCollectionPath(path);
    final resp = await _client.wdMkcol(
      path,
      cancelToken: cancelToken,
      ifHeader: ifHeader,
    );
    var status = resp.statusCode;
    if (status != 201 && status != 405) {
      throw _newResponseError(resp);
    }
  }

  /// Recursively create folders
  ///
  /// - [path] of the folder
  /// - [cancelToken] for cancelling the request
  /// - [ifHeader] supplies preconditions such as lock tokens via an HTTP If header
  Future<void> mkdirAll(
    String path, {
    CancelToken? cancelToken,
    String? ifHeader,
  }) async {
    path = _fixCollectionPath(path);
    final resp = await _client.wdMkcol(
      path,
      cancelToken: cancelToken,
      ifHeader: ifHeader,
    );
    final status = resp.statusCode;
    if (status == 201 || status == 405) {
      return;
    }
    if (status == 409) {
      final paths = path.split('/');
      var sub = '/';
      for (var e in paths) {
        if (e == '') {
          continue;
        }
        sub += '$e/';
        final resp = await _client.wdMkcol(
          sub,
          cancelToken: cancelToken,
          ifHeader: ifHeader,
        );
        final status = resp.statusCode;
        if (status != 201 && status != 405) {
          throw _newResponseError(resp);
        }
      }
      return;
    }
    throw _newResponseError(resp);
  }
}
