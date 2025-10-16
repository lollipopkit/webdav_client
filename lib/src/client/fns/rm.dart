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
  }) {
    return removeAll(
      path,
      cancelToken: cancelToken,
      ifHeader: ifHeader,
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
  }) async {
    final resp = await _client.wdDelete(
      path,
      cancelToken: cancelToken,
      ifHeader: ifHeader,
    );
    final status = resp.statusCode ?? -1;
    if (status == 200 || status == 202 || status == 204 || status == 404) {
      return;
    }
    if (status == 207) {
      final body = resp.data;
      if (body is! String || body.isEmpty) {
        throw WebdavException(
          message:
              'DELETE returned 207 Multi-Status without an XML response body to inspect',
          statusCode: status,
          statusMessage: resp.statusMessage,
          response: resp,
        );
      }
      try {
        final failures = parseMultiStatusFailureMessages(body);
        if (failures.isEmpty) {
          // RFC 4918 §8.7 requires Multi-Status to describe at least one member.
          throw WebdavException(
            message: 'DELETE reported Multi-Status but no member failures',
            statusCode: status,
            statusMessage: resp.statusMessage,
            response: resp,
          );
        }
        throw WebdavException(
          message: failures.join('; '),
          statusCode: status,
          statusMessage: resp.statusMessage,
          response: resp,
        );
      } on XmlException catch (error) {
        throw WebdavException(
          message: 'Unable to parse DELETE Multi-Status response: $error',
          statusCode: status,
          statusMessage: resp.statusMessage,
          response: resp,
        );
      }
    }
    throw _newResponseError(resp);
  }
}
