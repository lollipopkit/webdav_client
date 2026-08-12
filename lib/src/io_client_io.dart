import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:webdav_client_plus/src/client/client.dart';

/// Local-file convenience operations for [WebdavClient] on `dart:io`
/// platforms. Kept in a separate library so the core client compiles for web.
extension WebdavClientIo on WebdavClient {
  /// Read the bytes of a remote file with a stream and write to a local file.
  ///
  /// - [remotePath] of the remote file
  /// - [localPath] of the local file
  /// - [onProgress] callback for progress
  /// - [cancelToken] for cancelling the request
  Future<void> readFile(
    String remotePath,
    String localPath, {
    Map<String, dynamic>? headers,
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final resp = await request<ResponseBody>(
      'GET',
      target: remotePath,
      headers: headers,
      cancelToken: cancelToken,
      configure: (options) => options.responseType = ResponseType.stream,
    );

    if (resp.statusCode != 200 && resp.statusCode != 206) {
      // Consume the error body so the connection can be reused.
      await resp.data?.stream.drain<void>();
      throw WebdavException.fromResponse(resp);
    }

    final respData = resp.data;
    if (respData == null) {
      throw WebdavException.fromResponse(resp, 'Response data is null');
    }

    resp.headers = Headers.fromMap(respData.headers);

    // If directory (or file) doesn't exist yet, the entire method fails.
    final file = File(localPath);
    await file.create(recursive: true);

    final fileReader = await file.open(mode: FileMode.write);

    // Create a Completer to notify the success/error state.
    final completer = Completer<Response<ResponseBody>>();
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

    await _awaitWithCancel(cancelToken, completer.future);
  }

  /// Read a local file and stream its contents to a remote path.
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
    final file = File(localPath);
    return writeStream(
      remotePath,
      file.openRead(),
      await file.length(),
      headers: headers,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }
}

/// Await [future], completing with the cancellation error when [cancelToken]
/// is cancelled and otherwise with the result (or error) of [future].
Future<T> _awaitWithCancel<T>(CancelToken? cancelToken, Future<T> future) {
  if (cancelToken == null || cancelToken.isCancelled) {
    return future;
  }
  final completer = Completer<T>();
  cancelToken.whenCancel.then(
    (error) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    },
    onError: (Object error) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    },
  );
  future.then(
    (value) {
      if (!completer.isCompleted) {
        completer.complete(value);
      }
    },
    onError: (Object error, StackTrace stack) {
      if (!completer.isCompleted) {
        completer.completeError(error, stack);
      }
    },
  );
  return completer.future;
}