library;

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';

import 'dev_data_dir.dart';

/// Einz 客户端本地库（Local-First 主存储，DATABASE.md §3）。
///
/// - 消息密文与本地状态（pending/sent/...）
/// - 附件元数据（解密所需 nonce/sha256）
/// - 同步锚点（per-space last_server_sequence）
/// - 密钥不进 SQLite（Keychain/Keystore，见 DATABASE.md §4）

part 'local_database.g.dart';

/// per-space 设置键：`space.<spaceId>.<key>`（多空间：设置按空间隔离）。
///
/// 读取时回退同名旧全局键（v7 之前的设置没有空间维度），故存量用户的设置不会丢，
/// 见 `aimemo/multiSpaceDesign.zhcn.md` §3.6。
String spaceScopedKey(String spaceId, String key) => 'space.$spaceId.$key';

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
  // 该条焚毁是否由用户长按单条手动设置（false=来自全局设置快照）——仅手动设置的
  // 消息气泡才标注「设置/修改时间+时长」，全局设置的只标时长
  BoolColumn get burnManual => boolean().withDefault(const Constant(false))();
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
  /// 所属空间（多空间隔离用：删除空间/撤销设备时按 space 清理，见 v7 迁移回填）。
  TextColumn get spaceId => text().withDefault(const Constant(''))();
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

/// 对方消息回执（已送达/已读）单调高水位，按 (space, person) 一行。
///
/// 语义：我发的消息 seq=S 已送达 ⟺ 对方 `deliveredUptoSeq ≥ S`；已读 ⟺
/// `readUptoSeq ≥ S`。按 person 记 → "该 person 至少一台设备已收到/已读"。
/// 目前只落库供将来 UI 使用（本轮不显示）。
class PeerReceipts extends Table {
  TextColumn get spaceId => text()();
  TextColumn get personId => text()();
  IntColumn get deliveredUptoSeq => integer().withDefault(const Constant(0))();
  IntColumn get readUptoSeq => integer().withDefault(const Constant(0))();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {spaceId, personId};
}

/// 本地已加入的 Space（多空间支持，见 `aimemo/multiSpaceDesign.zhcn.md` §3.1）。
///
/// 定位是「**元数据 + 会话外状态**」：Space Key 只存在于 Vault（PIN 密文包 /
/// SecureStore 明文包），本表**不存任何密钥**——避免两处真相。
///
/// 行在解锁/读取到该空间凭证时补写（v7 迁移无法解密 PIN 包，故不在迁移里灌数据）。
class Spaces extends Table {
  TextColumn get spaceId => text()();
  TextColumn get name => text().withDefault(const Constant(''))(); // 我的显示名
  TextColumn get peerName => text().withDefault(const Constant(''))(); // 对端名
  TextColumn get personId => text().nullable()();
  TextColumn get deviceId => text().withDefault(const Constant(''))(); // 该空间的设备身份
  IntColumn get keyVersion => integer().withDefault(const Constant(1))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();
  IntColumn get lastActiveAt => integer().withDefault(const Constant(0))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {spaceId};
}

/// 本地应用状态（设置等）。
class AppState extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(
    tables: [LocalMessages, LocalAttachments, SyncState, Drafts, AppState, PeerReceipts, Spaces])
class LocalDatabase extends _$LocalDatabase {
  LocalDatabase() : super(_openConnection());

  /// 全 App 共享的单例连接：LocalDatabase() 是惰性打开，多处 new 会导致
  /// 同一 SQLite 文件被开多个连接（drift 警告 race condition，且从不关闭）。
  /// 调用点一律用 [shared]；测试用 [forTesting] 自带 executor，不受影响。
  static final LocalDatabase shared = LocalDatabase();

  LocalDatabase.forTesting(super.executor) : super();

  @override
  int get schemaVersion => 7;

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
          if (from < 5) {
            // v5：local_messages 加单条焚毁「是否手动设置」列（默认 false=全局设置）。
            // 仅手动设置的消息在气泡里标注「设置(修改)时间+时长」（老板 2026-09-12）
            await m.addColumn(localMessages, localMessages.burnManual);
          }
          if (from < 6) {
            // v6：新增 peer_receipts 表（对方已送达/已读高水位；本轮只落库不显示）
            await m.createTable(peerReceipts);
          }
          if (from < 7) {
            // v7：新增 spaces 表（多空间元数据）。**不灌数据**——PIN 模式下的旧
            // 锁包在迁移阶段无法解密，改由解锁/读到凭证时补写该行（幂等 upsert）。
            await m.createTable(spaces);
            // v7：local_attachments 加 spaceId（多空间隔离），按 messageId 从
            // local_messages 回填（存量库只有单空间，回填写得对；回填不到留空串）
            await m.addColumn(localAttachments, localAttachments.spaceId);
            await customStatement(
              'UPDATE local_attachments SET space_id = '
              'COALESCE((SELECT m.space_id FROM local_messages m '
              'WHERE m.message_id = local_attachments.message_id), \'\')',
            );
          }
        },
      );

  static QueryExecutor _openConnection() => driftDatabase(
        name: 'einz',
        native: DriftNativeOptions(
          // dev 运行（npm run desk-mac-run-local*）把库挪到 Documents/dev-*/ 下，
          // 与装机那份正式库互不干扰；不启用时传 null = 用 drift 默认
          // （getApplicationDocumentsDirectory()），生产路径一个字节都不动。
          databaseDirectory:
              devDataDirIsolated ? () => devSubDir(getApplicationDocumentsDirectory) : null,
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
