library;

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

/// OnlySpace 客户端本地库（Local-First 主存储，DATABASE.md §3）。
///
/// - 消息密文与本地状态（pending/sent/...）
/// - 附件元数据（解密所需 nonce/sha256）
/// - 同步锚点（per-space last_server_sequence）
/// - 密钥不进 SQLite（Keychain/Keystore，见 DATABASE.md §4）

part 'local_database.g.dart';

/// 本地消息（与 Server messages 同构 + 本地状态）。
class LocalMessages extends Table {
  TextColumn get messageId => text()();
  TextColumn get spaceId => text()();
  TextColumn get senderDeviceId => text()();
  TextColumn get type => text()();
  IntColumn get keyVersion => integer()();
  TextColumn get nonce => text()();
  TextColumn get ciphertext => text()();
  IntColumn get serverSequence => integer().nullable()(); // NULL = 尚未同步
  IntColumn get createdAt => integer()();
  TextColumn get status =>
      text().withDefault(const Constant('pending'))(); // pending|sent|delivered|read|failed
  IntColumn get localCreatedAt => integer()();

  @override
  Set<Column> get primaryKey => {messageId};
}

/// 本地附件元数据。
class LocalAttachments extends Table {
  TextColumn get attachmentId => text()();
  TextColumn get messageId => text().references(LocalMessages, #messageId)();
  IntColumn get keyVersion => integer()();
  IntColumn get size => integer()();
  TextColumn get sha256 => text()();
  TextColumn get nonce => text()();
  TextColumn get localPath => text().nullable()(); // 解密缓存路径（App 私有目录）
  TextColumn get status => text().withDefault(const Constant('pending'))(); // pending|uploaded|downloaded

  @override
  Set<Column> get primaryKey => {attachmentId};
}

/// 同步锚点（per-space 单调序列）。
class SyncState extends Table {
  TextColumn get spaceId => text()();
  IntColumn get lastServerSequence => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {spaceId};
}

/// 草稿（本地明文，仅存本机）。
class Drafts extends Table {
  TextColumn get messageId => text()();
  TextColumn get spaceId => text()();
  TextColumn get content => text()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {messageId};
}

/// 本地应用状态（设置等）。
class AppState extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(tables: [LocalMessages, LocalAttachments, SyncState, Drafts, AppState])
class LocalDatabase extends _$LocalDatabase {
  LocalDatabase() : super(_openConnection());

  LocalDatabase.forTesting(super.executor) : super();

  @override
  int get schemaVersion => 1;

  static QueryExecutor _openConnection() => driftDatabase(name: 'onlyspace');
}
