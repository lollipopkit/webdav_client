import 'dart:async';
import 'dart:io' as io;
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:webdav_client_plus/src/adapter/adapter_stub.dart'
    if (dart.library.io) 'package:webdav_client_plus/src/adapter/adapter_mobile.dart'
    if (dart.library.js) 'package:webdav_client_plus/src/adapter/adapter_web.dart';
import 'package:webdav_client_plus/src/auth.dart';
import 'package:webdav_client_plus/src/enums.dart';
import 'package:webdav_client_plus/src/internal/iterable_extensions.dart';
import 'package:webdav_client_plus/src/internal/path_utils.dart';
import 'package:webdav_client_plus/src/internal/property_resolution.dart';
import 'package:webdav_client_plus/src/internal/xml_utils.dart';
import 'package:webdav_client_plus/src/models/webdav_file.dart';
import 'package:xml/xml.dart';

part 'dio.dart';
part 'error.dart';
part 'utils.dart';

part 'fns/mk.dart';
part 'fns/read.dart';
part 'fns/prop.dart';
part 'fns/lock.dart';
part 'fns/copy_move.dart';
part 'fns/write.dart';
part 'fns/rm.dart';

/// Webdav Client
class WebdavClient {
  /// WebDAV url
  final String url;

  /// Wrapped http client
  late final _client = _WdDio(client: this);

  /// Auth Mode (noAuth/basic/digest/bearer)
  Auth auth;

  /// Create a client with username and password
  WebdavClient({
    required this.url,
    this.auth = const NoAuth(),
  });

  /// Create a client with basic auth
  WebdavClient.basicAuth({
    required this.url,
    required String user,
    required String pwd,
  }) : auth = BasicAuth(user: user, pwd: pwd);

  /// Create a client with bearer token
  WebdavClient.bearerToken({
    required this.url,
    required String token,
  }) : auth = BearerAuth(token: token);

  /// Create a client with no authentication
  WebdavClient.noAuth({
    required this.url,
  }) : auth = const NoAuth();

  // methods--------------------------------

  /// Set the public request headers
  void setHeaders(Map<String, dynamic> headers) =>
      _client.options.headers = headers;

  /// Set the connection server timeout time in milliseconds.
  void setConnectTimeout(int timeout) =>
      _client.options.connectTimeout = Duration(milliseconds: timeout);

  /// Set send data timeout time in milliseconds.
  void setSendTimeout(int timeout) =>
      _client.options.sendTimeout = Duration(milliseconds: timeout);

  /// Set transfer data time in milliseconds.
  void setReceiveTimeout(int timeout) =>
      _client.options.receiveTimeout = Duration(milliseconds: timeout);

  /// Test whether the service can connect
  Future<void> ping([CancelToken? cancelToken]) async {
    final resp = await _client.wdOptions('/', cancelToken: cancelToken);
    final status = resp.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw _newResponseError(resp);
    }
  }

  /// Discover DAV capabilities advertised by the server via the `DAV` header.
  ///
  /// Returns an ordered list of feature tokens, mirroring SabreDAV's
  /// [Client::options] helper (see `dav/lib/DAV/Client.php:371`) and
  /// complying with RFC 4918 §7.7.
  Future<List<String>> options({
    String path = '/',
    bool allowNotFound = false,
    CancelToken? cancelToken,
  }) async {
    final resp = await _client.wdOptions(
      path,
      cancelToken: cancelToken,
      allowNotFound: allowNotFound,
    );
    final davHeader = resp.headers.value('dav');
    if (davHeader == null || davHeader.trim().isEmpty) {
      return const [];
    }
    return davHeader
        .split(',')
        .map((feature) => feature.trim())
        .where((feature) => feature.isNotEmpty)
        .toList(growable: false);
  }

  /// Send a raw WebDAV request while reusing the client's authentication
  /// pipeline and base URL resolution.
  ///
  /// Mirrors SabreDAV's [`Client::request`](dav/lib/DAV/Client.php:419) so
  /// advanced extensions (REPORT, SEARCH, etc.) can be exercised without
  /// reimplementing Digest handling.
  Future<Response<T>> request<T>(
    String method, {
    String target = '',
    dynamic data,
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
    void Function(Options options)? configure,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
  }) {
    return _client.req<T>(
      method,
      target,
      data: data,
      optionsHandler: (options) {
        if (headers != null && headers.isNotEmpty) {
          options.headers ??= <String, dynamic>{};
          headers.forEach((key, value) {
            options.headers?[key] = value;
          });
        }
        if (configure != null) {
          configure(options);
        }
      },
      onSendProgress: onSendProgress,
      onReceiveProgress: onReceiveProgress,
      cancelToken: cancelToken,
    );
  }

  /// Get the quota of the server
  ///
  /// - [cancelToken] for cancelling the request
  Future<(double percent, String size)> quota({
    CancelToken? cancelToken,
  }) async {
    final resp = await _client.wdPropfind(
      '/',
      PropsDepth.zero,
      PropfindType.prop.buildXmlStr([
        'quota-available-bytes',
        'quota-used-bytes',
      ]),
      cancelToken: cancelToken,
    );

    final str = resp.data as String;
    final file = WebdavFile.parseFiles('/', str, skipSelf: false).firstOrNull;
    if (file == null) {
      throw WebdavException(
        message: 'Quota not found',
        statusCode: 404,
      );
    }

    final quotaAvailable = file.quotaAvailableBytes;
    final quotaUsed = file.quotaUsedBytes;
    if (quotaAvailable == null || quotaUsed == null) {
      throw WebdavException(
        message: 'Quota not found',
        statusCode: 404,
      );
    }

    String formatSize(int bytes) {
      final mb = bytes / 1024 / 1024;
      return '${mb.toStringAsFixed(2)}M';
    }

    if (quotaAvailable < 0) {
      return (
        double.nan,
        '${formatSize(quotaUsed)}/unlimited',
      );
    }

    final total = quotaUsed + quotaAvailable;
    if (total <= 0) {
      return (0.0, '0M/0M');
    }

    final percent = quotaUsed / total;
    return (
      percent,
      '${formatSize(quotaUsed)}/${formatSize(total)}',
    );
  }
}
