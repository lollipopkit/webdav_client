import 'package:test/test.dart';
import 'package:webdav_client_plus/src/internal/property_resolution.dart';

void main() {
  group('resolvePropertyNames', () {
    test('throws when namespace prefix is unknown', () {
      expect(
        () => resolvePropertyNames(const ['oc:permissions']),
        throwsA(isA<ArgumentError>().having(
          (error) => error.message,
          'message',
          contains('Namespace prefix "oc" is not defined'),
        )),
      );
    });

    test('accepts explicit namespace mappings for custom prefixes', () {
      final result = resolvePropertyNames(
        const ['oc:permissions'],
        namespaceMap: const {'oc': 'http://owncloud.org/ns'},
      );

      expect(result.properties.single.qualifiedName, 'oc:permissions');
      expect(result.properties.single.namespaceUri, 'http://owncloud.org/ns');
      expect(result.namespaces, containsPair('oc', 'http://owncloud.org/ns'));
    });
  });
}
