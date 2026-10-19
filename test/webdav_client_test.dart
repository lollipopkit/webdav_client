import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

const _testDir = 'test dir';
const _testDir2 = 'test dir2';
const _testFile = 'README.md';
const _testFile2 = 'README2.md';

const _davPrefix = '/dav';

final _dockerSkipReason = _computeDockerSkipReason();

void main() {
  group('Basic', () {
    late WebdavClient client;
    late _ApacheServer server;

    setUpAll(() async {
      server = await _startApacheServer();
      client = WebdavClient.basicAuth(
        url: server.url,
        user: 'test',
        pwd: 'test',
      );
    });

    tearDownAll(() async {
      await server.dispose();
    });

    setUp(() async {
      client.setHeaders({'accept-charset': 'utf-8'});
      client.setConnectTimeout(8000);
      client.setSendTimeout(8000);
      client.setReceiveTimeout(8000);

      try {
        await client.ping();
      } catch (e) {
        print('$e');
      }

      await client.removeAll('/$_testDir');
      await client.removeAll('/$_testDir2');
    });

    test('mkdir', () async {
      await client.mkdir(_testDir);
      await client.mkdirAll('/new folder/new folder2');
      await client.removeAll('/new folder');
    });

    test('write', () async {
      await client.mkdir(_testDir);
      await client.writeFile(_testFile, '/$_testDir/$_testFile');
    });

    test('read', () async {
      await client.mkdir(_testDir);
      await client.writeFile(_testFile, '/$_testDir/$_testFile');

      final props = await client.readProps('/$_testDir/$_testFile');
      expect(props, isNotNull);
      expect(props?.size, isNotNull);
      expect(props?.modified, isNotNull);

      final notExists = await client.exists('/$_testDir/not-exists.txt');
      expect(notExists, isFalse);
    });

    test('list', () async {
      await client.mkdir(_testDir);
      await client.writeFile(_testFile, '/$_testDir/$_testFile');

      final listRootDir = await client.readDir('/');
      expect(listRootDir.isNotEmpty, isTrue);

      final listTestDir = await client.readDir(_testDir);
      expect(listTestDir.map((f) => f.name), [_testFile]);
    });

    test('list excludes self under a base path', () async {
      await client.mkdirAll('/$_testDir/sub');

      final files = await client.readDir('/$_testDir');
      expect(files.map((f) => f.path), ['/$_testDir/sub/']);
    });

    test('list with infinite depth', () async {
      await client.mkdirAll('/$_testDir/a/b');
      await client.writeFile(_testFile, '/$_testDir/a/b/$_testFile');

      final files = await client.readDir(_testDir, depth: PropsDepth.infinity);
      expect(
        files.map((f) => f.path),
        unorderedEquals([
          '/$_testDir/a/',
          '/$_testDir/a/b/',
          '/$_testDir/a/b/$_testFile',
        ]),
      );
    });

    test('rename', () async {
      await client.mkdir(_testDir);
      // Apache answers MOVE into a missing parent with 500 rather than 409.
      await client.mkdir(_testDir2);
      await client.writeFile(_testFile, '/$_testDir/$_testFile');

      await client.rename(
        '/$_testDir/$_testFile',
        '/$_testDir2/$_testFile2',
        overwrite: true,
      );
      final renamed = await client.exists('/$_testDir2/$_testFile2');
      expect(renamed, isTrue);
    });

    test('read file content', () async {
      await client.mkdir(_testDir);
      await client.writeFile(_testFile, '/$_testDir/$_testFile');

      final readContent = await client.read('/$_testDir/$_testFile');
      expect(readContent, isNotEmpty);
    });

    test('copy', () async {
      await client.mkdir(_testDir);
      await client.mkdir(_testDir2);
      await client.writeFile(_testFile, '/$_testDir/$_testFile');

      await client.copy(
        '/$_testDir/$_testFile',
        '/$_testDir2/$_testFile2',
        overwrite: true,
      );
      final copied = await client.exists('/$_testDir2/$_testFile2');
      expect(copied, isTrue);
    });

    test('concurrent', () async {
      await client.mkdir(_testDir);

      await Future.wait([
        client.mkdir('$_testDir/concurrent1'),
        client.mkdir('$_testDir/concurrent2'),
        client.mkdir('$_testDir/concurrent3'),
      ]);

      final dirs = await client.readDir('/$_testDir/');
      expect(dirs.where((d) => d.name.startsWith('concurrent')).length, 3);

      await Future.wait([
        client.remove('/$_testDir/concurrent1'),
        client.remove('/$_testDir/concurrent2'),
        client.remove('/$_testDir/concurrent3'),
      ]);
    });

    test('lock and unlock', () async {
      await client.mkdir(_testDir);
      await client.writeFile(_testFile, '/$_testDir/lock_test.txt');

      final lockToken = await client.lock(
        '/$_testDir/lock_test.txt',
        exclusive: true,
        timeout: 60,
        owner: 'test-owner',
      );
      expect(lockToken, isNotEmpty);

      await client.unlock('/$_testDir/lock_test.txt', lockToken);
    });

    test('property management', () async {
      await client.mkdir(_testDir);
      await client.writeFile(_testFile, '/$_testDir/props_test.txt');

      try {
        final props = {
          'custom:test-prop': 'test-value',
          'custom:another-prop': 'another-value',
        };
        await client.setProps(
          '/$_testDir/props_test.txt',
          props,
          namespaces: const {'custom': 'http://example.com/custom'},
        );

        await client.modifyProps(
          '/$_testDir/props_test.txt',
          setProps: {'custom:updated-prop': 'updated-value'},
          removeProps: ['custom:another-prop'],
          namespaces: const {'custom': 'http://example.com/custom'},
        );
      } catch (e) {
        if (e is WebdavException &&
            (e.statusCode == 403 || e.statusCode == 422)) {
          print(
              'Note: Server does not support WebDAV property modification (${e.statusCode})');
          return;
        }
        rethrow;
      }
    });

    test('conditional put', () async {
      await client.mkdir(_testDir);
      await client.write('/$_testDir/conditional.txt',
          Uint8List.fromList('Initial content'.codeUnits));

      final fileProps = await client.readProps('/$_testDir/conditional.txt');
      final etag = fileProps?.eTag;

      if (etag != null) {
        await client.conditionalPut(
          '/$_testDir/conditional.txt',
          Uint8List.fromList('Updated content'.codeUnits),
          etag: etag,
        );

        final updatedContent = await client.read('/$_testDir/conditional.txt');
        expect(String.fromCharCodes(updatedContent), equals('Updated content'));

        expect(
          () => client.conditionalPut(
            '/$_testDir/conditional.txt',
            Uint8List.fromList('Should not update'.codeUnits),
            etag: 'wrong-etag',
          ),
          throwsA(anything),
        );
      }

      final lockToken = await client.lock('/$_testDir/conditional.txt');
      await client.conditionalPut(
        '/$_testDir/conditional.txt',
        Uint8List.fromList('Lock updated content'.codeUnits),
        lockToken: lockToken,
      );

      await client.unlock('/$_testDir/conditional.txt', lockToken);
    });

    test('error handling', () async {
      await client.mkdir(_testDir);

      expect(
        () => client.readDir('/non-existent-dir'),
        throwsA(isA<WebdavException<Object>>()),
      );

      expect(
        () => client.modifyProps(
          '/non-existent-file.txt',
          setProps: {'custom:prop': 'value'},
          namespaces: const {'custom': 'http://example.com/custom'},
        ),
        throwsA(isA<WebdavException<Object>>()),
      );

      expect(
        // Locking an unmapped URL creates it (RFC 4918 §7.3); a missing
        // parent must still fail.
        () => client.lock('/non-existent-dir/file.txt'),
        throwsA(isA<WebdavException<Object>>()),
      );
    });

    test('remove', () async {
      await client.mkdir(_testDir);
      await client.remove('/$_testDir');

      final dirs = await client.readDir('/');
      expect(dirs.where((d) => d.name == _testDir).isEmpty, isTrue);
    });

    test('non-existent file readFile', () async {
      expect(
        () => client.readFile('/non-existent-file.txt', 'output.txt'),
        throwsA(anything),
      );
    });
  }, skip: _dockerSkipReason);

  test('Invalid URL', () async {
    final invalidClient = WebdavClient.noAuth(url: 'http://invalid-url');
    expect(
      invalidClient.ping,
      throwsA(anything),
    );
  });
}

class _ApacheServer {
  _ApacheServer(this._containerName, this.port);

  final String _containerName;
  final int port;

  String get url => 'http://127.0.0.1:$port$_davPrefix';

  Future<void> dispose() async {
    await Process.run('docker', ['rm', '-f', _containerName]);
  }
}

String? _computeDockerSkipReason() {
  try {
    final result = Process.runSync('docker', const ['info']);
    if (result.exitCode != 0) {
      return 'docker is required for WebDAV integration tests '
          '(exit ${result.exitCode})';
    }
  } on ProcessException catch (e) {
    return 'docker is required for WebDAV integration tests (${e.message})';
  }
  return null;
}

/// Start Apache mod_dav from `test/apache`.
Future<_ApacheServer> _startApacheServer() async {
  const image = 'webdav-client-test-apache';
  final build = await Process.run(
    'docker',
    ['build', '-q', '-t', image, 'test/apache'],
  );
  if (build.exitCode != 0) {
    throw StateError('Failed to build $image: ${build.stderr}');
  }

  final port = await _allocatePort();
  final name = '$image-$port';
  final run = await Process.run('docker', [
    'run',
    '-d',
    '--rm',
    '--name',
    name,
    '-p',
    '127.0.0.1:$port:80',
    image,
  ]);
  if (run.exitCode != 0) {
    throw StateError('Failed to start $image: ${run.stderr}');
  }

  final server = _ApacheServer(name, port);
  try {
    await _waitForServerReady(server.url);
  } catch (_) {
    await server.dispose();
    rethrow;
  }
  return server;
}

Future<void> _waitForServerReady(String url) async {
  final client = HttpClient();
  final authHeader = 'Basic ${base64Encode(utf8.encode('test:test'))}';
  final uri = Uri.parse('$url/');
  final deadline = DateTime.now().add(const Duration(seconds: 30));

  while (DateTime.now().isBefore(deadline)) {
    try {
      final request = await client.openUrl('OPTIONS', uri);
      request.headers.set(HttpHeaders.authorizationHeader, authHeader);
      final response = await request.close();
      await response.drain<void>();
      if (response.statusCode == HttpStatus.ok) {
        client.close(force: true);
        return;
      }
    } catch (_) {
      // Not accepting connections yet.
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }

  client.close(force: true);
  throw StateError('Timed out waiting for Apache at $url');
}

Future<int> _allocatePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}
