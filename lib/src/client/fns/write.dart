part of '../client.dart';

extension WebdavClientWrite on WebdavClient {
  /// Write the bytes to remote path
  ///
  /// - [path] of the file
  /// - [data] to write
  /// - [onProgress] callback for progress
  /// - [cancelToken] for cancelling the request
  Future<void> write(
    String path,
    Uint8List data, {
    Map<String, dynamic>? headers,
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) {
    return _client.wdWriteWithBytes(
      path,
      data,
      additionalHeaders: headers,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  /// Write a caller-provided byte stream to a remote file.
  ///
  /// - [path] of the remote file
  /// - [data] stream of bytes to upload
  /// - [length] known content length for the PUT request
  /// - [headers] optional additional PUT headers such as Content-Type or If-Match
  /// - [onProgress] callback for progress
  /// - [cancelToken] for cancelling the request
  Future<void> writeStream(
    String path,
    Stream<List<int>> data,
    int length, {
    Map<String, dynamic>? headers,
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) {
    return _client.wdWriteWithStream(
      path,
      data,
      length,
      additionalHeaders: headers,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  /// Read local file stream and write to remote file
  ///
  /// - [localPath] of the local file
  /// - [remotePath] of the remote file
  /// - [onProgress] callback for progress
  /// - [cancelToken] for cancelling the request
  Future<void> writeFile(
    String localPath,
    String remotePath, {
    Map<String, dynamic>? headers,
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final file = io.File(localPath);
    return writeStream(
      remotePath,
      file.openRead(),
      file.lengthSync(),
      headers: headers,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }
}
