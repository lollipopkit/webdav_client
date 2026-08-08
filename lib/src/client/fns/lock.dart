part of '../client.dart';

/// Parsed DAV:activelock information from a lockdiscovery property.
class ActiveLock {
  final String? token;
  final String? scope;
  final String? type;
  final String? depth;
  final String? owner;
  final String? timeout;

  const ActiveLock({
    this.token,
    this.scope,
    this.type,
    this.depth,
    this.owner,
    this.timeout,
  });
}

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
    String? ownerXml,
    PropsDepth depth = PropsDepth.infinity,
    String? ifHeader,
    bool refreshLock = false,
    Map<String, dynamic>? headers,
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

      // Extract the lock token from the If header so we have it even when
      // the server omits it from the refresh response.
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
        headers: headers,
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
      xmlBuilder.namespaceUri('d', 'DAV:');
      xmlBuilder.element('d:lockscope', nest: () {
        xmlBuilder.element(exclusive ? 'd:exclusive' : 'd:shared');
      });
      xmlBuilder.element('d:locktype', nest: () {
        xmlBuilder.element('d:write');
      });
      if (ownerXml != null || owner != null) {
        // RFC 4918 §14.17 allows arbitrary XML inside owner.
        xmlBuilder.element('d:owner', nest: () {
          if (ownerXml != null) {
            xmlBuilder.xml(ownerXml);
          } else {
            final ownerText = owner!;
            if (ownerText.startsWith('http://') ||
                ownerText.startsWith('https://')) {
              xmlBuilder.element('d:href', nest: ownerText);
            } else {
              xmlBuilder.text(ownerText);
            }
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
      headers: headers,
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

  /// Discover supported lock entries reported for [path].
  Future<List<(String scope, String type)>> supportedLocks(
    String path, {
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final props = await propFind(
      path,
      properties: const ['supportedlock'],
      headers: headers,
      cancelToken: cancelToken,
    );
    final supported = props['{DAV:}supportedlock'];
    if (supported == null) {
      return const <(String, String)>[];
    }

    return supported
        .findElements('lockentry', namespaceUri: '*')
        .map((entry) {
          final scope = entry
              .findElements('lockscope', namespaceUri: '*')
              .firstOrNull
              ?.childElements
              .firstOrNull
              ?.name
              .local;
          final type = entry
              .findElements('locktype', namespaceUri: '*')
              .firstOrNull
              ?.childElements
              .firstOrNull
              ?.name
              .local;
          if (scope == null || type == null) {
            return null;
          }
          return (scope, type);
        })
        .whereType<(String, String)>()
        .toList(growable: false);
  }

  /// Discover active locks reported for [path].
  Future<List<ActiveLock>> lockDiscovery(
    String path, {
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    final props = await propFind(
      path,
      properties: const ['lockdiscovery'],
      headers: headers,
      cancelToken: cancelToken,
    );
    final discovery = props['{DAV:}lockdiscovery'];
    if (discovery == null) {
      return const <ActiveLock>[];
    }

    return discovery
        .findElements('activelock', namespaceUri: '*')
        .map(_parseActiveLock)
        .toList(growable: false);
  }

  /// Refresh an existing lock using its lock token.
  ///
  /// RFC 4918 §9.10.2 refreshes a lock with an empty LOCK body and an `If`
  /// header containing the submitted lock token.
  Future<String> refreshLock(
    String path,
    String lockToken, {
    int timeout = 3600,
    List<LockTimeout> timeoutPreferences = const <LockTimeout>[],
    PropsDepth depth = PropsDepth.infinity,
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) {
    final ifHeader = _buildIfHeader(url, path, lockToken, null, false);
    return lock(
      path,
      timeout: timeout,
      timeoutPreferences: timeoutPreferences,
      depth: depth,
      ifHeader: ifHeader,
      refreshLock: true,
      headers: headers,
      cancelToken: cancelToken,
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
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
  }) async {
    await _client.wdUnlock(
      path,
      lockToken,
      headers: headers,
      cancelToken: cancelToken,
    );
  }
}

ActiveLock _parseActiveLock(XmlElement element) {
  String? firstChildName(String container) {
    final containerElement = element.findElements(container, namespaceUri: '*')
        .firstOrNull;
    return containerElement?.childElements.firstOrNull?.name.local;
  }

  String? nestedText(String container, String child) {
    final containerElement = element.findElements(container, namespaceUri: '*')
        .firstOrNull;
    final childElement = containerElement?.findElements(child, namespaceUri: '*')
        .firstOrNull;
    final text = childElement?.innerText.trim();
    return text == null || text.isEmpty ? null : text;
  }

  String? directText(String name) {
    final text = element.findElements(name, namespaceUri: '*')
        .firstOrNull
        ?.innerText
        .trim();
    return text == null || text.isEmpty ? null : text;
  }

  return ActiveLock(
    token: nestedText('locktoken', 'href'),
    scope: firstChildName('lockscope'),
    type: firstChildName('locktype'),
    depth: directText('depth'),
    owner: directText('owner'),
    timeout: directText('timeout'),
  );
}
