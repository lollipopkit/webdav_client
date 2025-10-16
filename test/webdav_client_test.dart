import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

const _baseTestDir = '.test';
const _testDir = 'test dir';
const _testDir2 = 'test dir2';
const _testFile = 'README.md';
const _testFile2 = 'README2.md';

final _dufsSkipReason = _computeDufsSkipReason();

void main() {
  group('Basic', () {
    late WebdavClient client;
    late _DufsServer dufsServer;

    setUpAll(() async {
      dufsServer = await _startDufsServer();
      client = WebdavClient.basicAuth(
        url: 'http://127.0.0.1:${dufsServer.port}',
        user: 'test',
        pwd: 'test',
      );
    });

    tearDownAll(() async {
      await dufsServer.dispose();
    });

    setUp(() async {
      final baseDir = Directory(_baseTestDir);
      if (await baseDir.exists()) {
        await baseDir.delete(recursive: true);
      }
      await baseDir.create();

      client.setHeaders({'accept-charset': 'utf-8'});
      client.setConnectTimeout(8000);
      client.setSendTimeout(8000);
      client.setReceiveTimeout(8000);

      try {
        await client.ping();
      } catch (e) {
        print('$e');
      }
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
      expect(listTestDir.firstOrNull?.name, _testFile);
    });

    test('rename', () async {
      await client.mkdir(_testDir);
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
        () => client.lock('/non-existent-file.txt'),
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
  }, skip: _dufsSkipReason);

  test('Invalid URL', () async {
    final invalidClient = WebdavClient.noAuth(url: 'http://invalid-url');
    expect(
      () => invalidClient.ping(),
      throwsA(anything),
    );
  });
}

class _DufsServer {
  _DufsServer(this._process, this.rootDirectory, this.port);

  final Process _process;
  final Directory rootDirectory;
  final int port;

  Future<void> dispose() async {
    _process.kill();
    await _process.exitCode;
    if (await rootDirectory.exists()) {
      await rootDirectory.delete(recursive: true);
    }
  }
}

String? _computeDufsSkipReason() {
  try {
    final result = Process.runSync('dufs', const ['--version']);
    if (result.exitCode != 0) {
      final stderrOutput = (result.stderr as String?)?.trim();
      return 'dufs is required for WebDAV integration tests '
          '(exit ${result.exitCode}${stderrOutput?.isEmpty ?? true ? '' : ': $stderrOutput'})';
    }
  } on ProcessException catch (e) {
    return 'dufs is required for WebDAV integration tests (${e.message})';
  }
  return null;
}

Future<_DufsServer> _startDufsServer() async {
  final serveDir = await Directory.systemTemp.createTemp('dufs_webdav_');
  final port = await _allocatePort();
  final process = await Process.start(
    'dufs',
    [
      '-A',
      '-a',
      'test:test@/:rw',
      '-b',
      '127.0.0.1',
      '-p',
      '$port',
      serveDir.path,
    ],
    workingDirectory: serveDir.path,
  );

  // Drain the process streams to avoid filling buffers during tests.
  process.stdout.listen((_) {});
  process.stderr.listen((data) {
    final message = utf8.decode(data, allowMalformed: true).trim();
    if (message.isNotEmpty) {
      print('dufs stderr: $message');
    }
  });

  await _waitForServerReady(port);
  return _DufsServer(process, serveDir, port);
}

Future<void> _waitForServerReady(int port) async {
  final client = HttpClient();
  final authHeader = 'Basic ${base64Encode(utf8.encode('test:test'))}';
  final uri = Uri.parse('http://127.0.0.1:$port/__dufs__/health');
  final deadline = DateTime.now().add(const Duration(seconds: 10));

  while (DateTime.now().isBefore(deadline)) {
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.authorizationHeader, authHeader);
      final response = await request.close();
      await response.drain();
      if (response.statusCode == HttpStatus.ok) {
        client.close(force: true);
        return;
      }
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  client.close(force: true);
  throw StateError('Timed out waiting for dufs to start on port $port');
}

Future<int> _allocatePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}
