/// How a client maps path arguments to request URLs and response hrefs back
/// to paths.
enum PathMode {
  /// Paths are decoded text relative to the base URL path, with or without a
  /// leading `/`. Every character, `%`, `?` and `#` included, belongs to the
  /// name and is percent-encoded per segment. `.` and `..` segments are
  /// resolved, and climbing above the base path throws [ArgumentError].
  ///
  /// Response hrefs inside the base path become such paths; any other href
  /// becomes an absolute URL. Absolute `http(s)://` URLs are accepted as
  /// targets in both forms, so every reported path can be passed back.
  baseRelative,

  /// Behaviour before 3.0.0: an absolute path is appended to the base path
  /// unless it already starts with it or with its first segment, valid `%XX`
  /// escapes are kept, `?` and `#` start a query and fragment, and reported
  /// paths are decoded server hrefs.
  // TODO: remove the legacy path mode in the next major release.
  legacy,
}

/// Options used to initialize a client.
class WebdavOptions {
  /// Path semantics, see [PathMode].
  final PathMode pathMode;

  /// Headers sent with every request.
  final Map<String, dynamic> headers;

  /// Timeout for opening a connection.
  final Duration? connectTimeout;

  /// Timeout for sending a request body.
  final Duration? sendTimeout;

  /// Timeout for receiving response data.
  final Duration? receiveTimeout;

  const WebdavOptions({
    this.pathMode = PathMode.baseRelative,
    this.headers = const <String, dynamic>{},
    this.connectTimeout,
    this.sendTimeout,
    this.receiveTimeout,
  });

  WebdavOptions copyWith({
    PathMode? pathMode,
    Map<String, dynamic>? headers,
    Duration? connectTimeout,
    Duration? sendTimeout,
    Duration? receiveTimeout,
  }) => WebdavOptions(
    pathMode: pathMode ?? this.pathMode,
    headers: headers ?? this.headers,
    connectTimeout: connectTimeout ?? this.connectTimeout,
    sendTimeout: sendTimeout ?? this.sendTimeout,
    receiveTimeout: receiveTimeout ?? this.receiveTimeout,
  );
}
