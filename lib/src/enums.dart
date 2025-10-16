import 'package:webdav_client_plus/src/internal/property_resolution.dart';
import 'package:xml/xml.dart';

/// Depth of the PROPFIND request
enum PropsDepth {
  /// Only the properties of the resource
  zero,

  /// Including the properties of the resource and its direct children
  one,

  /// Including the properties of the resource and all its children
  infinity,
  ;

  /// Get the String value of the enum
  String get value {
    return switch (this) {
      zero => '0',
      one => '1',
      infinity => 'infinity',
    };
  }
}

/// Type of PROPFIND request
enum PropfindType {
  /// Properties
  prop,

  /// All properties
  allprop,

  /// Only property names
  propname,
  ;

  /// Build the XML string for the PROPFIND request
  String buildXmlStr(
    List<String> properties, {
    Map<String, String> namespaceMap = const <String, String>{},
  }) {
    return switch (this) {
      prop => _buildPropXml(properties, namespaceMap: namespaceMap),
      allprop => _buildAllPropXml(),
      propname => _buildPropNameXml(),
    };
  }

  /// Default properties to be requested in a PROPFIND request
  static const defaultFindProperties = [
    'resourcetype',
    'getcontenttype',
    'getetag',
    'getcontentlength',
    'creationdate',
    'getlastmodified',
    'displayname',
  ];

  static String _buildPropXml(
    List<String> properties, {
    Map<String, String> namespaceMap = const <String, String>{},
  }) {
    final resolution = resolvePropertyNames(
      properties,
      namespaceMap: namespaceMap,
    );

    final xmlBuilder = XmlBuilder();
    xmlBuilder.processing('xml', 'version="1.0" encoding="utf-8"');
    xmlBuilder.element('d:propfind', nest: () {
      xmlBuilder.namespace('DAV:', 'd');

      resolution.namespaces.forEach((prefix, uri) {
        if (prefix == 'd') return;
        xmlBuilder.namespace(uri, prefix);
      });

      xmlBuilder.element('d:prop', nest: () {
        for (final prop in resolution.properties) {
          xmlBuilder.element(prop.qualifiedName);
        }
      });
    });
    return xmlBuilder.buildDocument().toString();
  }

  static String _buildAllPropXml() {
    final xmlBuilder = XmlBuilder();
    xmlBuilder.processing('xml', 'version="1.0" encoding="utf-8"');
    xmlBuilder.element('d:propfind', nest: () {
      xmlBuilder.namespace('DAV:', 'd');
      xmlBuilder.element('d:allprop');
    });
    return xmlBuilder.buildDocument().toString();
  }

  static String _buildPropNameXml() {
    final xmlBuilder = XmlBuilder();
    xmlBuilder.processing('xml', 'version="1.0" encoding="utf-8"');
    xmlBuilder.element('d:propfind', nest: () {
      xmlBuilder.namespace('DAV:', 'd');
      xmlBuilder.element('d:propname');
    });
    return xmlBuilder.buildDocument().toString();
  }
}

/// Representation of a WebDAV `Timeout` preference as defined in RFC 4918 §10.7.
class LockTimeout {
  /// Header fragment to transmit, for example `Second-3600` or `Infinite`.
  final String headerValue;

  const LockTimeout._(this.headerValue);

  /// Request that the server chooses a timeout of exactly [seconds].
  ///
  /// RFC 4918 allows clients to provide a list of preferred durations that the
  /// server may interpret; zero or negative values are rejected because they
  /// have no well-defined meaning for the `Timeout` header.
  factory LockTimeout.seconds(int seconds) {
    if (seconds <= 0) {
      throw ArgumentError.value(seconds, 'seconds', 'must be positive');
    }
    return LockTimeout._('Second-$seconds');
  }

  /// Request an infinite lock duration (`Timeout: Infinite`).
  const LockTimeout.infinite() : headerValue = 'Infinite';

  /// Provide a raw timeout token for extension headers.
  factory LockTimeout.custom(String token) {
    final normalized = token.trim();
    if (normalized.isEmpty) {
      throw ArgumentError('Timeout token cannot be empty');
    }
    return LockTimeout._(normalized);
  }

  @override
  bool operator ==(Object other) =>
      other is LockTimeout && headerValue == other.headerValue;

  @override
  int get hashCode => headerValue.hashCode;

  @override
  String toString() => 'LockTimeout($headerValue)';
}
