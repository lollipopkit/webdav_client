part of '../client.dart';

extension WebdavClientLock on WebdavClient {
  /// Lock a resource
  ///
  /// - [path] of the resource
  /// - [exclusive] If true, the lock is exclusive; if false, the lock is shared
  /// - [timeout] of the lock in seconds
  /// - [timeoutPreferences] optional list of Timeout header preferences per RFC 4918 §10.7
  ///
  /// Returns the lock token
  Future<String> lock(
    String path, {
    bool exclusive = true,
    int timeout = 3600,
    List<LockTimeout> timeoutPreferences = const <LockTimeout>[],
    String? owner,
    PropsDepth depth = PropsDepth.infinity,
    String? ifHeader,
    bool refreshLock = false,
    CancelToken? cancelToken,
  }) async {
    if (depth == PropsDepth.one) {
      throw ArgumentError(
        'LOCK depth must be 0 or infinity per RFC 4918 §9.10.3',
      );
    }

    if (refreshLock) {
      if (ifHeader == null) {
        throw WebdavException(
          message: '`If` header is required for lock refresh',
          statusCode: 400,
        );
      }

      // Extract the lock token from the If header so we have it even if the server doesn't return it in the response
      final existingLockToken = _extractLockTokenFromIfHeader(ifHeader);
      if (existingLockToken == null) {
        throw WebdavException(
          message: 'Valid lock token not found in If header',
          statusCode: 400,
        );
      }

      final resp = await _client.wdLock(
        path,
        null, // Empty body for lock refresh
        depth: depth,
        timeout: timeout,
        timeoutPreferences: timeoutPreferences,
        cancelToken: cancelToken,
        ifHeader: ifHeader,
      );

      if (resp.statusCode != 200) {
        throw _newResponseError(resp);
      }

      // RFC 4918 9.10.2
      // Returns the same lock token if the lock was successfully refreshed
      return existingLockToken;
    }

    final xmlBuilder = XmlBuilder();
    xmlBuilder.processing('xml', 'version="1.0" encoding="utf-8"');
    xmlBuilder.element('d:lockinfo', nest: () {
      xmlBuilder.namespace('DAV:', 'd');
      xmlBuilder.element('d:lockscope', nest: () {
        xmlBuilder.element(exclusive ? 'd:exclusive' : 'd:shared');
      });
      xmlBuilder.element('d:locktype', nest: () {
        xmlBuilder.element('d:write');
      });
      if (owner != null) {
        // RFC 4918 14.17
        // The owner XML can contain any XML content, so we need to handle URLs
        xmlBuilder.element('d:owner', nest: () {
          // If the owner is a URL, it must be wrapped in a <d:href> tag
          if (owner.startsWith('http://') || owner.startsWith('https://')) {
            xmlBuilder.element('d:href', nest: owner);
          } else {
            xmlBuilder.text(owner);
          }
        });
      }
    });

    final xmlString = xmlBuilder.buildDocument().toString();
    final resp = await _client.wdLock(
      path,
      xmlString,
      depth: depth,
      timeout: timeout,
      timeoutPreferences: timeoutPreferences,
      cancelToken: cancelToken,
      ifHeader: ifHeader,
    );

    // Check if the lock was successful
    final status = resp.statusCode;
    if (status != 200 && status != 201) {
      throw _newResponseError(resp);
    }

    final headerToken =
        _extractLockTokenFromHeaderValue(resp.headers.value('lock-token'));
    if (headerToken != null && headerToken.isNotEmpty) {
      return headerToken;
    }

    final data = resp.data;
    if (data is String && data.isNotEmpty) {
      return _extractLockToken(data);
    }

    throw WebdavException(
      message: 'No lock token found in response',
      statusCode: status,
      statusMessage: resp.statusMessage,
      response: resp,
    );
  }

  /// Unlock a resource
  ///
  /// - [path] of the resource
  /// - [lockToken] of the resource
  /// - [cancelToken] for cancelling the request
  Future<void> unlock(
    String path,
    String lockToken, {
    CancelToken? cancelToken,
  }) async {
    await _client.wdUnlock(path, lockToken, cancelToken: cancelToken);
  }
}
