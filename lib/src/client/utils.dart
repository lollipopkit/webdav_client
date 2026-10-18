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

  for (final responseElement in multiStatusResponses(document)) {
    final href = hrefText(responseElement);
    final decodedHref = href != null ? decodeHref(href) : '';

    final overallStatusElement = davChild(responseElement, 'status');
    final overallStatusText = overallStatusElement?.innerText;
    final overallStatusCode =
        overallStatusText != null ? parseStatusLine(overallStatusText) : null;

    final errorElement = davChild(responseElement, 'error');
    final responseDescriptionElement =
        davChild(responseElement, 'responsedescription');
    final locationElement = davChild(responseElement, 'location');

    String? responseDescription;
    if (responseDescriptionElement != null) {
      final text = responseDescriptionElement.innerText.trim();
      if (text.isNotEmpty) {
        responseDescription = text;
      }
    }

    String? locationHref;
    if (locationElement != null) {
      final hrefElement = davChild(locationElement, 'href');
      if (hrefElement != null) {
        final hrefText = hrefElement.innerText.trim();
        if (hrefText.isNotEmpty) {
          locationHref = decodeHref(hrefText);
        }
      }
    }

    final propstats = <MultiStatusPropstat>[];
    for (final propstatElement in davChildren(responseElement, 'propstat')) {
      final statusElement = davChild(propstatElement, 'status');
      final statusText = statusElement?.innerText;
      final statusCode =
          statusText != null ? parseStatusLine(statusText) : null;

      final propElement = davChild(propstatElement, 'prop');
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

/// Parse the XML body of [resp] with [parse], reporting a missing or
/// malformed body as a [WebdavException] that names the [request].
T _parseXmlBody<T>(
  Response<Object?> resp,
  String request,
  T Function(String body) parse,
) {
  WebdavException<Object?> error(String message) => WebdavException(
        message: message,
        statusCode: resp.statusCode,
        statusMessage: resp.statusMessage,
        response: resp,
      );

  final body = resp.data;
  if (body is! String || body.trim().isEmpty) {
    throw error('$request response did not include a multi-status body');
  }
  try {
    return parse(body);
  } on XmlException catch (e) {
    throw error('Unable to parse $request response: $e');
  }
}

List<String> parsePropPatchFailureMessages(String xmlString) =>
    _multiStatusFailures(
      xmlString,
      action: 'update properties for',
      propsLabel: 'Failed props',
      alwaysListProps: true,
    );

List<String> parseMultiStatusFailureMessages(String xmlString) =>
    _multiStatusFailures(
      xmlString,
      action: 'process',
      propsLabel: 'Props',
      alwaysListProps: false,
    );

/// Describe every failed entry of a Multi-Status body. RFC 4918 §14.24 and
/// §14.22 require a status for each propstat and a status or propstats for
/// each response, so a missing or unparsable one counts as a failure.
List<String> _multiStatusFailures(
  String xmlString, {
  required String action,
  required String propsLabel,
  required bool alwaysListProps,
}) {
  final failures = <String>[];

  for (final response in parseMultiStatus(xmlString)) {
    final description = response.responseDescription;
    final descriptionSuffix = description == null ? '' : '. $description';

    String? failedStatus(int? code, String? raw) {
      if (code != null) return code >= 400 ? raw ?? 'HTTP status $code' : null;
      return raw == null ? 'missing status' : 'invalid status "$raw"';
    }

    final responseFailure =
        response.rawStatus != null || response.propstats.isEmpty
            ? failedStatus(response.statusCode, response.rawStatus)
            : null;
    if (responseFailure != null) {
      failures.add(
        'Failed to $action ${response.href}: $responseFailure'
        '$descriptionSuffix',
      );
    }

    for (final propstat in response.propstats) {
      final propstatFailure =
          failedStatus(propstat.statusCode, propstat.rawStatus);
      if (propstatFailure == null) continue;
      final props =
          propstat.properties.values.map(_formatPropertyName).toList();
      final propsSuffix =
          props.isEmpty && !alwaysListProps ? '' : '. $propsLabel: $props';
      failures.add(
        'Failed to $action ${response.href}: '
        '$propstatFailure$propsSuffix$descriptionSuffix',
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
        document.findAllElements('activelock', namespaceUri: '*');
    for (final activeLock in activeLockElements) {
      final lockTokenElements =
          activeLock.findElements('locktoken', namespaceUri: '*');
      for (final lockToken in lockTokenElements) {
        final href = lockToken.findElements('href', namespaceUri: '*').firstOrNull;
        final token = href?.innerText.trim();
        if (token != null && token.isNotEmpty) {
          return token;
        }
      }
    }

    // Fall back to locktoken/href
    final lockTokenElements =
        document.findAllElements('locktoken', namespaceUri: '*');
    for (final lockToken in lockTokenElements) {
      final href = lockToken.findElements('href', namespaceUri: '*').firstOrNull;
      final token = href?.innerText.trim();
      if (token != null && token.isNotEmpty) {
        return token;
      }
    }

    // Try
    final hrefElements = document.findAllElements('href', namespaceUri: '*');
    for (final href in hrefElements) {
      final text = href.innerText.trim();
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

  String _formatLockTokenHeader(String lockToken) {
    final trimmed = lockToken.trim();
    if (trimmed.startsWith('<') && trimmed.endsWith('>')) {
      return trimmed;
    }
    return '<$trimmed>';
  }

  /// First state token in the If header's lists (RFC 4918 §10.4.2). Any
  /// absolute URI is a valid lock token; resource tags outside the lists and
  /// `Not` conditions are skipped.
  String? _extractLockTokenFromIfHeader(String ifHeader) {
    final lists = RegExp(r'\(([^)]*)\)').allMatches(ifHeader);
    for (final list in lists) {
      final conditions = RegExp(r'(Not\s+)?<([^>]+)>').allMatches(list[1]!);
      for (final condition in conditions) {
        if (condition[1] == null) return condition[2]!.trim();
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
      // Lock tokens prove knowledge per RFC 4918 §7.5, so they must remain positive.
      final formattedLockToken = _formatLockTokenHeader(lockToken);
      conditionElements.add(formattedLockToken);
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

    final failures =
        _parseXmlBody(resp, 'PROPPATCH', parsePropPatchFailureMessages);
    if (failures.isNotEmpty) {
      throw WebdavException(
        message: failures.join('; '),
        statusCode: 422,
        statusMessage: resp.statusMessage,
        response: resp,
      );
    }
  }
}
