part of 'client.dart';

class WebdavException<T> implements Exception {
  final String message;
  final int? statusCode;
  final String? statusMessage;
  final Response<T>? response;

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

  factory WebdavException.fromResponse(
    Response<T> response, [
    String? message,
  ]) {
    final status = response.statusCode;
    final statusMessage = response.statusMessage;

    String errorMessage = message ?? 'WebDAV operation failed';

    // RFC 4918
    switch (status) {
      case 207:
        // Parse the exact err of the multistatus response
        try {
          final xmlDoc = XmlDocument.parse(response.data as String);
          final errorElements = xmlDoc.findAllElements('error', namespace: '*');
          if (errorElements.isNotEmpty) {
            final firstError = errorElements.first;
            errorMessage = 'MultiStatus error: ${firstError.innerText}';
          }
        } catch (_) {
          errorMessage = 'Multi-Status response with errors';
        }
        break;
      case 422:
        errorMessage =
            'Unprocessable Entity: The server understands the content type but was unable to process the contained instructions';
        break;
      case 423:
        errorMessage = 'Resource is locked';
        break;
      case 424:
        errorMessage =
            'Failed dependency: The method could not be performed because the requested action depended on another action that failed';
        break;
      case 507:
        errorMessage = 'Insufficient storage';
        break;
      // Other common status codes
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
        errorMessage =
            'Conflict: The request could not be completed due to a conflict with the current state of the resource';
        break;
      case 412:
        errorMessage =
            'Precondition failed: One of the conditions specified in the request header failed';
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

WebdavException<T> _newResponseError<T>(Response<T> resp, [String? message]) {
  return WebdavException.fromResponse(resp, message);
}
