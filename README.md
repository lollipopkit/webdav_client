# webdav_client_plus

[![pub package](https://img.shields.io/pub/v/webdav_client_plus.svg)](https://pub.dev/packages/webdav_client_plus)

A WebDAV client for Dart and Flutter, built on [dio](https://pub.dev/packages/dio).

- File operations: list, read, write, stream, copy, move, delete, `mkdir -p`
- Basic, Bearer and Digest auth (MD5, SHA-256, SHA-512-256, `-sess`, `auth-int`)
- Locks, conditional writes (`If`, `If-Match`, `If-None-Match`) and property management
- Helpers for DeltaV, ACL, BIND, SEARCH, sync-collection and other WebDAV extensions
- Download and upload progress, cancellation, streaming without buffering

## Installation

```shell
dart pub add webdav_client_plus
```

```dart
import 'package:webdav_client_plus/webdav_client_plus.dart';
```

## Quick start

```dart
final client = WebdavClient.basicAuth(
  url: 'https://example.com/remote.php/dav/files/alice',
  user: 'alice',
  pwd: 'password',
);

for (final file in await client.readDir('/')) {
  print('${file.name} ${file.isDir ? '(dir)' : '${file.size} bytes'}');
}
```

### Authentication

```dart
WebdavClient.noAuth(url: 'http://localhost:8080');
WebdavClient.basicAuth(url: 'https://example.com/dav', user: 'u', pwd: 'p');
WebdavClient.bearerToken(url: 'https://example.com/dav', token: 'token');

// Digest: the challenge is filled in from the server's first 401 response.
WebdavClient(
  url: 'https://example.com/dav',
  auth: DigestAuth(user: 'u', pwd: 'p', digestParts: DigestParts(null)),
);
```

### Paths

Paths are decoded names relative to `url`: with
`url: 'https://example.com/dav'`, both `/docs/a.txt` and `docs/a.txt` address
`https://example.com/dav/docs/a.txt`. Every character belongs to the name, so
`/50% done?.txt` is encoded as `/dav/50%25%20done%3F.txt`. `..` cannot leave
`url`; such a path throws `ArgumentError`. Absolute `http(s)://` URLs are used
as they are. `client.absoluteUrl(path)` shows the URL a path resolves to.

`WebdavFile.path` and the hrefs returned by discovery helpers use the same
form (`/docs/a.txt`), so they can be passed back as they are. Resources outside
`url` are reported as absolute URLs.

`PathMode.legacy` keeps the behaviour before 3.0.0 and will be removed in the
next major release.

### Settings

```dart
final client = WebdavClient.noAuth(
  url: 'https://example.com/dav',
  options: WebdavOptions(
    headers: {'accept-charset': 'utf-8'},
    connectTimeout: Duration(seconds: 8),
    sendTimeout: Duration(seconds: 8),
    receiveTimeout: Duration(seconds: 8),
  ),
);

// The settings can also be changed later.
client.setConnectTimeout(8000); // milliseconds

await client.ping(); // throws if the server is unreachable
```

## Usage

### List and inspect

```dart
final children = await client.readDir('/docs');

// Recursive listing. Servers may refuse Depth: infinity (Apache does by
// default), in which case a WebdavException with status 403 is thrown.
final tree = await client.readDir('/docs', depth: PropsDepth.infinity);

final file = await client.readProps('/docs/a.txt');
print('${file?.size} ${file?.modified} ${file?.eTag}');

final exists = await client.exists('/docs/a.txt');
```

### Create folders

```dart
await client.mkdir('/docs');
await client.mkdirAll('/docs/2024/reports'); // creates missing parents
```

### Upload

```dart
await client.write('/docs/a.txt', Uint8List.fromList(utf8.encode('hello')));

// Stream a local file
await client.writeFile(
  'local.bin',
  '/docs/remote.bin',
  onProgress: (count, total) => print('$count / $total'),
);

// Stream any byte source of known length
await client.writeStream('/docs/large.bin', byteStream, contentLength);

// Conditional writes
await client.create('/docs/new.txt', bytes); // fails if it already exists
await client.updateIfMatch('/docs/a.txt', bytes, etag); // fails if changed
```

Streamed uploads cannot be replayed, so with Digest auth send one in-memory
request first to obtain the challenge.

### Download

```dart
final bytes = await client.read('/docs/a.txt');

// Stream to a local file; a partial file is removed on failure or cancel
await client.readFile(
  '/docs/remote.bin',
  'local.bin',
  onProgress: (count, total) => print(count / total),
);

// Raw response stream, without buffering
final resp = await client.readStream('/docs/remote.bin');
await resp.data!.stream.drain<void>();
```

### Copy, move and delete

```dart
await client.copy('/docs/a.txt', '/backup/a.txt', overwrite: true);
await client.rename('/docs/a.txt', '/docs/b.txt', overwrite: true);
await client.copy('/docs/', '/backup/docs/'); // collections copy recursively

await client.remove('/docs/b.txt');
await client.remove('/backup/'); // collections are removed recursively
```

### Locks

```dart
final token = await client.lock('/docs/a.txt', timeout: 600, owner: 'me');
await client.conditionalPut('/docs/a.txt', bytes, lockToken: token);
await client.refreshLock('/docs/a.txt', token);
await client.unlock('/docs/a.txt', token);
```

### Properties

```dart
await client.propPatch(
  '/docs/a.txt',
  [
    PropPatchOperation.set('x:category', 'report'),
    PropPatchOperation.remove('x:draft'),
  ],
  namespaces: {'x': 'https://example.com/ns'},
);

final props = await client.propFind(
  '/docs/a.txt',
  properties: ['x:category'],
  namespaces: {'x': 'https://example.com/ns'},
);
print(props['{https://example.com/ns}category']?.innerText);

final (usedBytes, availableBytes) = await client.quotaBytes();
```

### Cancellation and errors

```dart
final cancel = CancelToken();
final download = client.read('/docs/large.bin', cancelToken: cancel);
cancel.cancel('no longer needed');

try {
  await download;
} on WebdavException catch (e) {
  print('${e.statusCode}: ${e.message}');
} on DioException catch (e) {
  print('cancelled or network error: ${e.type}');
}
```

Failed requests throw `WebdavException`, which carries the status code and the
raw `response`. Network errors and cancellation surface as dio's
`DioException`.

### WebDAV extensions

```dart
// Raw requests, REPORT and SEARCH
final resp = await client.request<String>('REPORT', target: '/calendar');
await client.report('/calendar', '<calendar-query/>', depth: PropsDepth.one);
await client.search('/', '<basicsearch/>', depth: PropsDepth.infinity);
await client.syncCollection('/collection/', syncToken: 'sync-token');

// Discovery
final allow = await client.allowedMethods();
final resourceTypes = await client.resourceTypes(path: '/calendar/');
final reports = await client.supportedReports();
final supportedLocks = await client.supportedLocks('/file.txt');
final locks = await client.lockDiscovery('/file.txt');

// BIND (RFC 5842) and ordered collections (RFC 3648)
await client.bind('/collection/', segment: 'alias.txt', href: '/source.txt');
await client.rebind('/collection/', segment: 'alias.txt', href: '/source.txt');
await client.unbind('/collection/', segment: 'alias.txt');
await client.orderpatch('/ordered/', '<orderpatch/>');

// Versioning (DeltaV, RFC 3253)
await client.versionControl('/file.txt');
await client.checkout('/file.txt');
await client.checkin('/file.txt');
await client.label('/versions/1', labelName: 'release', action: 'add');
await client.versionTree('/versions/1');
final history = await client.versionHistory(path: '/file.txt');

// Access control (RFC 3744)
final principal = await client.currentUserPrincipal();
final privileges = await client.currentUserPrivilegeSet(path: '/file.txt');
final aces = await client.accessControlList(path: '/file.txt');
await client.acl('/resource', '<acl/>');
await client.principalPropertySearch(
  '/principals/',
  property: 'displayname',
  match: 'Alice',
);
```

See the [API reference](https://pub.dev/documentation/webdav_client_plus/latest/)
for the full list.

## Testing

```shell
dart test
```

The integration specs build and run an Apache `mod_dav` container from
`test/apache`, served under `/dav`. They need Docker with permission to build
and run containers, and are skipped when `docker info` fails.
