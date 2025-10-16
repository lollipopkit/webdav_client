part of 'client.dart';

/// Exception type surfaced by the WebDAV client for protocol-aware failures.
///
/// Wraps the underlying dio [Response] together with the translated message so
/// callers can access HTTP metadata in addition to the high level diagnostic.
class WebdavException<T extends Object?> implements Exception {
  final String message;
  final int? statusCode;
  final String? statusMessage;
  final Response<T>? response;

  /// Construct a [WebdavException] with the resolved message and optional
  /// status metadata from the originating HTTP response.
  WebdavException({
    required this.message,
    this.statusCode,
    this.statusMessage,
    this.response,
  });

  @override
  String toString() {
    return 'WebdavException: $message (Status: ${statusCode ?? "unknown"} ${statusMessage ?? ""}):\n${response?.data}';
  }

  /// Create a [WebdavException] by inspecting a raw dio [Response].
  ///
  /// WebDAV-specific status codes are mapped to descriptive messages to help
  /// callers surface RFC 4918 guidance without re-parsing the payload.
  factory WebdavException.fromResponse(
    Response<T> response, [
    String? message,
  ]) {
    final status = response.statusCode;
    final statusMessage = response.statusMessage;

    String errorMessage = message ?? 'WebDAV operation failed';

    // RFC 4918: normalise well-known WebDAV status codes into actionable
    // diagnostics so callers receive consistent guidance when debugging
    // protocol-specific failures.
    switch (status) {
      case 207:
        // Multi-Status (RFC 4918 §13) — parse XML payload for detailed errors.
        try {
          final xmlDoc = XmlDocument.parse(response.data as String);
          final errorElements = xmlDoc.findAllElements('error', namespace: '*');
          if (errorElements.isNotEmpty) {
            // Check common WebDAV preconditions/postconditions codes
            for (final errorElement in errorElements) {
              // Lookup for lock-token-submitted
              if (errorElement
                  .findElements('lock-token-submitted', namespace: '*')
                  .isNotEmpty) {
                return WebdavException(
                  message: 'Resource is locked and requires a valid lock token',
                  statusCode: status,
                  statusMessage: statusMessage,
                  response: response,
                );
              }
              if (errorElement
                  .findElements('no-conflicting-lock', namespace: '*')
                  .isNotEmpty) {
                return WebdavException(
                  message: 'The resource has a conflicting lock',
                  statusCode: status,
                  statusMessage: statusMessage,
                  response: response,
                );
              }
            }

            final firstError = errorElements.first;
            errorMessage = 'MultiStatus error: ${firstError.innerText}';
          }
        } catch (_) {
          errorMessage = 'Multi-Status response with errors';
        }
        break;
      case 422:
        // Unprocessable Entity (RFC 4918 §11.2 / §16).
        errorMessage =
            'Unprocessable Entity: The server understands the content type but was unable to process the contained instructions';
        break;
      case 423:
        // Locked (RFC 4918 §11.3).
        errorMessage = 'Resource is locked';
        break;
      case 424:
        // Failed Dependency (RFC 4918 §11.4).
        errorMessage =
            'Failed dependency: The method could not be performed because the requested action depended on another action that failed';
        break;
      case 507:
        // Insufficient Storage (RFC 4918 §11.5).
        errorMessage = 'Insufficient storage';
        break;
      // Other common status codes
      case 401:
        // HTTP 401 (RFC 7235 §3.1) — authentication challenge.
        errorMessage = 'Authentication required';
        break;
      case 403:
        // HTTP 403 (RFC 7231 §6.5.3) — permissions issue.
        errorMessage = 'Access forbidden';
        break;
      case 404:
        // HTTP 404 (RFC 7231 §6.5.4) — resource missing.
        errorMessage = 'Resource not found';
        break;
      case 409:
        // HTTP 409 (RFC 7231 §6.5.8) — conflict with current state.
        errorMessage =
            'Conflict: The request could not be completed due to a conflict with the current state of the resource';
        break;
      case 412:
        // HTTP 412 (RFC 7232 §4.2) — conditional headers failed.
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

/// Helper to ensure we always translate dio errors into [WebdavException].
WebdavException<T> _newResponseError<T extends Object?>(Response<T> resp,
    [String? message]) {
  return WebdavException.fromResponse(resp, message);
}
