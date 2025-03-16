part of 'client.dart';

class WebdavException implements Exception {
  final String message;
  final int? statusCode;
  final String? statusMessage;
  final Response? response;

  WebdavException({
    required this.message,
    this.statusCode,
    this.statusMessage,
    this.response,
  });

  @override
  String toString() {
    return 'WebdavException: $message (Status: ${statusCode ?? "unknown"} ${statusMessage ?? ""})';
  }

  factory WebdavException.fromResponse(Response response, [String? message]) {
    final status = response.statusCode;
    final statusMessage = response.statusMessage;

    String errorMessage = message ?? 'WebDAV operation failed';

    // 根据RFC 4918状态码定义更精确的错误信息
    switch (status) {
      case 423:
        errorMessage = 'Resource is locked';
        break;
      case 424:
        errorMessage = 'Failed dependency';
        break;
      case 507:
        errorMessage = 'Insufficient storage';
        break;
      // 其他HTTP状态码
      case 401:
        errorMessage = 'Authentication required';
        break;
      case 403:
        errorMessage = 'Access forbidden';
        break;
      case 404:
        errorMessage = 'Resource not found';
        break;
      case 409:
        errorMessage = 'Conflict';
        break;
      case 412:
        errorMessage = 'Precondition failed';
        break;
    }

    return WebdavException(
      message: errorMessage,
      statusCode: status,
      statusMessage: statusMessage,
      response: response,
    );
  }
}

WebdavException _newResponseError(Response resp, [String? message]) {
  return WebdavException.fromResponse(resp, message);
}
