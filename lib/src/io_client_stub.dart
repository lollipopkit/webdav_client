import 'package:dio/dio.dart';
import 'package:webdav_client_plus/src/client/client.dart';

/// Stub implementation of local-file helpers for platforms without `dart:io`.
extension WebdavClientIo on WebdavClient {
  /// Not supported on this platform; see the `dart:io` implementation.
  Future<void> readFile(
    String remotePath,
    String localPath, {
    Map<String, dynamic>? headers,
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) {
    throw UnsupportedError(
      'readFile is only supported on platforms with dart:io',
    );
  }

  /// Not supported on this platform; see the `dart:io` implementation.
  Future<void> writeFile(
    String localPath,
    String remotePath, {
    Map<String, dynamic>? headers,
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) {
    throw UnsupportedError(
      'writeFile is only supported on platforms with dart:io',
    );
  }
}