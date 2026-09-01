// CLI REST 客户端 —— 已上移至 shared 核心包（App 与 CLI 共用），此处仅 re-export。
//
// 迁移说明（Phase 3）：ApiClient 为纯 Dart + dart:io 实现，
// 从 cli 移入 shared/src/protocol/api_client.dart，由 einz_shared 导出。
export 'package:einz_shared/einz_shared.dart' show ApiClient;
