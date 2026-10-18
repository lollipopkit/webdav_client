part of '../client.dart';

extension WebdavClientRm on WebdavClient {
  /// Remove a folder or file
  /// If you remove the folder, some webdav services require a '/' at the end of the path.
  ///
  /// - [path] of the resource
  /// - [cancelToken] for cancelling the request
  /// - [ifHeader] supplies preconditions such as lock tokens via an HTTP If header
  Future<void> remove(
    String path, {
    CancelToken? cancelToken,
    String? ifHeader,
    Map<String, dynamic>? headers,
  }) {
    return removeAll(
      path,
      cancelToken: cancelToken,
      ifHeader: ifHeader,
      headers: headers,
    );
  }

  /// Remove files
  ///
  /// - [path] of the resource
  /// - [cancelToken] for cancelling the request
  /// - [ifHeader] supplies preconditions such as lock tokens via an HTTP If header
  Future<void> removeAll(
    String path, {
    CancelToken? cancelToken,
    String? ifHeader,
    Map<String, dynamic>? headers,
  }) async {
    final resp = await _client.wdDelete(
      path,
      cancelToken: cancelToken,
      ifHeader: ifHeader,
      headers: headers,
    );
    final status = resp.statusCode ?? -1;
    if (status == 200 || status == 202 || status == 204 || status == 404) {
      return;
    }
    if (status == 207) {
      final failures = _parseXmlBody(
        resp,
        'DELETE Multi-Status',
        parseMultiStatusFailureMessages,
      );
      throw WebdavException(
        // RFC 4918 §8.7 requires Multi-Status to describe at least one member.
        message: failures.isEmpty
            ? 'DELETE reported Multi-Status but no member failures'
            : failures.join('; '),
        statusCode: status,
        statusMessage: resp.statusMessage,
        response: resp,
      );
    }
    throw _newResponseError(resp);
  }
}
