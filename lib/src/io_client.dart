/// Local-file convenience operations for [WebdavClient].
///
/// These helpers require `dart:io` and are therefore only exported on VM
/// platforms; on web they compile to a stub that throws [UnsupportedError].
library;

export 'io_client_stub.dart' if (dart.library.io) 'io_client_io.dart';