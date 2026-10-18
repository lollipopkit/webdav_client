import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:test/test.dart';
import 'package:webdav_client_plus/src/internal/auth_challenge.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

typedef _Handler = Future<void> Function(HttpRequest request);

Future<HttpServer> _serve(_Handler handler) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen(handler);
  return server;
}

String _url(HttpServer server) => 'http://127.0.0.1:${server.port}';

String _md5(String value) => crypto.md5.convert(utf8.encode(value)).toString();

Map<String, String> _digestParams(String header) => {
      for (final m in RegExp(r'(\w+)=(?:"([^"]*)"|([^,\s]*))')
          .allMatches(header.substring('Digest '.length)))
        m.group(1)!: m.group(2) ?? m.group(3)!,
    };

void main() {
  group('cross-origin redirects', () {
    test('drop client-wide sensitive headers', () async {
      final seen = <String?>[];
      final target = await _serve((request) async {
        seen.add(request.headers.value('cookie'));
        seen.add(request.headers.value('authorization'));
        await request.response.close();
      });
      final origin = await _serve((request) async {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set('Location', '${_url(target)}/x');
        await request.response.close();
      });

      final client = WebdavClient.noAuth(url: _url(origin))
        ..setHeaders({'Cookie': 'sid=secret', 'Authorization': 'Bearer s'});
      await client.read('/f');
      expect(seen, [null, null]);
    });

    test('keep dropping per-request headers on later hops', () async {
      final cookies = <String, String?>{};
      final target = await _serve((request) async {
        cookies[request.uri.path] = request.headers.value('cookie');
        if (request.uri.path == '/x') {
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set('Location', '/y');
        }
        await request.response.close();
      });
      final origin = await _serve((request) async {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set('Location', '${_url(target)}/x');
        await request.response.close();
      });

      await WebdavClient.noAuth(url: _url(origin))
          .read('/f', headers: {'Cookie': 'sid=secret'});
      expect(cookies, {'/x': null, '/y': null});
    });
  });

  group('303 See Other', () {
    test('turns PUT into a GET without entity headers', () async {
      final requests = <String>[];
      final server = await _serve((request) async {
        await request.drain<void>();
        requests.add('${request.method} ${request.uri.path} '
            '${request.headers.contentLength}');
        if (request.method == 'PUT') {
          request.response
            ..statusCode = HttpStatus.seeOther
            ..headers.set('Location', '/done');
        }
        await request.response.close();
      });

      await WebdavClient.noAuth(url: _url(server)).request<String>(
        'PUT',
        target: '/f',
        data: Uint8List(100),
        configure: (options) => options.headers?['content-length'] = 100,
      );
      expect(requests, ['PUT /f 100', 'GET /done -1']);
    });

    test('keeps HEAD as HEAD', () async {
      final methods = <String>[];
      final server = await _serve((request) async {
        methods.add(request.method);
        if (request.uri.path == '/f') {
          request.response
            ..statusCode = HttpStatus.seeOther
            ..headers.set('Location', '/g');
        }
        await request.response.close();
      });

      await WebdavClient.noAuth(url: _url(server)).head('/f');
      expect(methods, ['HEAD', 'HEAD']);
    });
  });

  group('streamed reads', () {
    test('readFile reports 401 as WebdavException', () async {
      final server = await _serve((request) async {
        request.response
          ..statusCode = HttpStatus.unauthorized
          ..headers.set('WWW-Authenticate', 'Basic realm="x"');
        await request.response.close();
      });
      final dir = await Directory.systemTemp.createTemp('read_file_401_');
      addTearDown(() => dir.delete(recursive: true));

      final client =
          WebdavClient.basicAuth(url: _url(server), user: 'u', pwd: 'p');
      await expectLater(
        client.readFile('/f', '${dir.path}/f'),
        throwsA(
          isA<WebdavException>().having((e) => e.statusCode, 'status', 401),
        ),
      );
    });

    test('readStream drains an error body into the exception', () async {
      final server = await _serve((request) async {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('missing');
        await request.response.close();
      });

      await expectLater(
        WebdavClient.noAuth(url: _url(server)).readStream('/f'),
        throwsA(
          isA<WebdavException<String>>()
              .having((e) => e.response?.data, 'body', 'missing'),
        ),
      );
    });

    test('readFile applies receiveTimeout between chunks', () async {
      final server = await _serve((request) async {
        request.response
          ..bufferOutput = false
          ..contentLength = 6;
        for (var i = 0; i < 6; i++) {
          request.response.add([i]);
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        await request.response.close();
      });
      final dir = await Directory.systemTemp.createTemp('read_file_timeout_');
      addTearDown(() => dir.delete(recursive: true));

      final client = WebdavClient.noAuth(url: _url(server))
        ..setReceiveTimeout(400);
      await client.readFile('/f', '${dir.path}/f');
      expect(await File('${dir.path}/f').readAsBytes(), [0, 1, 2, 3, 4, 5]);
    });
  });

  group('digest', () {
    DigestAuth digest() =>
        DigestAuth(user: 'u', pwd: 'p', digestParts: DigestParts(null));

    test('sends no Authorization before a challenge', () async {
      final auths = <String?>[];
      final server = await _serve((request) async {
        auths.add(request.headers.value('authorization'));
        await request.response.close();
      });

      await WebdavClient(url: _url(server), auth: digest()).read('/f');
      expect(auths, [null]);
    });

    test('picks the Digest challenge out of a multi-scheme field', () async {
      final auths = <String>[];
      final server = await _serve((request) async {
        final auth = request.headers.value('authorization');
        if (auth == null) {
          request.response
            ..statusCode = HttpStatus.unauthorized
            ..headers.set(
              'WWW-Authenticate',
              'Basic realm="digest", Digest realm="r2", nonce="n1", '
                  'qop="auth"',
            );
        } else {
          auths.add(auth);
        }
        await request.response.close();
      });

      await WebdavClient(url: _url(server), auth: digest()).read('/f');
      final params = _digestParams(auths.single);
      expect(params['realm'], 'r2');
      expect(params['nonce'], 'n1');
    });

    test('rejects a challenge with only unsupported algorithms', () async {
      final server = await _serve((request) async {
        request.response
          ..statusCode = HttpStatus.unauthorized
          ..headers.set(
            'WWW-Authenticate',
            'Digest realm="r", nonce="n", algorithm=SHA-1',
          );
        await request.response.close();
      });

      await expectLater(
        WebdavClient(url: _url(server), auth: digest()).read('/f'),
        throwsA(isA<WebdavException>().having(
          (e) => e.message,
          'message',
          contains('no supported algorithm'),
        )),
      );
    });

    test('auth-int hashes the request body', () async {
      String? verified;
      final server = await _serve((request) async {
        final body = await request.fold<List<int>>([], (a, b) => a..addAll(b));
        final auth = request.headers.value('authorization');
        if (auth == null) {
          request.response
            ..statusCode = HttpStatus.unauthorized
            ..headers.set(
              'WWW-Authenticate',
              'Digest realm="r", nonce="n", qop="auth-int"',
            );
        } else {
          final p = _digestParams(auth);
          final ha1 = _md5('u:r:p');
          final bodyHash = crypto.md5.convert(body).toString();
          final ha2 = _md5('${request.method}:${p['uri']}:$bodyHash');
          final expected = _md5(
            '$ha1:n:${p['nc']}:${p['cnonce']}:auth-int:$ha2',
          );
          verified = p['response'] == expected ? 'ok' : 'mismatch';
          request.response.statusCode =
              verified == 'ok' ? HttpStatus.created : HttpStatus.unauthorized;
        }
        await request.response.close();
      });

      await WebdavClient(url: _url(server), auth: digest()).request<String>(
        'PUT',
        target: '/f.txt',
        data: Uint8List.fromList(utf8.encode('hello')),
      );
      expect(verified, 'ok');
    });
  });

  test('COPY retries a 409 at most once', () async {
    var copies = 0;
    final server = await _serve((request) async {
      await request.drain<void>();
      if (request.method == 'COPY') {
        copies++;
        request.response.statusCode = HttpStatus.conflict;
      } else {
        request.response.statusCode = HttpStatus.methodNotAllowed;
      }
      await request.response.close();
    });

    await expectLater(
      WebdavClient.noAuth(url: _url(server)).copy('/a.txt', '/f.txt/b.txt'),
      throwsA(isA<WebdavException>()),
    );
    expect(copies, 2);
  });

  group('parseAuthChallenges', () {
    test('splits several challenges on one line', () {
      final challenges = parseAuthChallenges([
        'Basic realm="a, b", Digest realm="r", nonce="n", qop="auth,auth-int"',
        'Bearer abc==',
      ]);
      expect(challenges.map((c) => c.scheme), ['basic', 'digest', 'bearer']);
      expect(challenges[0].params, 'realm="a, b"');
      expect(challenges[1].params, 'realm="r", nonce="n", qop="auth,auth-int"');
      expect(challenges[2].params, 'abc==');
    });

    test('keeps a parameter whose name looks like a scheme', () {
      final challenges = parseAuthChallenges(['Digest nonce = "n", realm="r"']);
      expect(challenges.single.params, 'nonce = "n", realm="r"');
    });
  });
}
