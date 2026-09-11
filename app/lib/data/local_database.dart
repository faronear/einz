library;

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

/// Einz 客户端本地库（Local-First 主存储，DATABASE.md §3）。
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
  // 阅后即焚（纯本地，每设备独立）：到达本设备时的设置快照 + 到期时间戳
  IntColumn get burnAfterSeconds => integer().withDefault(const Constant(0))(); // 0=无限
  IntColumn get expiresAt => integer().nullable()(); // NULL/0=永久；非空=到期时间戳
  // 本地墓碑（纯本地）：非空 = 本机已删除/已焚毁——内容隐藏、时间+焚毁记录保留
  // （老板决策 2026-09-09：不打破消息历史流水，只隐藏内容）
  IntColumn get deletedAt => integer().nullable()(); // NULL=正常；非空=删除时间戳

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
  BlobColumn get localCipher => blob().nullable()(); // 发送端本地密文副本：即时显示/离线兜底
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
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            // v2：local_messages 加阅后即焚列（burn_after_seconds 默认 0、expires_at 可空）
            await m.addColumn(localMessages, localMessages.burnAfterSeconds);
            await m.addColumn(localMessages, localMessages.expiresAt);
          }
          if (from < 3) {
            // v3：local_messages 加本地墓碑列（deleted_at 可空）——删除/焚毁改为
            // 打标记（内容隐藏、记录保留），不再彻底删行（老板决策 2026-09-09）
            await m.addColumn(localMessages, localMessages.deletedAt);
          }
          if (from < 4) {
            // v4：local_attachments 加本地密文副本列（发送端即时显示/离线兜底，
            // 图片视频直接展示，老板 2026-09-11）
            await m.addColumn(localAttachments, localAttachments.localCipher);
          }
        },
      );

  static QueryExecutor _openConnection() => driftDatabase(
        name: 'einz',
        native: DriftNativeOptions(
          // 锁竞争容错（启动偶发 SqliteException(5) database is locked 根因）：
          // - journal_mode=WAL：读（SELECT）不再被写阻塞——"while selecting"
          //   锁错误来源消除；WAL 模式持久化在库文件头，每次连接再设一遍兜底
          // - busy_timeout=5000：写写竞争等待 5s 而非立即 SQLITE_BUSY（默认 0）
          // - synchronous=NORMAL：WAL 推荐档位（配 checkpoint 足够安全，写入更快）
          setup: (db) {
            db.execute('PRAGMA journal_mode = WAL');
            db.execute('PRAGMA busy_timeout = 5000');
            db.execute('PRAGMA synchronous = NORMAL');
          },
        ),
      );
}
