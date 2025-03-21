import 'package:webdav_client_plus/src/utils.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';
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
    return 'WebdavFile{path: $path, isDir: $isDir, name: $name, mimeType: $mimeType, size: $size, eTag: $eTag, created: $created, modified: $modified}';
  }

  /// Parse a WebDAV XML response to a list of WebdavFile objects
  ///
  /// - [path] is the base path of the files
  /// - [xmlStr] is the XML response from the server
  /// - [skipSelf] is a flag to skip the first entry (self) in the response
  static List<WebdavFile> parseFiles(
    String path,
    String xmlStr, {
    bool skipSelf = true,
  }) {
    final files = <WebdavFile>[];
    final xmlDocument = XmlDocument.parse(xmlStr);
    final responseElements = findAllElements(xmlDocument, 'response');

    bool firstEntry = skipSelf;

    for (final response in responseElements) {
      final href = getElementText(response, 'href');
      if (href == null) continue;

      // Find successful propstat element
      final propstat = _findSuccessfulPropstat(response);
      if (propstat == null) continue;

      // Find and process prop element
      final prop = findElements(propstat, 'prop').firstOrNull;
      if (prop == null) continue;

      // Handle skipSelf logic for first entry
      if (firstEntry) {
        firstEntry = false;
        final isFirstDir = _isDirectory(prop);

        // Only skip if it's a directory, otherwise process as normal
        if (isFirstDir && skipSelf) continue;
      }

      // Create WebdavFile from prop data
      final file = parse(path, href, prop);
      // print(file);
      files.add(file);
    }

    return files;
  }

  /// Create a WebdavFile object from prop data
  ///
  /// - [basePath] is the base path of the files
  /// - [href] is the href of the file
  /// - [prop] is the prop element of the file
  static WebdavFile parse(
    String basePath,
    String href,
    XmlElement prop,
  ) {
    final isDir = _isDirectory(prop);

    // Extract properties
    final mimeType = getElementText(prop, 'getcontenttype');
    final eTag = getElementText(prop, 'getetag');
    final size = isDir ? null : getIntValue(prop, 'getcontentlength');

    // Created time
    final cTimeStr = getElementText(prop, 'creationdate');
    final cTime = cTimeStr != null ? DateTime.tryParse(cTimeStr) : null;

    // Modified time
    final mTimeStr = getElementText(prop, 'getlastmodified');
    final mTime = _parseHttpDate(mTimeStr);

    // Path and name
    final decodedHref = Uri.decodeFull(href);
    var name = getElementText(prop, 'displayname');

    // If name is not found, extract from path
    if (name == null || name.isEmpty) {
      final pathParts = decodedHref.split('/');
      name = pathParts.lastWhere((part) => part.isNotEmpty, orElse: () => '/');
    }

    final quotaAvailableBytes = getIntValue(prop, 'quota-available-bytes');
    final quotaUsedBytes = getIntValue(prop, 'quota-used-bytes');

    // Custom properties
    final customProps = <String, String>{};
    for (final element in prop.childElements) {
      final localName = element.localName;
      final namespace = element.namespaceUri;

      // Skip common properties
      if (PropfindType.defaultFindProperties.contains(localName)) {
        continue;
      }

      // Custom property found
      final value = element.innerText;
      if (value.isNotEmpty) {
        final propName = namespace != null && namespace != 'DAV:'
            ? '$namespace:$localName'
            : localName;
        customProps[propName] = value;
      }
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
  for (var propstat in findElements(response, 'propstat')) {
    final status = getElementText(propstat, 'status');
    if (status != null && status.contains('200')) {
      return propstat;
    }
  }
  return null;
}

/// Determine if resource is a directory
bool _isDirectory(XmlElement prop) {
  final resourceTypes = findElements(prop, 'resourcetype');
  return resourceTypes.isNotEmpty &&
      hasElement(resourceTypes.first, 'collection');
}

/// Parse HTTP date format to DateTime
DateTime? _parseHttpDate(String? httpDate) {
  if (httpDate == null) return null;

  try {
    final pattern = RegExp(
      r'(\w{3}), (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT',
      caseSensitive: false,
    );
    final match = pattern.firstMatch(httpDate);

    if (match != null) {
      final day = match.group(2)!.padLeft(2, '0');
      final month = _monthMap[match.group(3)!.toLowerCase()];
      final year = match.group(4);
      final time = '${match.group(5)}:${match.group(6)}:${match.group(7)}';

      if (month != null) {
        return DateTime.parse('$year-$month-${day}T${time}Z').toLocal();
      }
    }

    // Fallback for any other formats
    return DateTime.tryParse(httpDate);
  } catch (_) {
    return null;
  }
}

const _monthMap = {
  'jan': '01',
  'feb': '02',
  'mar': '03',
  'apr': '04',
  'may': '05',
  'jun': '06',
  'jul': '07',
  'aug': '08',
  'sep': '09',
  'oct': '10',
  'nov': '11',
  'dec': '12',
};
