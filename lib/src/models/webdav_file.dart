import 'package:webdav_client_plus/src/enums.dart';
import 'package:webdav_client_plus/src/internal/path_utils.dart';
import 'package:webdav_client_plus/src/internal/xml_utils.dart';
import 'package:xml/xml.dart';

/// WebdavFile class
///
/// Represents a file or directory in a WebDAV server.
class WebdavFile {
  /// Path of the file or directory
  final String path;

  /// Whether the item is a directory
  final bool isDir;

  /// Name of the file or directory
  final String name;

  /// MIME type of the file
  final String? mimeType;

  /// Size of the file in bytes
  final int? size;

  /// ETag of the file
  final String? eTag;

  /// Created time
  final DateTime? created;

  /// Modified time
  final DateTime? modified;

  /// Used bytes in the quota
  final int? quotaUsedBytes;

  /// Available bytes in the quota
  final int? quotaAvailableBytes;

  /// Custom properties
  final Map<String, String> customProps;

  /// Constructor for [WebdavFile]
  const WebdavFile({
    required this.path,
    required this.isDir,
    required this.name,
    this.mimeType,
    this.size,
    this.eTag,
    this.created,
    this.modified,
    this.quotaUsedBytes,
    this.quotaAvailableBytes,
    this.customProps = const {},
  });

  @override
  String toString() {
    return 'WebdavFile{'
        'path: $path, '
        'isDir: $isDir, '
        'name: $name, '
        'mimeType: $mimeType, '
        'size: $size, '
        'eTag: $eTag, '
        'created: $created, '
        'modified: $modified'
        '}';
  }

  /// Parse a WebDAV XML response to a list of WebdavFile objects
  ///
  /// - [path] is the requested path or absolute URL, matched against hrefs
  ///   when [skipSelf] is set
  /// - [xmlStr] is the XML response from the server
  /// - [skipSelf] is a flag to skip the first entry (self) in the response
  static List<WebdavFile> parseFiles(
    String path,
    String xmlStr, {
    bool skipSelf = true,
  }) {
    final files = <WebdavFile>[];
    final xmlDocument = XmlDocument.parse(xmlStr);
    final responseElements = multiStatusResponses(xmlDocument);

    final normalizedBaseHref = skipSelf
        ? _normalizeHrefForComparison(
            path,
            treatAsCollection: path.trim().isEmpty || path.trim().endsWith('/'),
          )
        : null;

    for (final response in responseElements) {
      final href = hrefText(response);
      if (href == null) continue;

      // Find successful propstat element
      final propstat = _findSuccessfulPropstat(response);
      if (propstat == null) continue;

      // Find and process prop element
      final prop = findElements(propstat, 'prop').firstOrNull;
      if (prop == null) continue;

      if (skipSelf && normalizedBaseHref != null) {
        final normalizedHref = _normalizeHrefForComparison(
          href,
          treatAsCollection: normalizedBaseHref.endsWith('/'),
        );
        if (normalizedHref == normalizedBaseHref) {
          continue;
        }
      }

      // Create WebdavFile from prop data
      final file = parse(path, href, prop);
      files.add(file);
    }

    return files;
  }

  /// Create a WebdavFile object from prop data
  ///
  /// - [basePath] is the base path of the files
  /// - [href] is the href of the file as sent by the server (percent-encoded)
  /// - [prop] is the prop element of the file
  static WebdavFile parse(
    String basePath,
    String href,
    XmlElement prop,
  ) {
    final isDir = _isDirectory(prop);

    // Extract properties
    final mimeType = _davText(prop, 'getcontenttype');
    final eTag = _davText(prop, 'getetag');
    final size = isDir ? null : _davInt(prop, 'getcontentlength');

    // RFC 4918 §15.1 specifies RFC 3339, but some servers send HTTP dates.
    final cTimeStr = _davText(prop, 'creationdate');
    final cTime = _parseIsoDate(cTimeStr) ?? _parseHttpDate(cTimeStr);

    final mTime = _parseHttpDate(_davText(prop, 'getlastmodified'));

    // Path and name
    final decodedHref = decodeHref(href.trim());
    var name = _davText(prop, 'displayname');

    // If name is not found, extract from path
    if (name == null || name.isEmpty) {
      final pathParts = decodedHref.split('/');
      name = pathParts.lastWhere((part) => part.isNotEmpty, orElse: () => '/');
    }

    final quotaAvailableBytes = _davInt(prop, 'quota-available-bytes');
    final quotaUsedBytes = _davInt(prop, 'quota-used-bytes');

    // Custom properties
    final customProps = <String, String>{};
    for (final element in prop.childElements) {
      final localName = element.localName;
      final namespace = element.namespaceUri;

      // Skip the DAV: properties exposed as fields
      if (namespace == 'DAV:' &&
          PropfindType.defaultFindProperties.contains(localName)) {
        continue;
      }

      // Custom property found
      final propName = namespace != null && namespace != 'DAV:'
          ? '$namespace:$localName'
          : localName;

      final hasComplexContent =
          element.childElements.isNotEmpty || element.attributes.isNotEmpty;
      final value =
          hasComplexContent ? element.toXmlString() : element.innerText;
      customProps[propName] = value;
    }

    return WebdavFile(
      path: decodedHref,
      isDir: isDir,
      name: name,
      mimeType: mimeType,
      size: size,
      eTag: eTag,
      created: cTime,
      modified: mTime,
      quotaAvailableBytes: quotaAvailableBytes,
      quotaUsedBytes: quotaUsedBytes,
      customProps: customProps,
    );
  }
}

/// Find the first successful propstat element
XmlElement? _findSuccessfulPropstat(XmlElement response) {
  for (final propstat in findElements(response, 'propstat')) {
    final statusText = getElementText(propstat, 'status');
    if (statusText == null) {
      continue;
    }

    final statusCode = parseStatusLine(statusText);
    if (statusCode != null && statusCode >= 200 && statusCode < 300) {
      return propstat;
    }
  }
  return null;
}

/// Determine if resource is a directory
bool _isDirectory(XmlElement prop) =>
    prop
        .getElement('resourcetype', namespaceUri: 'DAV:')
        ?.getElement('collection', namespaceUri: 'DAV:') !=
    null;

/// Trimmed text of the DAV: property [name] in [prop], or `null`.
String? _davText(XmlElement prop, String name) =>
    prop.getElement(name, namespaceUri: 'DAV:')?.innerText.trim();

int? _davInt(XmlElement prop, String name) {
  final value = _davText(prop, name);
  return value != null ? int.tryParse(value) : null;
}

/// Parse an RFC 3339 date, whose `T` and `Z` may be lowercase (§5.6).
DateTime? _parseIsoDate(String? value) {
  if (value == null || value.isEmpty) return null;
  return DateTime.tryParse(value.toUpperCase())?.toLocal();
}

/// Parse HTTP date formats accepted by RFC 9110 §5.6.7.
DateTime? _parseHttpDate(String? httpDate) {
  if (httpDate == null) return null;

  final value = httpDate.trim();
  if (value.isEmpty) return null;

  DateTime? parseMatch(RegExpMatch match, int dayIndex, int monthIndex,
      int yearIndex, int hourIndex, int minuteIndex, int secondIndex) {
    final month = _monthNumbers[match.group(monthIndex)!.toLowerCase()];
    if (month == null) return null;
    final day = int.parse(match.group(dayIndex)!);
    var year = int.parse(match.group(yearIndex)!);
    if (year < 100) {
      // RFC 9110 §5.6.7: a year more than 50 years ahead is in the past.
      final now = DateTime.now().toUtc().year;
      year += now - now % 100;
      if (year > now + 50) year -= 100;
    }
    final hour = int.parse(match.group(hourIndex)!);
    final minute = int.parse(match.group(minuteIndex)!);
    final second = int.parse(match.group(secondIndex)!);

    // Validate numeric ranges before constructing DateTime
    if (month < 1 || month > 12) return null;
    final daysInMonth = DateTime(year, month + 1, 0).day;
    if (day < 1 || day > daysInMonth) return null;
    if (hour < 0 || hour > 23) return null;
    if (minute < 0 || minute > 59) return null;
    if (second < 0 || second > 59) return null;

    final dt = DateTime.utc(year, month, day, hour, minute, second);
    // DateTime.utc silently normalizes out-of-range fields; verify round-trip
    if (dt.year != year ||
        dt.month != month ||
        dt.day != day ||
        dt.hour != hour ||
        dt.minute != minute ||
        dt.second != second) {
      return null;
    }
    return dt.toLocal();
  }

  final imf = RegExp(
    r'^[A-Za-z]{3},\s+(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+'
    r'(\d{2}):(\d{2}):(\d{2})\s+(?:GMT|UTC)$',
  ).firstMatch(value);
  if (imf != null) {
    return parseMatch(imf, 1, 2, 3, 4, 5, 6);
  }

  final rfc850 = RegExp(
    r'^[A-Za-z]+,\s+(\d{1,2})-([A-Za-z]{3})-(\d{2})\s+'
    r'(\d{2}):(\d{2}):(\d{2})\s+(?:GMT|UTC)$',
  ).firstMatch(value);
  if (rfc850 != null) {
    return parseMatch(rfc850, 1, 2, 3, 4, 5, 6);
  }

  final asctime = RegExp(
    r'^[A-Za-z]{3}\s+([A-Za-z]{3})\s+(\d{1,2})\s+'
    r'(\d{2}):(\d{2}):(\d{2})\s+(\d{4})$',
  ).firstMatch(value);
  if (asctime != null) {
    return parseMatch(asctime, 2, 1, 6, 3, 4, 5);
  }

  return _parseIsoDate(value);
}

const _monthNumbers = {
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
};

String _normalizeHrefForComparison(
  String href, {
  required bool treatAsCollection,
}) {
  var value = href.trim();
  if (value.isEmpty) {
    return treatAsCollection ? '/' : '/';
  }

  Uri? parsed;
  try {
    parsed = Uri.parse(value);
  } catch (_) {
    parsed = null;
  }

  if (parsed != null) {
    if (parsed.hasScheme || value.startsWith('/')) {
      value = parsed.path;
    } else if (parsed.path.isNotEmpty) {
      value = parsed.path;
    }
  }

  final queryIndex = value.indexOf('?');
  if (queryIndex != -1) {
    value = value.substring(0, queryIndex);
  }

  final fragmentIndex = value.indexOf('#');
  if (fragmentIndex != -1) {
    value = value.substring(0, fragmentIndex);
  }

  if (!value.startsWith('/')) {
    value = '/$value';
  }

  value = value.replaceAll(RegExp('/+'), '/');
  if (value.isEmpty) {
    value = '/';
  }

  if (treatAsCollection) {
    if (!value.endsWith('/')) {
      value = '$value/';
    }
  } else if (value.length > 1 && value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }

  // Servers may percent-encode differently than the client did.
  return decodeHref(value);
}
