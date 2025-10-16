part of 'client.dart';

/// Result of parsing a WebDAV Multi-Status response.
class MultiStatusResponse {
  /// The decoded href of the resource the response applies to.
  final String href;

  /// Top-level HTTP status code (outside of propstat blocks), if present.
  final int? statusCode;

  /// Raw status text as transmitted by the server for the top-level status.
  final String? rawStatus;

  /// Detailed propstat blocks grouped by status code.
  final List<MultiStatusPropstat> propstats;

  /// Raw `<d:error>` element reported for the response, if any.
  final XmlElement? error;

  /// Optional response description (DAV:responsedescription) for human diagnostics.
  final String? responseDescription;

  /// Optional redirect location for the resource, decoded when available.
  final String? locationHref;

  const MultiStatusResponse({
    required this.href,
    required this.propstats,
    this.statusCode,
    this.rawStatus,
    this.error,
    this.responseDescription,
    this.locationHref,
  });
}

/// A single propstat block within a Multi-Status response.
class MultiStatusPropstat {
  /// HTTP status code parsed from the propstat status line, if available.
  final int? statusCode;

  /// Raw status text as transmitted by the server.
  final String? rawStatus;

  /// Properties reported for this status, keyed by Clark notation
  /// (e.g. `{DAV:}getetag`). Values expose the original XML element so callers
  /// can inspect complex content if needed.
  final Map<String, XmlElement> properties;

  const MultiStatusPropstat({
    required this.properties,
    this.statusCode,
    this.rawStatus,
  });
}

/// Parse an RFC 4918 Multi-Status XML body into structured responses, closely
/// following the behaviour of SabreDAV's `Client::parseMultiStatus`.
List<MultiStatusResponse> parseMultiStatus(String xmlString) {
  final document = XmlDocument.parse(xmlString);
  final responses = <MultiStatusResponse>[];

  for (final responseElement in findAllElements(document, 'response')) {
    final href = getElementText(responseElement, 'href');
    final decodedHref =
        href != null && href.isNotEmpty ? _decodeHref(href) : '';

    final overallStatusElement = responseElement.childElements.firstWhereOrNull(
      (element) =>
          element.name.local == 'status' &&
          element.parentElement == responseElement,
    );
    final overallStatusText = overallStatusElement?.innerText;
    final overallStatusCode =
        overallStatusText != null ? _parseStatusCode(overallStatusText) : null;

    final errorElement = responseElement.childElements.firstWhereOrNull(
      (element) => element.name.local == 'error',
    );
    final responseDescriptionElement =
        responseElement.childElements.firstWhereOrNull(
      (element) => element.name.local == 'responsedescription',
    );
    final locationElement = responseElement.childElements.firstWhereOrNull(
      (element) => element.name.local == 'location',
    );

    String? responseDescription;
    if (responseDescriptionElement != null) {
      final text = responseDescriptionElement.innerText.trim();
      if (text.isNotEmpty) {
        responseDescription = text;
      }
    }

    String? locationHref;
    if (locationElement != null) {
      final hrefElement = findElements(locationElement, 'href').firstOrNull;
      if (hrefElement != null) {
        final hrefText = hrefElement.innerText;
        if (hrefText.isNotEmpty) {
          locationHref = _decodeHref(hrefText);
        }
      }
    }

    final propstats = <MultiStatusPropstat>[];
    for (final propstatElement in findElements(responseElement, 'propstat')) {
      final statusElement = findElements(propstatElement, 'status').firstOrNull;
      final statusText = statusElement?.innerText;
      final statusCode =
          statusText != null ? _parseStatusCode(statusText) : null;

      final propElement = findElements(propstatElement, 'prop').firstOrNull;
      final properties = <String, XmlElement>{};
      if (propElement != null) {
        for (final prop in propElement.childElements) {
          final namespaceUri = prop.name.namespaceUri ?? '';
          final key = namespaceUri.isEmpty
              ? prop.name.local
              : '{$namespaceUri}${prop.name.local}';
          properties[key] = prop;
        }
      }

      propstats.add(
        MultiStatusPropstat(
          properties: properties,
          statusCode: statusCode,
          rawStatus: statusText,
        ),
      );
    }

    responses.add(
      MultiStatusResponse(
        href: decodedHref,
        propstats: propstats,
        statusCode: overallStatusCode,
        rawStatus: overallStatusText,
        error: errorElement,
        responseDescription: responseDescription,
        locationHref: locationHref,
      ),
    );
  }

  return responses;
}

/// Parse a Multi-Status response into a map keyed by decoded href, mirroring
/// SabreDAV's `Client::parseMultiStatus`.
Map<String, Map<int, Map<String, XmlElement>>> parseMultiStatusToMap(
  String xmlString,
) {
  final responses = parseMultiStatus(xmlString);
  final result = <String, Map<int, Map<String, XmlElement>>>{};

  for (final response in responses) {
    final hrefKey = response.href;
    final statusMap =
        result.putIfAbsent(hrefKey, () => <int, Map<String, XmlElement>>{});

    final overallStatus = response.statusCode;
    if (overallStatus != null) {
      statusMap.putIfAbsent(overallStatus, () => <String, XmlElement>{});
    }

    for (final propstat in response.propstats) {
      final statusCode = propstat.statusCode;
      if (statusCode == null) continue;

      final propertiesCopy = Map<String, XmlElement>.from(propstat.properties);
      statusMap.update(
        statusCode,
        (existing) {
          final merged = Map<String, XmlElement>.from(existing);
          merged.addAll(propertiesCopy);
          return merged;
        },
        ifAbsent: () => propertiesCopy,
      );
    }
  }

  return result;
}

String _decodeHref(String value) {
  try {
    return Uri.decodeFull(value);
  } on FormatException {
    return value;
  }
}

List<String> parsePropPatchFailureMessages(String xmlString) {
  final responses = parseMultiStatus(xmlString);
  final failures = <String>[];

  for (final response in responses) {
    for (final propstat in response.propstats) {
      final status = propstat.statusCode;
      if (status != null && status >= 400) {
        final propNames =
            propstat.properties.values.map(_formatPropertyName).toList();
        final statusText = propstat.rawStatus ?? 'HTTP status $status';
        failures.add(
          'Failed to update properties for ${response.href}: '
          '$statusText. Failed props: $propNames',
        );
      }
    }
  }

  return failures;
}

List<String> parseMultiStatusFailureMessages(String xmlString) {
  final responses = parseMultiStatus(xmlString);
  final failures = <String>[];

  for (final response in responses) {
    final status = response.statusCode;
    if (status != null && status >= 400) {
      final statusText = response.rawStatus ?? 'HTTP status $status';
      failures.add('Failed to process ${response.href}: $statusText');
    }

    for (final propstat in response.propstats) {
      final statusCode = propstat.statusCode;
      if (statusCode == null || statusCode < 400) {
        continue;
      }
      final statusText = propstat.rawStatus ?? 'HTTP status $statusCode';
      final props =
          propstat.properties.values.map(_formatPropertyName).toList();
      final propsSuffix = props.isEmpty ? '' : '. Props: $props';
      failures.add(
        'Failed to process ${response.href}: $statusText$propsSuffix',
      );
    }
  }

  return failures;
}

String _formatPropertyName(XmlElement element) {
  final prefix = element.name.prefix;
  if (prefix != null && prefix.isNotEmpty) {
    return '$prefix:${element.name.local}';
  }

  final namespace = element.name.namespaceUri;
  if (namespace != null && namespace.isNotEmpty) {
    return '{$namespace}${element.name.local}';
  }

  return element.name.local;
}

extension _Utils on WebdavClient {
  // Extract the lock token from the response
  String _extractLockToken(String xmlString) {
    final document = XmlDocument.parse(xmlString);

    // First, try activelock/locktoken/href
    final activeLockElements =
        document.findAllElements('activelock', namespace: '*');
    for (final activeLock in activeLockElements) {
      final lockTokenElements =
          activeLock.findElements('locktoken', namespace: '*');
      for (final lockToken in lockTokenElements) {
        final href = lockToken.findElements('href', namespace: '*').firstOrNull;
        if (href != null && href.innerText.isNotEmpty) {
          return href.innerText;
        }
      }
    }

    // Fall back to locktoken/href
    final lockTokenElements =
        document.findAllElements('locktoken', namespace: '*');
    for (final lockToken in lockTokenElements) {
      final href = lockToken.findElements('href', namespace: '*').firstOrNull;
      if (href != null && href.innerText.isNotEmpty) {
        return href.innerText;
      }
    }

    // Try
    final hrefElements = document.findAllElements('href', namespace: '*');
    for (final href in hrefElements) {
      final text = href.innerText;
      if (text.startsWith('urn:uuid:') || text.startsWith('opaquelocktoken:')) {
        return text;
      }
    }

    throw WebdavException(
      message: 'No lock token found in response',
      statusCode: 500,
    );
  }

  String? _extractLockTokenFromHeaderValue(String? headerValue) {
    if (headerValue == null) {
      return null;
    }
    final match = RegExp(r'<\s*([^>]+)\s*>').firstMatch(headerValue);
    if (match != null) {
      final token = match.group(1)?.trim();
      if (token != null && token.isNotEmpty) {
        return token;
      }
    }
    final trimmed = headerValue.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  String? _extractLockTokenFromIfHeader(String ifHeader) {
    final regex = RegExp(r'<([^>]+)>');
    final matches = regex.allMatches(ifHeader);
    for (final match in matches) {
      final token = match.group(1);
      if (token != null &&
          (token.startsWith('urn:uuid:') ||
              token.startsWith('opaquelocktoken:'))) {
        return token;
      }
    }
    return null;
  }

  String _buildIfHeader(
    String url,
    String path,
    String? lockToken,
    String? etag,
    bool notTag,
  ) {
    if (lockToken == null && etag == null) {
      return '';
    }

    final resourceTag = resolveAgainstBaseUrl(url, path);

    final conditionElements = <String>[];
    if (lockToken != null) {
      // 确保锁令牌格式正确
      final formattedLockToken =
          lockToken.startsWith('<') ? lockToken : '<$lockToken>';
      conditionElements.add(
        notTag ? 'Not $formattedLockToken' : formattedLockToken,
      );
    }

    if (etag != null) {
      final formattedEtag = _formatEntityTag(etag);
      conditionElements
          .add(notTag ? 'Not [$formattedEtag]' : '[$formattedEtag]');
    }

    if (conditionElements.isEmpty) {
      return '';
    }

    final buffer = StringBuffer('<$resourceTag> (');
    buffer.write(conditionElements.join(' '));
    buffer.write(')');

    return buffer.toString();
  }

  String _formatEntityTag(String etag) {
    var trimmed = etag.trim();
    var isWeak = false;

    if (trimmed.startsWith('W/')) {
      isWeak = true;
      trimmed = trimmed.substring(2).trim();
    }

    final normalized = _ensureQuoted(trimmed);
    return isWeak ? 'W/$normalized' : normalized;
  }

  String _ensureQuoted(String value) {
    var result = value.trim();
    if (!result.startsWith('"')) {
      result = '"$result';
    }
    if (!result.endsWith('"')) {
      result = '$result"';
    }
    return result;
  }

  String _fixCollectionPath(String path) {
    if (!path.startsWith('/')) {
      path = '/$path';
    }
    if (!path.endsWith('/')) {
      return '$path/';
    }
    return path;
  }

  void _ensurePropPatchSuccess(Response<String> resp) {
    final status = resp.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw _newResponseError(resp);
    }

    if (status != 207) {
      // RFC 4918 §9.2 allows other 2xx statuses for high-level responses.
      return;
    }

    final xmlString = resp.data;
    if (xmlString == null || xmlString.isEmpty) {
      throw WebdavException(
        message:
            'PROPPATCH response did not include a multi-status body to inspect',
        statusCode: resp.statusCode,
        statusMessage: resp.statusMessage,
        response: resp,
      );
    }

    try {
      final failures = parsePropPatchFailureMessages(xmlString);
      if (failures.isNotEmpty) {
        throw WebdavException(
          message: failures.join('; '),
          statusCode: 422,
          statusMessage: resp.statusMessage,
          response: resp,
        );
      }
    } on XmlException catch (error) {
      throw WebdavException(
        message: 'Unable to parse PROPPATCH response: $error',
        statusCode: resp.statusCode,
        statusMessage: resp.statusMessage,
        response: resp,
      );
    }
  }
}

int? _parseStatusCode(String statusText) {
  final match = RegExp(r'\b(\d{3})\b').firstMatch(statusText);
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}
