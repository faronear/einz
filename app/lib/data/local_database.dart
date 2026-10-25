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
/// 见 `aimemo/20260918_multiSpaceDesign.zhcn.md` §3.6。
String spaceScopedKey(String spaceId, String key) => 'space.$spaceId.$key';

/// 本地消息（与 Server messages 同构 + 本地状态）。
class LocalMessages extends Table {
  TextColumn get messageId => text()();
  TextColumn get spaceId => text()();
  TextColumn get senderEntranceId => text()();
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
  // 墓碑来路（2026-10-11）：'recall'=已撤回、'delete'=本机立刻删除；NULL=焚毁到期
  // （或 v10 之前打的墓碑）——气泡时间行据此显示撤回/删除图标，焚毁才显示沙漏+时长
  TextColumn get deletedKind => text().nullable()();

  @override
  Set<Column> get primaryKey => {messageId};
}

/// 本地附件元数据。
class LocalAttachments extends Table {
  TextColumn get attachmentId => text()();
  TextColumn get messageId => text().references(LocalMessages, #messageId)();
  /// 所属空间（多空间隔离用：删除空间/撤销通道时按 space 清理，见 v7 迁移回填）。
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

/// 对方消息回执（已送达/已读）单调高水位，按 (space, member) 一行。
///
/// 语义：我发的消息 seq=S 已送达 ⟺ 对方 `deliveredUptoSeq ≥ S`；已读 ⟺
/// `readUptoSeq ≥ S`。按 member 记 → "该 member 至少一条通道已收到/已读"。
/// 目前只落库供将来 UI 使用（本轮不显示）。
class PeerReceipts extends Table {
  TextColumn get spaceId => text()();
  TextColumn get memberId => text()();
  IntColumn get deliveredUptoSeq => integer().withDefault(const Constant(0))();
  IntColumn get readUptoSeq => integer().withDefault(const Constant(0))();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {spaceId, memberId};
}

/// 本地已加入的 Space（多空间支持，见 `aimemo/20260918_multiSpaceDesign.zhcn.md` §3.1）。
///
/// 定位是「**元数据 + 会话外状态**」：Space Key 只存在于 Vault（PIN 密文包 /
/// SecureStore 明文包），本表**不存任何密钥**——避免两处真相。
///
/// 行在解锁/读取到该空间凭证时补写（v7 迁移无法解密 PIN 包，故不在迁移里灌数据）。
class Spaces extends Table {
  TextColumn get spaceId => text()();
  TextColumn get name => text().withDefault(const Constant(''))(); // 我的显示名
  TextColumn get peerName => text().withDefault(const Constant(''))(); // 对端名
  TextColumn get memberId => text().nullable()();
  TextColumn get entranceId => text().withDefault(const Constant(''))(); // 该空间的通道身份
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

/// 语音消息本地转写（纯本地派生表，`aimemo/20261009_voiceTranscript.zhcn.md` §7）。
///
/// 定位是**可丢弃缓存**：转写文本 = f(明文音频, ASR 模型)，各端各自转写、
/// 不进 E2EE 密文、不参与同步、服务端不可见；换模型/换版本后可对同一音频重算。
/// 随消息**级联删除**（音频被焚毁/删除时转写必须同时消失）。
/// 不写进备份快照（能从密文音频重算，不把可能不准的文字固化进备份）。
class LocalVoiceTranscripts extends Table {
  TextColumn get messageId => text().references(LocalMessages, #messageId)();
  // 列名用 transcript（drift Table 基类已有 text() 方法，`text` 列名与之冲突）
  TextColumn get transcript => text().withDefault(const Constant(''))();
  TextColumn get modelId => text().withDefault(const Constant(''))(); // 如 sense-voice-small
  // 模型版本/文件哈希——与当前期望不一致 → stale（可重转的开关）
  TextColumn get modelVersion => text().withDefault(const Constant(''))();
  // 音频密文 sha256——音频若变化则转写失效（重发/换附件场景）
  TextColumn get audioSha256 => text().withDefault(const Constant(''))();
  TextColumn get language => text().withDefault(const Constant(''))(); // 识别到的语言
  // pending=排队中 | done=完成 | failed=失败(重试耗尽) | stale=模型/音频已变化 | unavailable=模型未就绪
  TextColumn get status => text().withDefault(const Constant('pending'))();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {messageId};
}

@DriftDatabase(tables: [
  LocalMessages,
  LocalAttachments,
  SyncState,
  Drafts,
  AppState,
  PeerReceipts,
  Spaces,
  LocalVoiceTranscripts,
])
class LocalDatabase extends _$LocalDatabase {
  LocalDatabase() : super(_openConnection());

  /// 全 App 共享的单例连接：LocalDatabase() 是惰性打开，多处 new 会导致
  /// 同一 SQLite 文件被开多个连接（drift 警告 race condition，且从不关闭）。
  /// 调用点一律用 [shared]；测试用 [forTesting] 自带 executor，不受影响。
  static final LocalDatabase shared = LocalDatabase();

  /// 测试用连接：executor 外包一层 [DatabaseConnection]（同 [_openConnection]），
  /// 保证测试与生产走同一条流store 语义（closeStreamsSynchronously 的缘由见
  /// [_openConnection] 注释）。
  LocalDatabase.forTesting(QueryExecutor executor)
      : super(DatabaseConnection(executor, closeStreamsSynchronously: true));

  @override
  int get schemaVersion => 12;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          // 幂等：某些历史/开发库的 `user_version` 会**落后于实际 schema**（例如
          // version 记 6 但已存在 v7 才引入的 `spaces` 表与 `local_attachments.space_id`）。
          // 直接 `ALTER TABLE ADD COLUMN` 会抛 "duplicate column name" → 迁移失败 →
          // 启动门重试耗尽 → "启动初始化失败"，且界面无出路。此处在每一步前先查
          // `PRAGMA table_info`，已存在就跳过（2026-09-24 iMac 生产库实测到该状态）。
          if (from < 2) {
            // v2：local_messages 加阅后即焚列（burn_after_seconds 默认 0、expires_at 可空）
            if (!await _hasColumn('local_messages', 'burn_after_seconds')) {
              await m.addColumn(localMessages, localMessages.burnAfterSeconds);
            }
            if (!await _hasColumn('local_messages', 'expires_at')) {
              await m.addColumn(localMessages, localMessages.expiresAt);
            }
          }
          if (from < 3) {
            // v3：local_messages 加本地墓碑列（deleted_at 可空）——删除/焚毁改为
            // 打标记（内容隐藏、记录保留），不再彻底删行（老板决策 2026-09-09）
            if (!await _hasColumn('local_messages', 'deleted_at')) {
              await m.addColumn(localMessages, localMessages.deletedAt);
            }
          }
          if (from < 4) {
            // v4：local_attachments 加本地密文副本列（发送端即时显示/离线兜底，
            // 图片视频直接展示，老板 2026-09-11）
            if (!await _hasColumn('local_attachments', 'local_cipher')) {
              await m.addColumn(localAttachments, localAttachments.localCipher);
            }
          }
          if (from < 5) {
            // v5：local_messages 加单条焚毁「是否手动设置」列（默认 false=全局设置）。
            // 仅手动设置的消息在气泡里标注「设置(修改)时间+时长」（老板 2026-09-12）
            if (!await _hasColumn('local_messages', 'burn_manual')) {
              await m.addColumn(localMessages, localMessages.burnManual);
            }
          }
          if (from < 6) {
            // v6：新增 peer_receipts 表（对方已送达/已读高水位；本轮只落库不显示）
            await m.createTable(peerReceipts); // CREATE TABLE IF NOT EXISTS
          }
          if (from < 7) {
            // v7：新增 spaces 表（多空间元数据）。**不灌数据**——PIN 模式下的旧
            // 锁包在迁移阶段无法解密，改由解锁/读到凭证时补写该行（幂等 upsert）。
            await m.createTable(spaces); // CREATE TABLE IF NOT EXISTS
            // v7：local_attachments 加 spaceId（多空间隔离），按 messageId 从
            // local_messages 回填（存量库只有单空间，回填写得对；回填不到留空串）
            if (!await _hasColumn('local_attachments', 'space_id')) {
              await m.addColumn(localAttachments, localAttachments.spaceId);
            }
            await customStatement(
              'UPDATE local_attachments SET space_id = '
              'COALESCE((SELECT m.space_id FROM local_messages m '
              'WHERE m.message_id = local_attachments.message_id), \'\')',
            );
          }
          if (from < 8) {
            // v8（历史，2026-09-23）：术语改名 device→entrance、person→partner。纯列改名，
            // 数据保留（ALTER TABLE RENAME COLUMN，SQLite ≥3.25）。身份列这里直接落到
            // **最终列名 member_id**——partner→member 已合入同一批（v9），无需两跳。
            // 逐列判存在：落后/超前库可能只有其中之一。
            if (await _hasColumn('local_messages', 'sender_device_id')) {
              await m.renameColumn(
                localMessages, 'sender_device_id', localMessages.senderEntranceId);
            }
            if (await _hasColumn('peer_receipts', 'person_id')) {
              await m.renameColumn(peerReceipts, 'person_id', peerReceipts.memberId);
            }
            if (await _hasColumn('spaces', 'person_id')) {
              await m.renameColumn(spaces, 'person_id', spaces.memberId);
            }
            if (await _hasColumn('spaces', 'device_id')) {
              await m.renameColumn(spaces, 'device_id', spaces.entranceId);
            }
          } else if (from < 9) {
            // v9（2026-09-24）：串术语改名 partner→member（列 partner_id→member_id）。
            // 只服务“已升到 v8（列名还是 partner_id）的存量库”；from<8 的库在上一分支
            // 已直接落到 member_id，故不重复改名。
            if (await _hasColumn('peer_receipts', 'partner_id')) {
              await m.renameColumn(peerReceipts, 'partner_id', peerReceipts.memberId);
            }
            if (await _hasColumn('spaces', 'partner_id')) {
              await m.renameColumn(spaces, 'partner_id', spaces.memberId);
            }
          }
          if (from < 10) {
            // v10（2026-10-11）：local_messages 加墓碑来路列（deleted_kind 可空，
            // NULL=焚毁到期/旧墓碑）——气泡时间行据 'recall'/'delete' 显示对应图标，
            // 不再与阅后即焚的沙漏+时长混淆（老板 2026-10-11）。
            if (!await _hasColumn('local_messages', 'deleted_kind')) {
              await m.addColumn(localMessages, localMessages.deletedKind);
            }
          }
          if (from < 11) {
            // v11（2026-10-22）：新增 local_voice_transcripts 表（语音消息本地转写，
            // 纯本地派生缓存——aimemo/20261009_voiceTranscript.zhcn.md §7）。纯新表，无回填。
            //
            // **必须占独立版本号**：v10 已随 main 发布过（墓碑来路列），本分支起初把
            // 新表塞进上面的 from<10 块——已升到 v10 的存量库（生产/dev 都是）再打开
            // 时 from==10，整段迁移根本不会跑，local_voice_transcripts 不存在，
            // 语音气泡下方的转写行（drift watch 流）直接报 "no such table"。
            await m.createTable(localVoiceTranscripts); // CREATE TABLE IF NOT EXISTS
          }
          if (from < 12) {
            // v12（2026-10-24）：转写设置 per-space 化的**存量数据善后**。
            //
            // 背景：2026-10-23 重构后 VoiceTranscriptSettings._ScopedKey.write 误写
            // 裸键（全局 voice_transcript_engine / voice_transcript_auto）而非
            // scopedKey——不勾「应用于本机所有秘境」的保存也污染了这两个全局键，
            // 所有空间读到时（per-space 缺失 → 回退全局）都生效（老板 2026-10-24
            // 实测）。代码已修（写 scopedKey）；本迁移处理已被写脏的存量库：
            // ① 把全局现值**认领**进每个空间的 per-space 键（INSERT OR IGNORE——
            //    已有 per-space 值的空间不动，那是 saveAll 清覆盖前的合法状态）；
            // ② 删除这两个全局键——不删的话此后新建/未配置空间仍会读到污染值。
            // 删后语义：每个空间各自独立（未配置走默认 local/手动），「所有秘境」
            // 仍可随时用勾选框重新铺（saveAll 写全局 + 清覆盖，与迁移前同款）。
            // 旧版单键 voice_transcript_auth（迁移派生源）不属这两键，不受影响。
            // 键名全是代码内常量（无注入面），与 v7 回填一样直接内联拼 SQL。
            //
            // app_state 表可能压根不存在（sqlite3 手工造的落后库：user_version=6
            // 却只有四张表——迁移测试第一个用例实测，2026-10-24）。没有设置表
            // 就没有污染可善后，整段跳过；不跳过的话 INSERT 抛 no such table,
            // 整个迁移失败、库再也打不开。
            final appStateExists =
                (await customSelect('PRAGMA table_info(app_state)').get())
                    .isNotEmpty;
            if (appStateExists) {
              for (final settingKey in const [
                'voice_transcript_engine',
                'voice_transcript_auto',
              ]) {
                await customStatement(
                  'INSERT OR IGNORE INTO app_state (key, value) '
                  "SELECT 'space.' || s.space_id || '.$settingKey', a.value "
                  "FROM spaces s, app_state a WHERE a.key = '$settingKey'",
                );
              }
              await customStatement(
                "DELETE FROM app_state WHERE key IN "
                "('voice_transcript_engine', 'voice_transcript_auto')",
              );
            }
          }
        },
      );

  /// 表 [table] 是否有列 [column]（迁移幂等用；表不存在时返回 false）。
  Future<bool> _hasColumn(String table, String column) async {
    final rows = await customSelect('PRAGMA table_info($table)').get();
    return rows.any((r) => r.read<String>('name') == column);
  }

  /// 连接外包 [DatabaseConnection] 并开 `closeStreamsSynchronously`：
  /// drift 的 select 流在**最后一个监听者取消**时，默认会起一个 `Timer.run`
  /// （把缓存流多留一个事件循环迭代，给同一帧内重新订阅的 StreamBuilder 复用）。
  /// 该定时器在 flutter_test 的 FakeAsync 里没人推进时钟 → 永不触发：
  ///   1. 测试卸载 widget 树时 `timersPending` 断言炸（"A Timer is still
  ///      pending even after the widget tree was disposed."）；
  ///   2. `db.close()` 里 StreamQueryStore.close() 会 await 这个永不完成的
  ///      timer completer → 整个测试吊死到 10 分钟超时。
  /// 2026-10-22 语音转写行的 drift 流（_buildVoiceTranscriptLine）首次把流
  /// 带进 widget 树，两个症状同时踩到（chat_page_menu_test 实测）。
  /// 全 App 仅此一处 drift 流，同步回收缓存无感知；测试与生产同一语义。
  static QueryExecutor _openConnection() => DatabaseConnection(
        driftDatabase(
          name: 'einz',
          native: DriftNativeOptions(
            // dev 运行（npm run app-mac-run-local*）把库挪到 Documents/dev-*/ 下，
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
        ),
        closeStreamsSynchronously: true,
      );
}
