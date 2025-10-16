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
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) {
    return _client.wdWriteWithBytes(
      path,
      data,
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
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    var file = io.File(localPath);
    return _client.wdWriteWithStream(
      remotePath,
      file.openRead(),
      file.lengthSync(),
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }
}
