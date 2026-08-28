/// OnlySpace 客户端共享核心（crypto / protocol / sync）——纯 Dart，App 与 CLI 共用。
library;

export 'src/crypto/attachment_crypto.dart';
export 'src/crypto/keys.dart';
export 'src/crypto/message_crypto.dart';
export 'src/protocol/api_client.dart';
export 'src/protocol/types.dart';
export 'src/sodium.dart' show sodium, loadDynamicLibrary, resetSodium;
export 'src/sync/sync_state.dart';
