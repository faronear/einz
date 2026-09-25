import 'l10n/app_localizations.dart';

/// 错误文案的**分类前缀**：把"这条错误是谁说的"写进文案里。
///
/// 两类错误的判定口径（老板 2026-09-25 定）：
/// - **后台**：服务端响应构造出的 `ApiException`（含 `HTTP_<status>` 兜底码），
///   以及由它的错误码映射出来的文案 → 一律经 [backendError] 加「后台：」前缀；
/// - **本机**：本地校验、本地状态、密钥/PIN/加密等客户端判定 → **不加前缀**，保持原文案。
///
/// 于是"带「后台：」"＝服务端说的，"不带"＝本机判的：用户和排障的人都一眼能分。
///
/// 为什么值得多这几个字（2026-09-25 的教训）：同一句"这个秘境已经添加过了"既可能
/// 来自本机闸门（`setup_page._isSpaceAlreadyAdded` 查本地库），也可能来自服务端
/// `ENTRANCE_ALREADY_EXISTS`——两者处置完全不同（前者清本地残档，后者要先退役旧通道），
/// 文案却一字不差，白白多绕一轮排查。
///
/// 用法：全仓库搜 `backendError(` 即得后台错误的完整清单（新增后台分支时照此办理）。
String backendError(AppLocalizations l10n, String message) =>
    l10n.errorBackend(message);
