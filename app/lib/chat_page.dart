import 'dart:async';
import 'widgets/menu_metrics.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'widgets/linkified_text.dart';
import 'package:image_picker/image_picker.dart';
import 'package:einz_shared/einz_shared.dart';
import 'package:open_filex/open_filex.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:record/record.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import 'widgets/about_sheet.dart';
import 'widgets/cancel_button.dart';
import 'brand_logo.dart';
import 'widgets/burn_duration_sheet.dart';
import 'widgets/version_gate.dart';
import 'data/attachment_storage_settings.dart';
import 'data/tombstone_settings.dart';
import 'data/attachment_store.dart';
import 'data/burn_after_settings.dart';
import 'data/app_lock.dart';
import 'data/local_database.dart';
import 'data/server_config.dart';
import 'error_text.dart';
import 'data/locale_settings.dart';
import 'data/lock_timer.dart';
import 'data/media_cache.dart';
import 'data/media_saver.dart';
import 'data/message_repository.dart';
import 'data/space_session.dart';
import 'data/ui_style_settings.dart';
import 'data/ws_realtime_service.dart';
import 'data/voice_call_service.dart';
import 'l10n/app_localizations.dart';
import 'lock_page.dart';
import 'setup_page.dart';
import 'voice_call_sheet.dart';
import 'widgets/reset_entrance.dart';
import 'widgets/space_switcher.dart';
import 'widgets/scrollable_card_area.dart';
import 'data/vault_session.dart';
import 'widgets/emoji_panel.dart';
import 'widgets/immersive_fullscreen.dart';
import 'widgets/passphrase_field.dart';
import 'widgets/option_picker_sheet.dart';
import 'widgets/labeled_checkbox.dart';
import 'widgets/top_notice.dart';
import 'widgets/ui_style_picker.dart';
import 'widgets/clickable.dart';

/// 选择弹层返回项：图像/视频用 image_picker，音频/文件用 file_picker；emoji 不
/// 上传附件，只打开输入栏内的表情面板（在 _showAttachmentSheet 里单独分流）。
enum _AttachmentKind { emoji, paste, photo, galleryImage, videoCamera, videoGallery, audioFile, anyFile }

/// 本平台是否具备**相机采集**能力（拍照/拍摄）。
///
/// 桌面端（macOS/Windows/Linux）没有：`image_picker` 在桌面平台遇到
/// `ImageSource.camera` 会直接抛 `StateError`（除非挂 cameraDelegate），所以附件
/// 面板在桌面端不摆「拍照/拍摄」两个入口——摆了也只会弹一条"发送失败"
/// （老板 2026-09-20 在 MacBook 实测：点拍视频报错）。相册/文件入口在桌面端走
/// 系统文件对话框，照常可用。
bool get _hasCameraCapture =>
    !kIsWeb && (Platform.isAndroid || Platform.isIOS);

/// 本平台是否能从系统拖文件进来（仅桌面）。移动端无此交互，且 desktop_drop 的
/// Android 实现还是 preview，不挂上去更稳。
bool get _fileDropSupported =>
    !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

/// 本平台是否支持「剪贴板粘贴」能力（附件面板的「粘贴」入口 + 读取逻辑）。
/// **全平台**（老板 2026-10-12：桌面端经附件面板同样可用，移动端经同一入口）：
/// 走 `pasteboard` 插件——iOS/macOS 零配置，Android 只读剪贴板也不需要
/// FileProvider（那只在 writeImage 时才用，我们从不写剪贴板）。
bool get _clipboardPasteSupported =>
    !kIsWeb &&
    (Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isMacOS ||
        Platform.isWindows ||
        Platform.isLinux);

/// 桌面端专属：Cmd/Ctrl+V 快捷键 + 配套的输入框 autofocus / onTapOutside
/// 行为调整（焦点链实测定的，见 build 里 CallbackShortcuts 注释）。
/// 移动端没有键盘快捷键这一说，入口走附件面板。
bool get _pasteShortcutSupported =>
    !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

/// 剪贴板**文件**分支仅桌面：插件在 Android 返回的是 content:// URI
/// （dart:io 读不了，要 content resolver——v1 不碰原生），iOS 侧恒返回空；
/// 桌面两端（macOS 路径 / Windows 临时文件中转）都是可直接读的路径。
bool get _pasteboardFilesSupported =>
    !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

/// 拖入文件的类型归类（扩展名 → 附件类型）。桌面拖放与相册/文件对话框各入口
/// 共用同一个发送收口（`_ChatPageState._sendAttachmentOptimistic`）。
const Set<String> _kDropImageExts = {
  'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'tif', 'tiff', 'avif',
};
const Set<String> _kDropVideoExts = {
  'mp4', 'mov', 'm4v', 'avi', 'mkv', 'webm', 'wmv', 'flv', 'mpeg', 'mpg', '3gp', 'ts',
};
const Set<String> _kDropAudioExts = {
  'mp3', 'm4a', 'aac', 'wav', 'flac', 'ogg', 'opus', 'wma', 'amr', 'aiff', 'aif', 'caf',
};

/// 扩展名 → 附件类型：命中 image/video/audio 之一，其余归 'file'（与 `_sendMedia`
/// 的 file_picker 分支同口径）。无法解码/伪装的扩展名 v1 不嗅探内容，按名归类。
String _dropAttachmentType(String fileName) {
  final dot = fileName.lastIndexOf('.');
  final ext = (dot >= 0 && dot < fileName.length - 1)
      ? fileName.substring(dot + 1).toLowerCase()
      : '';
  if (_kDropImageExts.contains(ext)) return 'image';
  if (_kDropVideoExts.contains(ext)) return 'video';
  if (_kDropAudioExts.contains(ext)) return 'audio';
  return 'file';
}

/// 剪贴板给的"文件路径"是否是**本地真实存在的普通文件**（老板 2026-10-12）：
/// 浏览器拷图有时会连带一个 http URL，插件取 `url.path` 得到个不存在的本地
/// 路径（如 `/images/foo.png`）——那种必须落空，让粘贴回落到图片数据分支，
/// 否则 statSync 抛错、用户看到"发送失败"。
bool _isLocalReadableFile(String path) {
  if (path.isEmpty) return false;
  try {
    return FileStat.statSync(path).type == FileSystemEntityType.file;
  } catch (_) {
    return false;
  }
}

/// 输入区模式：text=文字输入框；hint=提示态（录音条显示「长按开始录音」，入口按钮变键盘、
/// 点击回文字态）；recording=按住录音中（波形实时）；preview=松手后预览态（试听/取消，
/// 发送复用右侧发送键）。
enum _InputMode { text, hint, recording, preview }

/// 「通道列表」卡片间距（一卡占满整行后只剩纵向间距，老板 2026-10-11）。
const double _entranceCardSpacing = 12;

/// 气泡时间行里各小控件的**统一高度**（老板 2026-10-08）：引用/拷贝/保存的圆钮，
/// 以及「沙漏+时长」胶囊——三者的背景高度必须一样（此前沙漏那块的文字把胶囊撑得
/// 比圆钮高一截）。28 = 16 图标 + 上下各 6（2026-10-09 老板要求加大：原 20×20
/// 热区远小于 44pt 最小触控标准，手机难点中；气泡约增高 8px）。
const double _bubbleTimeRowControlHeight = 28;

/// 「我的通道」弹层标题行右端「刷新」按钮的占位/按钮边长（标题居中靠它配平）。
const double _entranceRefreshSize = 40;

/// 「我的资料」弹层的最大宽度（老板 2026-10-17）：BottomSheet 默认铺满窗口，
/// 桌面端宽屏下这张身份卡会被拉成一条空旷的长带——限到 480 后居中停在窗口底部，
/// 手机端本就比它窄，不受影响。
const double kMyProfileSheetMaxWidth = 480;

/// 聊天页：本地历史 + 发送 + 自动轮询同步（最小可用，无 WS 长连接）。
class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.spaceId,
    required this.entranceId,
    required this.spaceKey,
    required this.keyVersion,
    required this.token,
    this.db,
    this.api,
    this.enableWs = true,
    this.reauth,
    this.escrowUpdatedAt,
    this.memberName, // 我的名字（登记时设置；菜单显示/修改）
    this.entranceName, // 我的通道名（登记时自动获取；菜单显示/修改）
    this.memberId, // 我的 memberId（头像上传/获取用）
    this.peerName, // 对方名字（setup 探测传入；对话顶部条显示）
    this.publicKeyB64, // 通道公钥（b64，随锁包持久化；弹窗展示用）
    this.privateKeyB64, // 通道私钥（b64，随锁包持久化；补设锁写入新锁包）
    this.isDemo = false, // 演示秘境（DemoSpace）：全离线，不触网、不起任何轮询
  });

  final String spaceId;
  final String entranceId;
  final Uint8List spaceKey;
  final int keyVersion;
  final String token;

  /// 本端已知的服务端口令更新时间（ms）：启动/上线时与服务器对比，
  /// 服务器更新 = 离线期间口令被重设（只发通知，不弹窗）。
  final int? escrowUpdatedAt;

  /// 我的名字（向导登记时设置；顶栏菜单显示/修改，服务端同步）。
  final String? memberName;

  /// 我的通道名（向导登记时自动获取设备型号；顶栏菜单显示/修改，服务端同步）。
  final String? entranceName;

  /// 我的 memberId（向导登记时确定；头像上传/消息身份标识用）。
  final String? memberId;

  /// 对方名字（向导探测时确定；对话顶部条显示，无则占位）。
  final String? peerName;

  /// 通道 X25519 公钥（b64，随锁包持久化）：「我的通道」弹窗展示用。
  final String? publicKeyB64;

  /// 通道 X25519 私钥（b64，随锁包持久化）：补设锁/改口令时写入新锁包。
  final String? privateKeyB64;

  /// 演示秘境模式（2026-10-19，App Store 审核演示通道方案 A）：空间由
  /// DemoSpace 本地生成、不入 Vault。聊天页一切需要服务器的路径（同步轮询、
  /// WS、在线状态、资料校正、推送注册、其它空间未读）全部不启动；
  /// 发送只落本地并立即标已读（见 MessageRepository.isDemo）。
  final bool isDemo;

  /// 测试注入用；默认新建（生产路径）。
  final LocalDatabase? db;

  /// 测试注入用（fake api）；默认按 [effectiveServer] 新建（生产路径）。
  final ApiClient? api;

  /// WS 实时开关（测试环境关闭，避免真实连接与重连 Timer）。
  final bool enableWs;

  /// session 过期（401/4401）时自动重新认证的回调（setup_page 注入，
  /// challenge-response 重新签发 token）——MessageRepository/WsRealtimeService 共用。
  final Future<String> Function()? reauth;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

/// 消息流正文（气泡内跟随默认样式的文字）字号（老板 2026-09-25 定：16）。
/// 演变：原样跟 Flutter 默认 14（比微信小一圈）→ 2026-09-15 取中间值 15 →
/// 2026-09-25 老板看 15 仍偏小，定 16。
/// 只作用于气泡内跟随默认样式的文字——时间戳/焚毁标签/引用块/长按预览行都显式
/// 设了字号，不受影响。
const double kMessageFontSize = 16;

/// **引用里**图片/视频缩略图的边长：输入栏引用条与气泡里的引用块**同尺寸**
/// （老板 2026-09-27：引用条里已经不显示文件名了，有的是空间，放大到和引用块一样）。
/// 改这里两处一起变——此前引用条 24、引用块 40，两处各写各的。
const double kQuoteThumbSize = 40;

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {

  late final MessageRepository _repo;

  /// 本空间的会话（**本页唯一权威 token**）：所有带鉴权的请求都走 `_withAuth`，
  /// 由它保证"401 → 续期 → 重试"。别再直接把 `widget.token` 塞给 ApiClient——
  /// 那是构造时的死副本，24h 后必 401（2026-09-26 老板线上实测的头像上传 bug）。
  late final SpaceSession _session;
  final _input = TextEditingController();
  final _inputFocusNode = FocusNode(); // 回车发送后重新聚焦（与图标发送一致保持焦点）
  final _lockTimer = LockTimer();
  // —— 锁屏（前台无操作 + 后台超时，共用一个用户可调阈值）——
  // 阈值默认 kLockSeconds；initState 异步读用户自选值（AppLockService.loadLockSeconds，
  // 「设置锁屏码」弹窗的滚动轴写入）后回填 _lockSeconds / _lockTimer 并重排。
  int _lockSeconds = kLockSeconds;
  // 前台无操作锁屏：超过阈值没任何交互（点/滑/滚/打字）也进锁屏。
  // 一次性 Timer：每次交互 cancel+重排到"现在+阈值"；空闲时 Timer 睡着零唤醒，
  // 且用 Dart 逻辑时钟，widget 测试可 tester.pump(30s) 推进（无需 runAsync 实睡）。
  // 「聊天页在栈顶」用 ModalRoute.isCurrent 判（真实路由状态），**不用** FocusNode
  // hasFocus——后者只在焦点链经过本子树时为 true，手机上无输入焦点时恒 false，
  // 会漏锁。到点若被弹层/锁屏盖着：不硬锁，重排一个新窗口（关掉弹层后最多
  // 30s 内必锁，安全方向不变）。锁屏页 pop 回聊天（Future 完成）重排新窗口。
  Timer? _idleTimer; // 一次性：每次交互重排到"现在+kLockSeconds"，空闲时睡着零唤醒
  bool _lockOverlayShown = false; // 锁屏覆盖页是否已 push（防重复 push 竞态）
  // 插件懒构造：AudioRecorder()/AudioPlayer() 构造即触发原生平台通道，
  // 仅在实际录音/播放时才实例化（widget 测试环境无原生实现，渲染路径不触碰）。
  AudioRecorder? _recorder;
  AudioPlayer? _player;
  final _picker = ImagePicker();
  // 图片解密缓存（messageId → Future<bytes>），避免重复下载解密。
  final Map<String, Future<Uint8List>> _imageCache = {};
  // 视频解密缓存（messageId → Future<bytes>），内联预览用（避免重复解密）。
  final Map<String, Future<Uint8List>> _videoCache = {};
  // 视频首帧缩略图缓存（messageId → Future<bytes>）：长按菜单/引用块/引用条共用。
  final Map<String, Future<Uint8List>> _videoThumbCache = {};
  List<HistoryMessage> _messages = [];

  /// 消息流**显示**用的列表：[_tombstoneDisplay] = 'hide'（彻底隐藏）时滤掉
  /// 墓碑（已删除/已焚毁）行——它们整条不显示；'keep'（保留消息状态，默认）
  /// 时原样返回。数据层的 [_messages] 不动（墓碑行仍是 recall/跳转/在途补发
  /// 的判断依据），只影响 ListView 的渲染。
  List<HistoryMessage> get _displayMessages =>
      _tombstoneDisplay == 'hide'
          ? [for (final m in _messages) if (!m.deleted) m]
          : _messages;

  Timer? _ticker;
  // 分页加载（UI 懒渲染）：上滑到顶部加载更早历史；ticker 只增量追加新增
  final ScrollController _scrollController = ScrollController();
  // 上一次滚动时列表是否贴底：`_onScrollForRead` 用它取"离开底部→回到贴底"的跨越沿
  bool _lastScrollAtBottom = false;
  bool _hasMoreOlder = true;
  bool _loadingOlder = false;
  // 首屏本地历史是否已上屏（用于守卫 _refreshLocal：未加载时 _lastLoadedSequence=0
  // 会触发全量解密）
  bool _initialLoaded = false;
  static const int _pageSize = 50;
  // ---- 回执上报（已送达/已读；本轮只打通数据链路，不显示）----
  int _lastReportedDeliveredSeq = 0; // 防抖：已上报过的送达高水位
  int _lastReportedReadSeq = 0; // 防抖：已上报过的已读高水位
  bool _appResumed = true; // 前台才允许把消息标为已读
  /// 对方回执（已送达/已读）本地缓存：渲染自己消息的状态标用（避免每条消息查库）。
  List<PeerReceipt> _peerReceipts = const [];

  /// 正在"点按重发"的消息：messageId → 'speedup'（点的是小飞机）/ 'resend'
  /// （点的是 failed）。点按期间在图标前显示「加速中…」/「重发中…」，完成或
  /// 再次失败后清掉（老板 2026-09-13）。
  final Map<String, String> _retrying = {};

  /// 还没确认（pending）的消息数：离线提示用（老板 2026-09-13）。
  int _unsentCount = 0;

  /// 连续同步失败次数：驱动 ticker 退避 + 离线提示。
  /// 远端不可达（丢包黑洞）时单轮 refresh 可能耗 3×连接超时(10s)≈30s，
  /// 若仍每 3s 发一轮会并发堆积 → 必须重入保护 + 退避。
  int _consecutiveSyncFailures = 0;

  /// 附件元数据自愈（2026-10-09）：sync 竞态下个别消息的附件行被永久漏拉
  /// （服务端后建附件行、anchor 已越过消息 seq）。`_healAttachments` 每轮
  /// sync 后补拉缺附件的媒体消息。[kHealAttachmentMaxRetries] 次失败（网络抖动
  /// 累计）后放弃该条；404（服务端**确认**没有，如超大附件被拒的孤儿）立即放弃。
  static const int _kHealAttachmentMaxRetries = 5;

  /// 每条消息的自愈尝试计数：网络失败 +1；404 直接置满（确定结论，别再问）。
  final Map<String, int> _healAttempts = {};

  /// 服务端**确认**无附件（自愈补拉 404）的消息 id：孤儿消息（超大附件被拒/
  /// 发送失败）重试永远无效，UI 据此去掉「点按重试」邀请（老板 2026-10-10）。
  /// 内存 Set 即可——重启后自愈首轮再 404 会重新标上。
  final Set<String> _healConfirmedMissing = {};

  /// 自愈重入保护：ticker 每 3s 一次 unawaited，单条补拉慢（弱网）时会叠轮。
  bool _healInFlight = false;

  /// 自愈一批缺附件的媒体消息（每轮 sync 后调用）。修好的触发一次刷新。
  Future<void> _healAttachments() async {
    if (_healInFlight || _wiped || _repo.token == null) return;
    final missing = [
      for (final m in _messages)
        if (!m.deleted &&
            m.attachment == null &&
            // 只补"服务端已收下"的：自己发的 pending/failed（seq=null）本地必有
            // 附件行，缺了是别的问题，补拉也问不到
            m.env.serverSequence != null &&
            (_healAttempts[m.env.messageId] ?? 0) < _kHealAttachmentMaxRetries &&
            _isMediaLike(m.env.type))
          m,
    ];
    if (missing.isEmpty) return;
    _healInFlight = true;
    try {
      var fixed = false;
      for (final m in missing) {
        try {
          if (await _repo.healAttachmentMeta(m)) {
            fixed = true; // 补到了；计数清零不再动它
          } else {
            // 404：服务端确认没有 → 立即放弃这条（置满计数），继续修其它；
            // 同时打上「确认缺失」标（UI 去掉「点按重试」邀请）
            _healAttempts[m.env.messageId] = _kHealAttachmentMaxRetries;
            _healConfirmedMissing.add(m.env.messageId);
            if (mounted) setState(() {});
          }
        } on Exception {
          // 网络/认证抖动：计数+1，留给下轮（到上限自然放弃）
          _healAttempts[m.env.messageId] =
              (_healAttempts[m.env.messageId] ?? 0) + 1;
        }
      }
      if (fixed && mounted) await _refreshLocal();
    } finally {
      _healInFlight = false;
    }
  }

  /// 媒体类消息（缺附件元数据时才有自愈意义；文本/系统消息本就无附件）。
  bool _isMediaLike(String type) =>
      type == 'image' || type == 'video' || type == 'audio' || type == 'file';

  /// 服务器不认这条通道（认证 403 `FORBIDDEN`：后台库被重置 / 本通道未登记）。
  /// **只警告，绝不销毁本地数据**（老板 2026-09-16：运维失误不该导致客户端抹数据）——
  /// 与"通道被明确撤销"（403 `ENTRANCE_REVOKED` / `entrance.revoked` 帧）严格区分：
  /// 只有后者才自毁。库复原后同步成功即自动复位。
  bool _entranceUnrecognized = false;

  /// 已执行过撤销自毁：短路后续网络与重入（`entrance.revoked` 帧与重认证可能同时触发）。
  bool _wiped = false;

  /// ticker 轮询的"上一轮是否还在跑"（重入保护：避免离线时并发堆积）。
  bool _tickerRefreshInFlight = false;

  /// 上一轮 ticker 刷新的开始时刻（配合 [_tickerRefreshInFlight] 做卡死兜底）。
  DateTime? _tickerRefreshStartedAt;

  /// 当前 ticker 周期（用于判断是否需要按退避重设）。
  Duration? _currentTickerInterval;
  _InputMode _inputMode = _InputMode.text; // 输入区模式（文字/提示/录音中/预览）
  // 表情面板展开中（输入栏内联，与键盘互斥：打开时收起键盘；输入框重新获焦时自动收起）
  bool _emojiPanelOpen = false;
  // 桌面端拖入文件的高亮浮层开关（desktop_drop 的 onDragEntered/Exited 驱动）
  bool _fileDragHover = false;
  String? _recordingPath; // 本次录音临时文件（录音中/预览态存续，发送或取消后清空）
  final List<double> _voiceSamples = []; // 本次录音振幅采样（录音中实时追加，预览态冻结）
  StreamSubscription<Amplitude>? _ampSub; // 录音振幅流订阅（波形驱动）
  Timer? _recordTimer; // 录音秒数计时（60s 上限自动停）
  // 首次录音会先弹 macOS/Android 授权框：hasPermission() 等待期间用户早已松手
  // （onLongPressEnd 先于授权回调触发），授权成功后 recorder.start() 才真正开录，
  // 此后再松手没人会去停它——只能等 60s 上限自动停。用该标记让 _stopVoice 在
  // 「还没进录音态但正在启动」时也能执行取消，而不是被 inputMode 检查直接放过。
  bool _voiceStarting = false;
  int _recordSeconds = 0;
  bool _previewPlaying = false; // 预览态试听播放中
  String? _playingMessageId; // 播放意图（点按即置：含下载解密等待期，按钮变停止）
  String? _audioStartedMessageId; // 音频真正出声的消息（波形进度从此刻起走，
  // 避免下载解密期间进度条空跑——老板要求 2026-09-13）
  // 音频文件时长（messageId → 秒）：播放时从播放器取真实值缓存，仅内存
  // ——发送端探测不到（老消息无标注）时，播放一次后才显示时长
  final Map<String, int> _audioFileDurations = {};
  // 音频播放状态版本号：每变一次 +1。消息流气泡在本页 build 树里（setState 即可），
  // 但长按菜单预览行在另一个路由，页面 setState 重建不到它，靠这个通知同步
  // （老板要求 2026-09-13：菜单里也能播/停并看到波形进度）。
  final ValueNotifier<int> _audioPlaybackVersion = ValueNotifier(0);
  int _burnSeconds = 0; // 当前阅后即焚秒数（0=无限；显示经 l10n 映射）
  /// 墓碑消息显示模式（'keep'=保留消息状态 / 'hide'=彻底隐藏；默认 keep）。
  /// 只影响消息流里墓碑（已删除/已焚毁）的呈现，数据行为不变。
  String _tombstoneDisplay = 'keep';
  HistoryMessage? _quoteTarget; // 长按「引用」选中的原消息（输入栏引用条 + 发送携带）
  // 点击引用卡跳转定位：目标消息的 GlobalKey（仅目标项持有，避免全列表 key
  // 阻碍懒回收）+ 目标 messageId（itemBuilder 按需挂 key）
  final GlobalKey _jumpTargetKey = GlobalKey();
  String? _jumpTargetId;
  // 跳转后目标消息短暂高亮背景（显眼橘黄 #FF9800，2s 后恢复原色）：
  // messageId + 定时清除（只换背景色、尺寸不变——边框方案实测闪烁期间
  // 气泡尺寸变化已弃用，老板要求 2026-09-10）
  String? _highlightMessageId;
  Timer? _highlightTimer;
  late String _uiStyle; // 当前界面主题（'plain'=素雅纯色 / 'gradient'=渐变粉蓝）

  /// 当前附件存储模式：'secured'=不留存明文（默认）/ 'stored'=明文留在本机、直接打开。
  late String _attachmentStorage;
  bool _hasPin = false; // 本机是否已设置启动锁（菜单项「PIN: 已设置/未设置」）
  /// 邮件通知状态（菜单项右侧值 + 弹窗内容）。null = 还没拉到/离线拉不到→菜单只显示标签，
  /// 不猜状态（猜错比不显示更糟：他会以为已经开了）。
  NotifyEmailStatus? _notifyEmail;
  /// 只在"待确认"期间跑的轮询（20s）：确认是**在 App 外面点邮件链接**完成的，服务端
  /// 没有任何通道能通知 App 它翻转了——不轮询的话只有重启才能看到（老板 2026-10-01 实测）。
  Timer? _notifyTicker;
  WsRealtimeService? _ws; // WS 实时（收到 message.new 立即刷新；断线自动重连）
  VoiceCallService? _voiceCall; // 语音通话（前台通话；信令走 WS，PROTOCOL.md §8.4）
  late String _myMemberName; // 我的名字（菜单显示；改名后 setState 刷新）
  late String _myEntranceName; // 我的通道名（菜单显示；改名后 setState 刷新）
  /// 本机 App 版本号（`yymm.ddhh.mm`；_registerClientInfo 启动时读一次）——
  /// 「我的设备通道」本机卡片的版本段用。读不到（包信息不可用）为空串 →
  /// 不显示该段。**不在弹层里现读**：PackageInfo 是平台调用，测试环境无 mock
  /// 时 future 永不完成，会把弹层的打开整个卡死（2026-10-14 回归教训）。
  String _myAppVersion = '';
  late String _myGender; // 我的性别（male/female/''；profile 恢复，个人资料弹窗图标展示）
  late String _peerGender; // 对方性别（male/female/''；profile 恢复，消息气泡配色用）
  int? _mySlot; // 我的身份槽位（0=第一人/创建者，1=第二人；同性别气泡青色判定用）
  int? _peerSlot; // 对方身份槽位（同上）
  Uint8List? _myAvatarBytes; // 我的头像 bytes 缓存（菜单显示；上传后刷新）
  /// 我的 memberId（头像上传/缓存失效/归属判定用）：向导路径由 widget 传入；
  /// 重启（PIN 解锁/明文直进）路径 widget.memberId 为空 → 运行时反查补齐
  /// （见 [_loadMyAvatar] / [_refreshProfileFromServer]）。
  String? _myMemberId;
  late String _peerName; // 对方名字（对话顶部条显示）
  bool _peerOnline = false; // 对方在线状态（last_seen 距今 <60s）
  String? _peerMemberId; // 对方 memberId（状态条头像用；来自 /space 成员表）
  Uint8List? _peerAvatarBytes; // 对方头像 bytes（状态条显示；拿不到就默认人形）
  /// 状态条要显示的「上线 / 下线时刻」（ms；null = 还不知道，不显示）：
  /// 对方与我方各一份，口径与「更多通道」卡片一致（见 [_sinceOfRow]）。
  int? _peerSinceMs;
  int? _mySinceMs;
  /// 我的通道总数（含本机这条，按 member 维度）：通道轮询（_refreshPeerOnline）
  /// 顺带维护，汉堡菜单「更多通道」项的 devices 图标旁显示（老板 2026-09-28）。
  /// null = 还没拉到（离线/未轮询过），菜单里就不显示数字。
  int? _myEntranceCount;

  /// 群聊一期（2026-10-03）：
  /// 本空间**全部成员**：member_id → 槽位（/space 的 member_slots——含还没设置
  /// 名字的成员；member_names 只收有名字的，不能拿来数人头）。槽位用于按加入
  /// 顺序列名单。
  final Map<String, int> _memberSlots = {};
  /// member_id → 显示名（/space 的 member_names；群空间里逐条消息标注"谁说的"）。
  final Map<String, String> _memberNames = {};
  /// member_id → 性别（/space 的 member_genders；成员弹层的卡片底色按它取色，
  /// 未知性别的成员退成中性灰）。
  final Map<String, String> _memberGenders = {};
  /// member_id → 成员状态（/space 的 member_status，2026-10-19 自愿退群配套）：
  /// 'active' | 'left'（墓碑）。**名字解析用全量**（墓碑保名，历史消息的
  /// "谁说的"不丢）；**名单/计数/邀请判定只数 active**（aimemo/groupExitDesign.md
  /// §4.2 三分口径）。老服务端不下发 → 空表 → 全部按 active（没有墓碑）。
  final Map<String, String> _memberStatus = {};
  /// 空间模式（'duo' | 'group'，/space 下发）。**不靠"成员数 ≥3"猜**——duo 满员
  /// 签发 invite 后、第三人还没加入时 mode 已经是 group（那时就得停用通话了）。
  String _spaceMode = 'duo';
  /// 本服务器单空间成员上限（/space 下发；0=不限）。满员时隐藏邀请入口用。
  int _maxMembers = 0;

  /// **群组名字**（群空间状态条第一行；老板 2026-10-09）。
  ///
  /// **仅本机存储**（per-space 资料里的 `groupName`，不跨成员同步）：服务端没有
  /// 空间名字段（`spaces.display_name` 早已删除）。空串 = 还没起名 → 状态条第一行
  /// 只显示一个编辑图标。
  String _groupName = '';

  /// 群聊判定：直接读服务端下发的 mode（不靠"成员数 ≥3"猜——duo 满员后签发
  /// invite 的那一刻就已升格，此时第三人还没进来，但通话必须立刻停用）。
  bool get _isGroup => _spaceMode == 'group';

  /// 本空间成员数（身份数，同身份多通道只算一个）——**只数 active**（自愿退群
  /// 2026-10-19：墓碑成员不占名额、不再收通知，服务端同口径）。
  int get _memberCount => _activeMembers.length;

  /// 在册成员（member_id → 槽位，**不含墓碑**）：名单/计数/邀请判定都用它。
  /// `_memberSlots` 是全量（含墓碑，供 slot 反查与历史归属），名字解析走
  /// `_memberNames`（同样全量）——两边刻意不分母，见 [_memberStatus] 注释。
  Iterable<MapEntry<String, int>> get _activeMembers => _memberSlots.entries
      .where((e) => _memberStatus[e.key] != 'left');

  /// 群空间状态条要显示的「**其他人在线数**」（**不含我自己**）：由通道轮询
  /// [\_refreshPeerOnline] 维护——在线按 **member** 去重（同一 member 有任一条通道
  /// 在线就算他在线）。老板 2026-10-05：显示在成员头像条右侧。
  int _othersOnline = 0;

  /// 同上，**其他人总数**（不含我自己）：以 /space 的成员表为准（`_memberCount - 1`），
  /// 拿不到时退回通道表里出现过的 member 数（见轮询里的 `max` 说明）。
  int _othersTotal = 0;

  /// **至少有一条通道在线**的其他成员（member_id 集合，不含我自己）。
  ///
  /// 头像条据此把在线的人**套一圈绿环**（老板 2026-10-05：要与不在线的区分开）。
  /// 口径与 [_othersOnline] 同一份计算——在线是**人**的维度（同一 member 有任一条
  /// 通道在线就算他在线），所以这里存的是去重后的 member_id。
  Set<String> _onlineOthers = <String>{};

  /// 每个其他成员**最近一次状态变化的时刻**（ms，不含我自己）：头像条排序用
  /// （老板 2026-10-06：最新上线的排最前，下线的沉底）。在线成员取"上线时刻"
  /// （`_sinceOfRow(online:true)`，即已连了多久），离线成员取"下线时刻"。
  /// 同一 member 多条通道取**最大值**（最近的那条）。由通道轮询维护。
  final Map<String, int> _otherSinceMs = {};

  /// 还能不能再邀请新成员（2026-10-04：mode 创建时定死，没有升格）：
  /// - duo：**只在还没第二个人时**能邀请（那是"邀请伴侣"）；满 2 人即永久关闭
  ///   ——第三个人不是"满了"，是双人秘境不允许；
  /// - group：未达服务端 maxMembersPerSpace（0=不限）。
  bool get _canInvite => _isGroup
      ? (_maxMembers <= 0 || _memberCount < _maxMembers)
      : _memberCount < 2;

  /// 是否在气泡旁显示发送者头像：group 默认开、duo 默认关；
  /// `--dart-define=SHOW_MESSAGE_AVATARS=true` 强制开（含 duo）。
  bool get _showMessageAvatars => kShowMessageAvatarsOverride || _isGroup;

  /// 发送者显示名（群内逐条标注）：成员表里的名字，查不到回落"未命名"。
  String _senderNameOf(String? memberId) {
    if (memberId == null) return '';
    final name = _memberNames[memberId];
    return (name == null || name.isEmpty) ? '' : name;
  }

  /// **其它**空间（非当前）的未读数：spaceId → 条数。用于顶部「切换秘境」旁的汇总角标。
  final Map<String, int> _otherUnread = {};
  Timer? _unreadTimer;
  int? _escrowUpdatedAt; // 本端已知口令更新时间（上线补查对比用；沿用 widget 初值）
  Timer? _peerTicker; // 对方在线轮询（30s）

  /// 阅后即焚时长文案：天/时/分可读组合（0 = 关闭）。老版本的固定档位映射
  /// 已删——2026-10-16 起任意时长，formatBurnDuration 对整点值输出相同的干净文案。
  String _burnOptionLabel(int seconds, AppLocalizations l10n) =>
      formatBurnDuration(seconds, l10n);

  /// 顶栏阅后即焚标记的档位文字：**只用量纲单位** d/h/m/s（老板 2026-09-24：
  /// 不用中文单位——横向更省，也不随界面语言变化）。取能整除的最大单位。
  String _burnBadgeText(int seconds) {
    if (seconds >= 86400 && seconds % 86400 == 0) return '${seconds ~/ 86400}d';
    if (seconds >= 3600 && seconds % 3600 == 0) return '${seconds ~/ 3600}h';
    if (seconds >= 60 && seconds % 60 == 0) return '${seconds ~/ 60}m';
    return '${seconds}s';
  }

  /// 顶栏的阅后即焚标记：沙漏 + 档位（如 `⧗ 1h`）。**点击直接进档位弹层**
  /// （与菜单里的「阅后即焚」是同一个动作，只是把这个"会丢消息"的状态提到明面上）。
  ///
  /// 图标与消息气泡里同族（`_BurnHourglass`），并同样**动态翻转**（老板 2026-09-28：
  /// 菜单里是动态的，顶栏这个静态的显得不一致，一并动态化）；尺寸 24 = 锁屏等
  /// 顶栏图标同大（老板 2026-09-24，火苗太小时改）。未焚毁态才有翻转，
  /// `burned: false` 恒真——顶栏标记只在焚毁**生效前**显示。
  /// 配色不单独指定：跟锁屏等顶栏图标同色。
  Widget _buildBurnBadge(AppLocalizations l10n) {
    return Tooltip(
      message: l10n.chatPageBurnHeading,
      child: InkWell(mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(16),
        onTap: _showBurnPicker,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _BurnHourglass(burned: false, size: 24),
              const SizedBox(width: 2),
              Text(_burnBadgeText(_burnSeconds),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }

  /// 消息发送时间标注：当天 HH:MM / 当年 mm-dd HH:MM / 跨年 yyyy-mm-dd HH:MM。
  String _messageTimeLabel(HistoryMessage m) => _timeStampLabel(m.createdAt);

  /// 时间戳标注（消息 / 通道列表共用）：当天 HH:MM / 当年 mm-dd HH:MM / 跨年 yyyy-mm-dd HH:MM。
  String _timeStampLabel(int ms) {
    final local = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    if (local.year == now.year &&
        local.month == now.month &&
        local.day == now.day) {
      return '${two(local.hour)}:${two(local.minute)}';
    }
    if (local.year == now.year) {
      return '${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
    }
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }

  /// 常驻提示条（老板 2026-09-16：连不上/未被识别要持续可见，不能只弹一次通知）。
  /// 三档优先级：
  /// - 服务器不认本通道（库被重置）→ 淡红：明确"数据没被清除"，用户可继续读本地消息；
  /// - 有 pending 消息 + 连接异常 → 淡琥珀（原有：解释"小飞机停了很久"）；
  /// - 仅连续同步失败（无 pending）→ 淡琥珀：只讲后果与自动恢复，**不诊断网络**
  ///   （2026-10-13 合并：原先按 WS 态分「同步中… / 离线」两种措辞，但网络诊断由
  ///   状态条红绿灯承担，条里复述"离线"在绿灯时自相矛盾、复述"同步中"在红灯深退避
  ///   时名不副实——统一成状态中性的一句，灯管灯、条管条）。
  /// 判定用 `_consecutiveSyncFailures > 0` 而不是 `!_ws.connected`，避免普通重连闪条。
  Widget _buildOfflineHint() {
    final l10n = AppLocalizations.of(context)!;
    if (_entranceUnrecognized) {
      return _hintBanner(
        l10n.chatPageEntranceUnrecognized,
        bg: const Color(0xFFFFEBEE), // 淡红：需要用户知晓的状态（非报错弹窗）
        fg: const Color(0xFFB71C1C),
      );
    }
    final troubled =
        _consecutiveSyncFailures > 0 || (_ws != null && !_ws!.connected.value);
    if (_unsentCount > 0 && troubled) {
      return _hintBanner(
        l10n.chatPageMsgsUnsent(_unsentCount),
        bg: const Color(0xFFFFF3E0), // 淡琥珀：提示而非报错
        fg: const Color(0xFF8A5300),
      );
    }
    if (_consecutiveSyncFailures == 0) return const SizedBox.shrink();
    return _hintBanner(
      l10n.chatPageMsgsSyncing,
      bg: const Color(0xFFFFF3E0),
      fg: const Color(0xFF8A5300),
    );
  }

  /// 提示条外观：整宽、单行小字（常驻在状态条下方，不遮挡输入区）。
  Widget _hintBanner(String text, {required Color bg, required Color fg}) {
    return Container(
      width: double.infinity,
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(text, style: TextStyle(fontSize: 12, color: fg)),
    );
  }

  /// 气泡时间行里的快捷动作小按钮（老板 2026-10-02）：**只留图标**（文字版实测
  /// 每条消息都带字，视觉太重），尺寸/颜色同时间戳淡色档，点击直接执行动作——
  /// 不用进长按菜单。悬浮/点击背景效果同状态栏电话/设备图标（Material+InkWell）。
  Widget _bubbleQuickAction(
    HistoryMessage m, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    double iconSize = 16,
  }) {
    final subtle = _uiStyle == 'gradient' ? Colors.white70 : Colors.grey;
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(), // 圆形背景（老板 2026-10-02：同状态栏电话图标）
      clipBehavior: Clip.antiAlias,
      child: Tooltip(
        message: label,
        child: InkWell(
          mouseCursor: SystemMouseCursors.click,
          // 悬浮/点击背景（老板 2026-10-02）：与状态栏电话/设备图标同档
          // hover/highlight 色，浅灰淡染——gradient 深色气泡下黑 alpha 同样可见
          hoverColor: Colors.black.withValues(alpha: 0.05),
          highlightColor: Colors.black.withValues(alpha: 0.08),
          onTap: onTap,
          child: SizedBox.square(
            // 固定方形热区 = 时间行统一高度（老板 2026-10-08：圆钮与"沙漏+时长"
            // 胶囊背景一样高）。不再用 padding 撑——那样图标大小一变高度就变了。
            dimension: _bubbleTimeRowControlHeight,
            child: Center(child: Icon(icon, size: iconSize, color: subtle)),
          ),
        ),
      ),
    );
  }

  /// 自己消息的发送状态小标（老板 2026-09-12）：
  /// - pending → 纸飞机（发送中）
  /// - sent → 单勾（服务端已收下）
  /// - **delivered / read → 单勾**（服务端已收下；这是我同一身份另一条通道发的
  ///   消息同步回来的状态，对方回执到了才升双勾）
  /// - 有对方回执（delivered/read）→ 双勾
  /// - failed → 红色警告（点按重发）
  /// 仅自己、非墓碑消息显示。
  ///
  /// 注意 `sent` 与 `delivered` 都是"服务端已收下"，**不能**只把 `sent` 当已发送：
  /// `delivered` 若因为暂时没有对方回执而掉进末尾的 pending 分支，就会被渲染成
  /// "发送中"蓝飞机 → 用户以为没发出去、去点重发 → 撞上服务端 403 → 变成永久红色
  /// 「点击重发」（老板 2026-09-22 线上实测的完整链条）。
  Widget _buildSendStatusIcon(HistoryMessage m) {
    final l10n = AppLocalizations.of(context)!;
    final subtle = _uiStyle == 'gradient' ? Colors.white70 : Colors.grey;
    final messageId = m.env.messageId;
    final busy = _retrying[messageId];

    // 点按重发期间的前置文案（老板 2026-09-13）：点小飞机 → 「加速中…」；
    // 点 failed → 「重发中…」。完成后按结果回到对应状态：若又失败（服务端明确
    // 拒绝）→ 清掉 busy → 文案回到「点击重发」。
    final busyLabel = switch (busy) {
      'speedup' => l10n.chatPageMsgSpeedingUp,
      'resend' => l10n.chatPageMsgResending,
      _ => null,
    };

    if (m.status == 'failed') {
      // 文字标签 + 红色警告图标（老板 2026-09-13：光一个 ⚠️ 看不出能点）。
      // 悬浮/点击圆形背景遮罩 + 图标 16（2026-10-11 老板：与时间戳后面的
      // 引用/拷贝/保存快捷动作同款风格，别像裸文字）
      return Tooltip(
        message: l10n.chatPageMsgFailed,
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            mouseCursor: SystemMouseCursors.click,
            hoverColor: Colors.black.withValues(alpha: 0.05),
            highlightColor: Colors.black.withValues(alpha: 0.08),
            onTap: () => _tapRetryMessage(m, asResend: true),
            child: Container(
              height: _bubbleTimeRowControlHeight,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              alignment: Alignment.center,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(busyLabel ?? l10n.chatPageMsgFailedTap,
                      style: TextStyle(fontSize: 11, color: Colors.red.shade600)),
                  const SizedBox(width: 2),
                  Icon(Icons.error_outline, size: 16, color: Colors.red.shade600),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // 撤回墓碑永远显示单勾（2026-10-11 老板）：服务端消息行已真删（对方永远
    // 拉不到这一条），但回执是按成员高水位记的、不按单条消息——对方之后拉到
    // 任何更大 seq 的消息都会越过它的 seq，按常规判定会误显双勾。撤回=没送达，
    // 固定单勾才符合事实。
    if (m.deletedKind == 'recall') {
      return Tooltip(
        message: l10n.chatPageMsgSent,
        child: Icon(Icons.check, size: 12, color: subtle),
      );
    }

    // 送达进度（老板 2026-10-12 定稿）：k=0 → 单勾；k≥1 → 「k 双勾」（数字在
    // 双勾**前面**、不加号——放在后面会跟时间数字混淆，老板同日调优）。
    // **群组永远不出现裸双勾**——群随时扩张，"全员送达"不是终态：新人进群
    // 后总数变大，显示自动退回"旧k 双勾"，不发生图标降级。duo 只有一名
    // 接收方（k=1 即全体），保持经典裸双勾。k 来自 _peerReceipts 逐成员
    // 水位（内存常驻，随回执轮询刷新，无额外网络开销）。
    final deliveredCount =
        MessageRepository.deliveredCountOf(m.env.serverSequence, _peerReceipts);
    if (deliveredCount > 0) {
      final allReceived = MessageRepository.receiptOf(
              m.env.serverSequence, _peerReceipts) !=
          null;
      return Tooltip(
        message: allReceived
            ? l10n.chatPageMsgDelivered
            : l10n.chatPageMsgSent,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // duo（peers=1）全员送达 → 裸双勾；群 → 永远带人数（含全员时），
            // 数字与双勾间留 1 空隙（老板 2026-10-12 定：试过 2/3 后回到 1）
            if (!allReceived || _peerReceipts.length > 1) ...[
              Text('$deliveredCount',
                  style: TextStyle(fontSize: 11, color: subtle)),
              const SizedBox(width: 1),
            ],
            Icon(Icons.done_all, size: 12, color: subtle),
          ],
        ),
      );
    }
    if (m.status == 'sent' || m.status == 'delivered' || m.status == 'read') {
      return Tooltip(
        message: l10n.chatPageMsgSent,
        child: Icon(Icons.check, size: 12, color: subtle),
      );
    }

    // pending（还没确认）：动态小飞机 + 可点按（幂等重发＝去问服务端收到没）。
    // 悬浮/点击圆形背景遮罩 + 图标 16（2026-10-11 老板：与时间行快捷动作同款）；
    // 小飞机用超链接蓝提示可点——但渐变主题深蓝气泡上蓝飞机几乎看不见
    // （2026-10-11 老板），改白系（同快捷动作的 white70）；「加速中」期间
    // 仍用中性色，避免"点了还提示可点"的矛盾。
    return Tooltip(
      message: l10n.chatPageMsgSendingTap,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          mouseCursor: SystemMouseCursors.click,
          hoverColor: Colors.black.withValues(alpha: 0.05),
          highlightColor: Colors.black.withValues(alpha: 0.08),
          onTap: () => _tapRetryMessage(m, asResend: false),
          child: Container(
            height: _bubbleTimeRowControlHeight,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (busyLabel != null) ...[
                  Text(busyLabel, style: TextStyle(fontSize: 11, color: subtle)),
                  const SizedBox(width: 2),
                ],
                _SendingPlane(
                  size: 16,
                  color: busyLabel != null
                      ? subtle
                      : (_uiStyle == 'gradient'
                          ? Colors.white70
                          : const Color(0xFF2E7CF6)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 点按状态小标 → 幂等重发（服务端按 message_id 去重），期间显示进行中文案。
  Future<void> _tapRetryMessage(HistoryMessage m, {required bool asResend}) async {
    final messageId = m.env.messageId;
    setState(() => _retrying[messageId] = asResend ? 'resend' : 'speedup');
    try {
      await _repo.retryMessage(messageId);
      await _refreshLocal();
    } finally {
      if (mounted) setState(() => _retrying.remove(messageId));
    }
  }

  /// 阅后即焚时钟标签：显示焚毁时刻（expiresAt），格式与其他时间戳一致
  /// （当天 HH:MM / 当年 mm-dd HH:MM / 跨年 yyyy-mm-dd HH:MM）——
  /// 不再区分手动/全局（手动原本的「修改时间+时长」、全局的纯时长统一取消，
  /// 老板 2026-10-09）。expiresAt 缺失时无标签。
  String _burnTagLabel(int? expiresAt, int burnSeconds, {required bool manual}) {
    if (expiresAt == null || expiresAt <= 0) return '';
    return _timeStampLabel(expiresAt);
  }

  @override
  void initState() {
    super.initState();
    // **会话先建**：下面每一步（含 initState 里就发起的 _refreshPeerOnline）
    // 都可能读 `_session.token`，late final 没赋值就抛 LateInitializationError
    // （2026-09-26 加会话时踩过一次：被 catch 吞掉 → 对方在线/「邀请加入」全失效）。
    final db = widget.db ?? LocalDatabase.shared;
    _session = SpaceSessions.of(
      spaceId: widget.spaceId,
      token: widget.token,
      // 续期用注入的 challenge-response（chat_entry 从锁包密钥对拼的）；
      // 旧锁包没有密钥对 → reauth 为 null → 会话续不了期，401 照抛
      refresh: widget.reauth,
      db: db,
    );
    _myMemberName = widget.memberName ?? '';
    _myEntranceName = widget.entranceName ?? '';
    _myGender = ''; // 个人资料弹窗性别图标：由 profile 恢复（向导完成时写入）
    _peerGender = ''; // 消息气泡配色：由 profile 恢复（向导完成时写入）
    _mySlot = null; // 身份槽位（0=第一人/1=第二人）：由 profile 恢复 + /space 校正
    _peerSlot = null;
    _peerName = widget.peerName ?? '';
    _myMemberId = widget.memberId; // 向导路径已知；重启路径为 null → 稍后反查补齐
    // 演示秘境：见 widget.isDemo——一切需要服务器的启动路径全部跳过
    if (!widget.isDemo) {
      _refreshPeerOnline();
      _peerTicker = Timer.periodic(const Duration(seconds: 30), (_) => _refreshPeerOnline());
    }
    WidgetsBinding.instance.addObserver(this);
    // 名字未由向导传入（如 PIN 解锁后重启进聊天）→ 从本地 profile 恢复。
    // 必须按 spaceId 读：多空间下全局键是所有空间共用的一格，会被别的空间覆写
    // （老板 2026-09-22 实测：新建空间对方还没加入，顶部条却显示原空间的对方名）。
    AppLockService(db).loadProfile(spaceId: widget.spaceId).then((p) {
      if (!mounted) return;
      setState(() {
        if (_myMemberName.isEmpty) _myMemberName = p['memberName'] as String? ?? '';
        if (_myEntranceName.isEmpty) _myEntranceName = p['entranceName'] as String? ?? '';
        if (_peerName.isEmpty) _peerName = p['peerName'] as String? ?? '';
        if (_myGender.isEmpty) _myGender = p['myGender'] as String? ?? '';
        if (_peerGender.isEmpty) _peerGender = p['peerGender'] as String? ?? '';
        _mySlot = p['mySlot'] as int?; // 槽位无"空值语义"问题，直接恢复
        _peerSlot = p['peerSlot'] as int?;
        // 群组名字（仅本机）：无 widget 入参，直接以 profile 为准
        _groupName = p['groupName'] as String? ?? '';
      });
      // 快照可能过期（对方改名 / v2 早期把对方性别写死空串）→ 以服务端为准校正
      // 名字与性别（老板 2026-09-11：App 重启后一直显示旧的对方名字）
      if (!widget.isDemo) _refreshProfileFromServer();
    });
    _repo = MessageRepository(
      db: db,
      api: widget.api ?? ApiClient(effectiveServer),
      spaceKey: widget.spaceKey,
      spaceId: widget.spaceId,
      entranceId: widget.entranceId,
      keyVersion: widget.keyVersion,
      token: widget.token,
      settings: BurnAfterSettings(db, spaceId: widget.spaceId),
      reauth: widget.reauth == null ? null : _reauthWithRevokedFallback,
      isDemo: widget.isDemo,
      // 本端 memberId（向导登记时确定）：种入归属判定映射，离线启动也能
      // 按 member 维度分左右分栏（服务器离线拉不到 entrance→member 映射）
      memberId: widget.memberId,
    );
    // 头像加载要在 _repo 就绪后（重启路径要靠它反查本机 memberId）
    _loadMyAvatar();
    _loadInitial();
    _scrollController.addListener(_maybeLoadOlder);
    _scrollController.addListener(_onScrollForRead);
    _inputFocusNode.addListener(_onInputFocusChanged);
    // 前台无操作锁屏：输入框持焦时打字（软键盘，onPointerDown 抓不到）也算交互，
    // 监听控制器文本变化刷新最近交互时刻。
    _input.addListener(_onInputInteraction);
    _loadBurnLabel();
    _loadTombstoneDisplay(); // 墓碑消息显示模式（更多设置里可改）
    _refreshPinStatus();
    _loadLockSeconds(); // 恢复用户自选的锁屏时长（默认 30s；两个计时器共用）
    // 前台无操作锁屏：一次性 Timer，每次交互重排到"现在+阈值"（见 _armIdleLock）。
    // 交互信号由 build 根的 Listener（点/滑）+ 滚动通知（滚轮）+ 输入框监听（打字）
    // 喂给 _armIdleLock；解锁/关弹层 pop 回聊天时由 push Future（_pushLockOverlay）
    // 重排。
    _armIdleLock();
    if (!widget.isDemo) _refreshNotifyEmail(); // 菜单项「邮件通知」的当前值（拉不到就保持 null，不显示）
    // 首帧同步取值（同进程内延续上次选择，避免首帧 LateInitializationError），
    // 随后用持久化值校正（_loadUiStyle 异步）
    _uiStyle = uiStyleNotifier.value;
    _loadUiStyle(); // 恢复界面主题（plain/gradient，默认素雅纯色）
    // 风格切换即时生效（弹窗不关闭也能预览）：notifier 通知 → 重建背景
    uiStyleNotifier.addListener(_onUiStyleChanged);
    _attachmentStorage = attachmentStorageNotifier.value;
    _loadAttachmentStorage(); // 恢复附件存储模式（secured/stored，默认 secured）
    attachmentStorageNotifier.addListener(_onAttachmentStorageChanged);
    // 每 3 秒轮询同步（WS 连接成功后降频为 30s 兜底；断开恢复高频——见 _onWsStatusChanged）
    if (widget.isDemo) return; // 演示秘境：全离线，同步/推送/实时/未读一律不起
    _restartTicker(_tickerInterval);
    _registerPushToken();
    _registerInstallUid();
    _registerClientInfo(); // 客户端信息（App + 版本）：设备通道卡片显示用
    _startRealtime();
    // 其它空间的未读：30s 问一次（WS 只管当前空间，别的收不到实时事件）
    _unreadTimer = Timer.periodic(
        const Duration(seconds: 30), (_) => unawaited(_refreshOtherUnread()));
    unawaited(_refreshOtherUnread());
  }

  /// 顶部栏的通话按钮：发起呼叫（振铃界面由状态监听弹出）。
  void _startVoiceCall() {
    unawaited(_voiceCall?.invite());
  }

  /// 通话信令（Server 哑转发 call.*，PROTOCOL.md §8.4）：交给通话服务处理。
  void _onCallSignal(WsCallEvent event) {
    unawaited(_voiceCall?.handleRemote(event));
  }

  bool _callSheetShown = false;

  /// 通话状态变化：振铃（来电/去电）时弹出通话界面；结束由界面自己关。
  void _onVoiceCallStateChanged() {
    final call = _voiceCall;
    final s = call?.state.value;
    if (call == null || s == null) return;
    final shouldShow =
        s.phase == VoiceCallPhase.calling || s.phase == VoiceCallPhase.ringing;
    if (!shouldShow || _callSheetShown) return;
    _callSheetShown = true;
    unawaited(
      showVoiceCallDialog(context, call: call, peerName: _peerName)
          .whenComplete(() => _callSheetShown = false),
    );
  }

  /// 通话结束：顶部提示条说明怎么结束的（未接/拒接/忙线/结束），并回到空闲。
  ///
  /// 注意：不做后台呼入，所以「对方没接」是常态——文案必须说清是"没接"而不是"坏了"。
  void _onCallEnded(VoiceCallEndReason reason, bool wasCaller, Duration? duration) {
    final l10n = AppLocalizations.of(context)!;
    final message = switch (reason) {
      VoiceCallEndReason.hungUp => l10n.voiceCallEnded,
      VoiceCallEndReason.canceled => l10n.voiceCallEndedCanceled,
      VoiceCallEndReason.declined => l10n.voiceCallEndedDeclined,
      VoiceCallEndReason.busy => l10n.voiceCallEndedBusy,
      VoiceCallEndReason.timeout => l10n.voiceCallEndedNoAnswer,
      VoiceCallEndReason.failed => l10n.voiceCallEndedFailed,
    };
    final overlay = Overlay.of(context, rootOverlay: true);
    showTopNoticeOn(overlay, message, extraTop: kNoticeExtraTopBelowStatusBar);
    unawaited(_recordCallInChat(reason, wasCaller, duration));
    _voiceCall?.reset();
  }

  /// 通话记录：往聊天流发一条 `system` 消息（对端靠正常同步看到，即"双向同步"）。
  ///
  /// **一通电话只发一条**，否则两端各插一条就成了双份。分工：
  /// - 主叫方（`wasCaller`）负责：正常结束、取消、超时未接、连接失败；
  /// - 被叫方负责：拒接与忙线——这两件事只有他自己知道，主叫只看到"没接"。
  ///
  /// 明文留空：**文案由各自客户端按自己的语言渲染**（meta 里只放结果与时长），
  /// 不然就把一方的语言塞给了另一方。
  Future<void> _recordCallInChat(
    VoiceCallEndReason reason,
    bool wasCaller,
    Duration? duration,
  ) async {
    final state = switch (reason) {
      VoiceCallEndReason.hungUp => kCallStateCompleted,
      VoiceCallEndReason.canceled => kCallStateCanceled,
      VoiceCallEndReason.timeout => kCallStateMissed,
      VoiceCallEndReason.failed => kCallStateFailed,
      VoiceCallEndReason.declined => kCallStateDeclined,
      VoiceCallEndReason.busy => kCallStateBusy,
    };
    final mine = switch (reason) {
      // 拒接/忙线只有被叫方知情 → 由被叫方发
      VoiceCallEndReason.declined || VoiceCallEndReason.busy => !wasCaller,
      _ => wasCaller,
    };
    if (!mine) return;
    try {
      await _repo.send(
        '',
        type: 'system',
        meta: <String, dynamic>{
          kMetaCallState: state,
          if (duration != null) kMetaCallDurationSeconds: duration.inSeconds,
        },
        onPersisted: (_) => _refreshLocal(),
      );
      await _refreshLocal();
    } catch (_) {
      // 记录没写进去不影响通话本身（也不该为此弹错误打扰用户）
    }
  }

  /// 上线成员的身份资料是否还不全（触发补拉 /space 的判据）：
  /// member_id 未知（旧服务端广播不带），或该成员**不在性别表里**（成员表还是
  /// 上次拉取的旧快照——如离线期间新加入的同伴）。已在表里的成员不触发，
  /// 避免每次上下线都白跑一次 /space。
  bool _peerProfileIncomplete(String? memberId) {
    if (memberId == null || memberId.isEmpty) return true;
    return !_memberGenders.containsKey(memberId);
  }

  /// 对端上下线（Server 广播——立即更新对方在线状态，不等 30s 轮询）。
  void _onPeerStatus(WsPeerStatusEvent event) {
    if (event.entranceId == widget.entranceId) return; // 本通道自身的事件忽略
    // 与我同身份的通道（我自己的另一条）不算"对方"（新服务端已不推这类广播，
    // 这里兜住旧服务端——旧 payload 无 member_id 时按原行为处理）
    if (event.memberId != null && event.memberId == widget.memberId) return;
    final online = event.type == kWsTypePeerOnline;
    // 上线成员的身份信息还不全（group 里第二个同伴上线时 _peerOnline 已是 true，
    // 旧 guard 会被挡住 → 名字/性别缺失直到下次广播/重启；CLI 同款 bug 在 group
    // E2E 暴露，2026-10-07 对齐修复）：不在表里就补拉，而不是只看 _peerOnline 翻转
    if (online && _peerProfileIncomplete(event.memberId)) {
      unawaited(_refreshProfileFromServer());
    }
    // 在 setState 之前记下"这次事件是否改变了状态"——下面要用，改完就比不出来了
    final changed = online != _peerOnline;
    if (mounted && changed) {
      setState(() {
        _peerOnline = online;
        // 灯与「时刻」必须同一帧到位。此前这里只翻 _peerOnline，_peerSinceMs 要等
        // 下一次 30s 轮询（_refreshPeerOnline）才算出来 → 绿灯先亮、约 1 分钟后
        // 才出时间（老板 2026-10-05 真机实测：iOS 建 duo、macOS 加入）。
        // 现在**两帧都自带时刻**：peer.online 带 online_since（进入在线态，重连
        // 不刷新），peer.offline 带 offline_since（断线时刻）；`WsPeerStatusEvent
        // .since` 已把两者归一（服务端 ws.ts 广播时带上），直接写即可，不用再等
        // 一次网络往返。
        if (event.since != null) _peerSinceMs = event.since;
      });
    }
    // 什么时候还要重拉一次 /entrances：
    // - **群空间**：左上角摆着「其他人在线数 / 总数」——任何一条别人的通道上下线都
    //   可能改变人数 → 一律重算。**必须重拉、不能就地加减**：同一 member 可能有多条
    //   通道，断一条不代表人下线（要按 member 去重才是"人在线"）。顺带也刷新了
    //   决定「邀请」入口的 `_peerJoined`。
    // - duo：仅当事件没带时刻（连着老服务端）才补拉，别白跑。
    if (_isGroup || (changed && event.since == null)) {
      unawaited(_refreshPeerOnline());
    }
  }

  /// 群聊一期：新**身份**入网（member.joined）——成员数 +1，立刻重拉 /space 刷新
  /// 成员名单与顶部条（否则要等下一次轮询/重启才看到新人）。
  void _onMemberJoined(WsMemberJoinedEvent event) {
    unawaited(_refreshProfileFromServer());
  }

  /// 自愿退群（member.left，2026-10-19，aimemo/groupExitDesign.md §6.4）：
  /// **别人**退出——与 [_onMemberJoined] 同构刷新名单/计数，另发一条顶部通知
  /// （告知形式=顶部通知+名单刷新，老板决策 3；不在聊天流落系统消息）。
  ///
  /// 自己退群收不到这帧（服务端只广播给剩余成员；发起设备的连接被静默摘除），
  /// 这里仍防一手：万一是自己（老服务端回声）→ 只刷新、不通知。
  void _onMemberLeft(WsMemberLeftEvent event) {
    unawaited(_refreshProfileFromServer());
    if (!mounted) return;
    if (event.memberId.isNotEmpty && event.memberId == _myMemberId) return;
    final l10n = AppLocalizations.of(context)!;
    final name = (event.displayName ?? '').trim();
    _notice(
      context,
      l10n.chatPageMemberLeftNotice(
          name.isEmpty ? l10n.chatPageMembersUnnamed : name),
    );
  }

  /// 空间口令被重设（Server 广播 passphrase.rotated）：只发通知不弹窗——
  /// 修改口令时（按需）才要求输入新口令。
  void _onPassphraseRotated(WsPassphraseRotatedEvent event) {
    if (!mounted) return;
    _notice(context, AppLocalizations.of(context)!.chatPageEscrowRotatedNotice(_isGroup ? 'group' : 'duo'));
  }

  /// 对方改名/换头像（Server 广播 profile.updated）：立即更新顶部条对方名；
  /// 头像则让缓存失效重拉（广播由改名或 POST /avatar 触发）。
  void _onProfileUpdated(WsProfileUpdatedEvent event) {
    // 自己触发的广播要排除：改名/换头像会广播给同空间全部在线通道（含我自己的
    // 其它通道），广播里是"我的"新资料，落进 _peerName/_peerGender 就是错的。
    // （注：切空间卡片错显我的名字的主犯是 saveProfile 覆盖写抹掉 peerJoined——
    // 见 app_lock.dart；这里是同一症状的另一条污染路径，一并堵上。）
    // 两条判据：memberId 比对（权威，但重启路径 _myMemberId 要等首次 /space 才
    // 回填，可能还是 null）；名字比对兜底（改名 UI 禁止与对方同名
    // `chatPageRenameSameAsPeerError` → 空间内名字唯一，等名必是自己）。
    final isSelf = (event.memberId != null && event.memberId == _myMemberId) ||
        ((event.memberName ?? '').isNotEmpty && event.memberName == _myMemberName);
    if (isSelf) return;
    // 头像：无论改名还是换头像都刷一次（同一 per-member 头像文件可能已变）
    _MessageAvatarState.invalidate(event.memberId);
    unawaited(_loadPeerAvatar()); // 状态条那份（自己存 bytes，不走上面那个缓存）
    _refreshProfileFromServer();
    final name = event.memberName;
    if (name == null || name.isEmpty || !mounted) return;
    setState(() => _peerName = name);
  }

  /// 对方回执更新（Server 广播 receipt.updated）：落库为已送达/已读高水位。
  /// **本轮不显示**——只为把数据打通，供将来 UI 使用（老板 2026-09-12）。
  void _onReceiptUpdated(WsReceiptUpdatedEvent event) {
    unawaited(_repo
        .upsertPeerReceipt(
          memberId: event.memberId,
          deliveredUptoSeq: event.deliveredUptoSeq,
          readUptoSeq: event.readUptoSeq,
        )
        .then((_) => _loadPeerReceipts()));
  }

  /// 从服务端校正双方名字与性别（GET /space 的 memberNames/memberGenders）。
  /// 本机 profile 只是入网时的快照：对方改名后若没收到广播（或广播前就重启），
  /// App 会一直显示旧名字（老板 2026-09-11 实测）；性别同理（v2 早期把对方性别
  /// 写死空串 → 气泡回退灰色）。启动与收到 profile.updated 时调用
  /// （对齐 CLI 的 _refreshMemberNames）。
  Future<void> _refreshProfileFromServer() async {
    if (!mounted || _session.token.isEmpty || effectiveServer.isEmpty) return;
    try {
      final api = widget.api ?? ApiClient(effectiveServer);
      final space = await _withAuth((t) => api.getSpace(t));
      // 重启（PIN 解锁）路径不传 memberId（main.dart 只还原明文 payload）——
      // 从 /space 的通道表里按 entranceId 反查，否则拿不到"我"，校正无从下手
      var mine = widget.memberId;
      if (mine == null || mine.isEmpty) {
        for (final d in space.entrances) {
          if (d.entranceId == widget.entranceId) {
            mine = d.memberId;
            break;
          }
        }
      }
      if (mine == null || mine.isEmpty) return;
      // 反查到的本机 memberId 落地：头像加载/上传后的缓存失效都要用它
      // （重启路径 widget.memberId 为空，否则上传头像后消息流不刷新）
      final mineChanged = _myMemberId != mine;
      _myMemberId = mine;
      // 启动时没有 memberId（重启路径）或反查值与服务器不一致 → 重拉头像
      if ((mineChanged || _myAvatarBytes == null) && mounted) unawaited(_loadMyAvatar());
      final myG = space.memberGenders[mine] ?? '';
      var peerG = '';
      var peerName = '';
      var peerId = '';
      for (final entry in space.memberNames.entries) {
        if (entry.key == mine) continue;
        peerName = entry.value;
        peerG = space.memberGenders[entry.key] ?? '';
        peerId = entry.key;
        break;
      }
      final myName = space.memberNames[mine] ?? '';
      // 群聊一期（2026-10-03）：全成员资料快照——群空间的顶部条名单、逐条消息
      // 的发送者名字、成员管理弹层都从这里取；duo 的 _peerName/_peerGender 原
      // 字段继续走原逻辑（下方"第一个非我成员"对 duo 仍等价于唯一对方）。
      _memberSlots
        ..clear()
        ..addAll(space.memberSlots); // 含未命名成员（memberNames 会漏）；含墓碑（保名）
      _memberNames
        ..clear()
        ..addAll(space.memberNames);
      _memberGenders
        ..clear()
        ..addAll(space.memberGenders);
      // 成员状态（'active' | 'left'）：老服务端不下发 → 空表（全按 active）
      _memberStatus
        ..clear()
        ..addAll(space.memberStatus);
      _spaceMode = space.mode;
      _maxMembers = space.maxMembers;
      // 身份槽位（0=第一人/创建者，1=第二人）：同性别第二人气泡取青色的判据
      // （老服务端 member_slots 为空表 → 保持 null，不启用青色）
      final mySlot = space.memberSlots[mine];
      final peerSlot = peerId.isEmpty ? null : space.memberSlots[peerId];
      if (!mounted) return;
      setState(() {
        if (myName.isNotEmpty) _myMemberName = myName;
        if (peerName.isNotEmpty) _peerName = peerName;
        if (peerId.isNotEmpty && peerId != _peerMemberId) {
          _peerMemberId = peerId; // 状态条头像要用
          unawaited(_loadPeerAvatar());
        }
        if (myG.isNotEmpty) _myGender = myG;
        if (peerG.isNotEmpty) _peerGender = peerG;
        _mySlot = mySlot;
        _peerSlot = peerSlot;
      });
      // 「切换我的秘境」的群组卡片要平铺成员：把**除我之外**的成员按加入先后
      // （槽位升序 = 入群顺序，见服务端"新身份分配最小空槽"）落进 per-space 资料。
      final otherMembers = [
        for (final e in (space.memberSlots.entries.where((e) => e.key != mine).toList()
          ..sort((a, b) => a.value.compareTo(b.value))))
          {'id': e.key, 'name': space.memberNames[e.key] ?? ''},
      ];
      // 校正结果回写本地快照：否则下次启动（尤其离线）又用回入网时的旧值
      // （setState 只覆盖非空值，故不会把已有名字写成空）；按 spaceId 写，仅落当前空间
      await AppLockService(widget.db ?? LocalDatabase.shared).saveProfile(
        spaceId: widget.spaceId,
        memberName: _myMemberName,
        peerName: _peerName,
        entranceName: _myEntranceName,
        myGender: _myGender,
        peerGender: _peerGender,
        mySlot: _mySlot,
        peerSlot: _peerSlot,
        // 空间类型（切空间卡片的群组配色要用）：/space 刚下发过，带上
        mode: _spaceMode,
        otherMembers: otherMembers,
      );
    } catch (_) {
      // 网络失败：保持快照值（下次刷新再试）
    }
  }

  /// 上线补查（离线期间口令被重设）：启动/WS 连接后对比服务端 updated_at，
  /// 服务器更新 = 口令已重设——只发通知不弹窗（修改口令时按需才要求输入新口令）。
  Future<void> _checkEscrowRotated() async {
    if (!mounted || _session.token.isEmpty || effectiveServer.isEmpty) return;
    try {
      final api = widget.api ?? ApiClient(effectiveServer);
      final snap = await _withAuth((t) => api.getKeyEscrow(t));
      final serverAt = snap.updatedAt;
      final knownAt = _escrowUpdatedAt ?? widget.escrowUpdatedAt;
      if (serverAt != null && knownAt != null && serverAt > knownAt) {
        if (!mounted) return;
        _notice(context, AppLocalizations.of(context)!.chatPageEscrowRotatedNotice(_isGroup ? 'group' : 'duo'));
        _escrowUpdatedAt = serverAt; // 记录已知时间（防 WS 重连/重复补查刷屏）
      }
    } catch (_) {
      // 查询失败（网络/未托管）静默：不打断正常使用
    }
  }

  /// 本页所有**带鉴权**的请求的统一入口：走本空间的会话（401 自动续期 + 重试一次），
  /// 并把"被撤销 / 服务器不认这条通道"的副作用补上（会话层只负责续期，不碰 UI 与数据清理）。
  ///
  /// 为什么必须有它：会话 24h 过期后，只有同步/WS 会续期（各写自己那份 token），
  /// 而头像上传/改名/通道码/更多通道/未读角标这些**直接请求**原来拿的是构造时固化的
  /// `widget.token` → 全部 401「invalid session」且重启不恢复（2026-09-26 老板实测）。
  Future<T> _withAuth<T>(Future<T> Function(String token) fn) async {
    try {
      return await _session.call(fn);
    } on ApiException catch (e) {
      await _handleAuthError(e);
      rethrow;
    }
  }

  /// 续期失败时的副作用（`ENTRANCE_REVOKED` → 自毁；`FORBIDDEN` → 常驻提示），
  /// 由 [_withAuth] 与 [_reauthWithRevokedFallback] 共用。
  Future<void> _handleAuthError(ApiException e) async {
    if (e.code == 'ENTRANCE_REVOKED') {
      await _onEntranceRevoked();
    } else if (e.code == 'FORBIDDEN' && mounted && !_entranceUnrecognized) {
      setState(() => _entranceUnrecognized = true);
    }
  }

  /// session 过期自动续期（WS 4401 / 请求 401）：challenge-response 重新签发 token。
  ///
  /// 撤销毁数据**只认两个明确信号**（老板 2026-09-16）：
  /// - `ENTRANCE_REVOKED`：服务端明确说"这条通道被撤销了"（涉嫌被盗用）→ [_onEntranceRevoked]
  ///   清空本地数据 → 提示 → 回设置页；
  /// - `entrance.revoked` 帧（见 [_onEntranceRevoked] 的另一挂点）。
  ///
  /// `FORBIDDEN` 只表示"服务器不认这条通道"——**最可能是后台数据库被清空/重置**，
  /// 这是运维失误而非撤销，只置 [_entranceUnrecognized] 让常驻提示条说明情况，
  /// 本地消息仍然可读（此前一律当撤销处理，把本地数据全删了，不可挽回）。
  /// 其他异常原样抛出（调用方退避/提示）。
  ///
  /// 去重（同时多处 401 只发一次 challenge）在 [SpaceSession.renew] 里。
  Future<String> _reauthWithRevokedFallback() async {
    try {
      return await _session.renew();
    } on ApiException catch (e) {
      await _handleAuthError(e);
      rethrow;
    }
  }

  /// 本通道被撤销（Server 广播 entrance.revoked / 认证 403 ENTRANCE_REVOKED）：
  /// 清理本地数据（锁包+消息库）→ 提示 → 强制回设置页重新配置。
  /// **只有明确撤销走这里**（未登记/连不上只提示，见 [_reauthWithRevokedFallback]）。
  Future<void> _onEntranceRevoked() async {
    if (_wiped) return; // 去重：WS 帧与重认证可能同时触发（两次清理/两次跳转）
    _wiped = true;
    _ticker?.cancel();
    await _ws?.stop();
    if (!mounted) return;
    final db = widget.db ?? LocalDatabase.shared;
    // 逐步 best-effort：此前 6 步共用一个 try，第一步（清锁包）一抛异常，后面三个
    // delete 全被跳过 → 消息明文留在盘上，与"撤销=销毁"的语义相反。
    Future<void> step(Future<void> Function() f) async {
      try {
        await f();
      } catch (_) {
        // 单步失败不阻断其余清理
      }
    }
    // **只清这一个空间**（多空间 2026-09-22）：凭证 + 消息/附件/同步锚点/媒体缓存/
    // 留存明文。PIN 模式下这里没有 pin（也不该在页面里留着 pin），凭证条目会挂
    // pending，下次解锁时再摘——数据此刻已经清干净，其他空间原样保留。
    // 此前是全机 clear() + 删全表，多空间下等于"一个空间被撤销 = 全机数据归零"。
    await step(() => AppLockService(db).removeSpace(widget.spaceId));
    SpaceSessions.forget(widget.spaceId); // 凭证已删：会话（含 refresh 闭包）一并丢掉
    if (!mounted) return;
    _notice(context, AppLocalizations.of(context)!.chatPageEntranceRevoked);
    // 还有其他空间 → 切到下一个；一个都不剩 → 回向导（2026-09-24：不再一律回向导，
    // 多空间下被撤销的只是一条通道，其他秘境应当照常可用）。
    final vault = VaultSession.current;
    final next = vault == null
        ? null
        : await AppLockService(db).resolveActivePayload(vault);
    if (!mounted) return;
    if (next == null) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const SetupPage()),
        (route) => false,
      );
      return;
    }
    await switchToSpace(context, next.spaceId, db: widget.db);
  }

  /// 重建轮询 ticker（WS 状态变化时切换间隔）。
  void _restartTicker(Duration interval) {
    _ticker?.cancel();
    _currentTickerInterval = interval;
    _ticker = Timer.periodic(interval, (_) => _onTick());
  }

  /// 其它空间未读的合计（顶部角标显示这个）。
  int get _otherUnreadTotal =>
      _otherUnread.values.fold(0, (int sum, int n) => sum + n);

  /// 拉取**其它空间**的未读数（当前空间不算——它正在眼前，不需要角标提醒）。
  ///
  /// 为什么要单独拉：WS 只连着当前空间，其它空间的消息**收不到实时事件**，
  /// 只能定时问一次（30s）。未读角标不需要秒级实时，这个延迟可以接受。
  ///
  /// 只更角标、**不再响提示音**（老板 2026-09-27：取消其它空间来消息的声音）。
  Future<void> _refreshOtherUnread() async {
    final vault = VaultSession.current;
    final spaces = vault?.spaces ?? const <AppLockPayload>[];
    if (spaces.length < 2) return; // 只有一个空间就没什么"其它"可言
    final client = widget.api ?? ApiClient(effectiveServer);
    for (final space in spaces) {
      if (space.spaceId == widget.spaceId) continue;
      if ((space.token ?? '').isEmpty) continue;
      // 走**各空间的会话**（不是裸 token）：会话 24h 过期，直接用 Vault 里的旧
      // token 会 401 → 未读静默变 0（space_switcher 里同样处理过，2026-09-26 修）
      final count = await SpaceSessions.ofPayload(space, db: widget.db)
          .call((t) => client.unreadCount(t))
          .catchError((_) => 0);
      _otherUnread[space.spaceId] = count;
    }
    if (!mounted) return;
    setState(() {});
  }

  /// 建立 / 重连实时链路（WS + 通话服务）。
  ///
  /// 首次进入与**回到前台**都走这里（后台时我们主动断开，见
  /// [didChangeAppLifecycleState]）。[VoiceCallService] **只创建一次**——它持有
  /// 通话状态与 WebRTC 连接，重建会把正在进行的通话弄丢。
  void _startRealtime() {
    if (!widget.enableWs) return;
    final ws = _ws ??
        WsRealtimeService(
          server: effectiveServer,
          token: widget.token,
          reauth: widget.reauth == null ? null : _reauthWithRevokedFallback,
        );
    _ws = ws;
    if (_voiceCall == null) {
      ws.connected.addListener(_onWsStatusChanged);
      final call = VoiceCallService(ws: ws)..onEnded = _onCallEnded;
      _voiceCall = call;
      call.state.addListener(_onVoiceCallStateChanged);
    }
    ws.start(
      // WS 实时新消息：标记为 realtime，允许把消息标为"已读"（下面的补拉路径
      // 只标"已送达"——老板 2026-09-12：补拉的历史不等于人看过）
      onMessageNew: () => _refresh(realtime: true),
      onEntranceRevoked: _onEntranceRevoked,
      onPeerStatus: _onPeerStatus,
      onPassphraseRotated: _onPassphraseRotated,
      onProfileUpdated: _onProfileUpdated,
      onReceiptUpdated: _onReceiptUpdated,
      onCall: _onCallSignal,
      onMemberJoined: _onMemberJoined,
      onMemberLeft: _onMemberLeft,
    );
  }

  /// WS 状态变化：在线 → 降频兜底（30s）；离线 → 恢复高频轮询（3s）。
  void _onWsStatusChanged() {
    final online = _ws?.connected.value ?? false;
    _restartTicker(_tickerInterval); // 基准随 WS 状态变（在线 30s / 离线 3s），再乘退避
    if (mounted) setState(() {}); // 刷新标题红绿灯（在线绿/离线红）
    _refreshPeerOnline(); // 连接恢复时顺带刷新对方在线状态
    if (!online) return;
    // 在线（含断线重连）= 网络/服务端已可达：若正处于"离线/未识别"状态，**立即同步
    // 一次**，别干等下一轮轮询。
    // 为什么必须（老板 2026-10-09 报告「开 App 显示离线、不自动恢复、重启才好」）：
    // 离线时轮询按失败次数退避（最长 60s），而每次 WS 状态翻转都会 _restartTicker
    // 把倒计时清零——重连后若不主动同步，恢复会被拖到几十秒，甚至在持续抖动时
    // 永远等不到下一轮。以「连上」为触发点直接同步，让恢复与 ticker 周期解耦。
    // 仅在确有离线迹象时才补这一次：正常在线不额外发请求，避免 WS 抖动（连上即被
    // 顶）时把 /sync 打成一串。
    if (_consecutiveSyncFailures > 0 || _entranceUnrecognized) {
      unawaited(_refresh());
    }
    _checkEscrowRotated(); // 上线补查：离线期间口令被重设则发通知
  }

  /// 加载本设备阅后即焚档位秒数（每设备独立，纯本地）。
  Future<void> _loadBurnLabel() async {
    final s = BurnAfterSettings(widget.db ?? LocalDatabase.shared, spaceId: widget.spaceId);
    final seconds = await s.load();
    if (mounted) setState(() => _burnSeconds = seconds);
  }

  /// 加载墓碑消息显示模式（每设备、每空间独立，纯本地）。
  Future<void> _loadTombstoneDisplay() async {
    final s = TombstoneSettings(widget.db ?? LocalDatabase.shared, spaceId: widget.spaceId);
    final mode = await s.load();
    if (mounted) setState(() => _tombstoneDisplay = mode);
  }

  /// 顶栏 🌐：切换界面语言（跟随系统/中文/English，即时生效）。
  Future<void> _showLocalePicker() async {
    final settings = LocaleSettings(widget.db ?? LocalDatabase.shared);
    final current = await settings.load();
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    var picked = current;
    await showOptionPickerSheet<void>(
      context: context,
      builder: (ctx) => OptionPickerSheet(
        title: l10n.chatPageMenuLocaleLabel,
        selected: current,
        options: [
          for (final option in kLocaleOptions)
            OptionPickerItem(value: option, label: kLocaleLabels[option]!),
        ],
        onApply: (value, {bool scopeAll = false}) async {
          picked = value;
          await settings.save(value);
        },
      ),
    );
    if (picked == current) return;
    if (!mounted) return;
    _notice(context, AppLocalizations.of(context)!.chatPageLocaleSwitched(kLocaleLabels[picked]!));
  }

  /// 加载持久化的界面主题（默认素雅纯色，保留原有视觉效果）。
  /// 同步回 uiStyleNotifier：弹层选中态读的是 notifier，不回写会导致
  /// 冷启动后"页面是渐变、弹层却选中素雅纯色"的不一致。
  Future<void> _loadUiStyle() async {
    final s = UiStyleSettings(widget.db ?? LocalDatabase.shared);
    final style = await s.load();
    if (!mounted) return;
    setState(() => _uiStyle = style);
    if (uiStyleNotifier.value != style) uiStyleNotifier.value = style;
  }

  /// 风格切换通知（弹窗内点选即触发）：立即重建背景与菜单当前值。
  void _onUiStyleChanged() {
    if (mounted) setState(() => _uiStyle = uiStyleNotifier.value);
  }

  Future<void> _loadAttachmentStorage() async {
    final s = AttachmentStorageSettings(widget.db ?? LocalDatabase.shared, spaceId: widget.spaceId);
    final mode = await s.load();
    if (mounted) setState(() => _attachmentStorage = mode);
  }

  /// 存储模式切换通知：立即重建（附件渲染改用/停用本地副本）。
  void _onAttachmentStorageChanged() {
    if (mounted) setState(() => _attachmentStorage = attachmentStorageNotifier.value);
  }

  /// 顶栏菜单 → 附件存储（安全 / 留存）：本设备设置，两台设备可各选各的。
  /// 切回 secured 时**清空已留存的明文**（否则"安全"名不副实——老板 2026-09-14 定）。
  /// 界面主题名（按当前语言）。
  String _uiStyleLabel(String style, AppLocalizations l10n) =>
      style == 'gradient' ? l10n.chatPageUiStyleGradient : l10n.chatPageUiStylePlain;

  /// 附件存储模式标签（按当前语言）。
  String _attachmentStorageLabel(String mode, AppLocalizations l10n) =>
      mode == 'stored'
          ? l10n.chatPageAttachmentStorageStored
          : l10n.chatPageAttachmentStorageSecured;

  /// 附件存储模式说明（按当前语言）。
  String _attachmentStorageDesc(String mode, AppLocalizations l10n) =>
      mode == 'stored'
          ? l10n.chatPageAttachmentStorageStoredDesc
          : l10n.chatPageAttachmentStorageSecuredDesc;

  /// 附件存储：**单选 + 提交**（不点选即生效——老板 2026-09-14）——切回「远程托管」
  /// 会立刻删掉已留存的明文，是有害操作；选中该项时弹层里给红字警示。
  /// 附件存储：**单选 + 提交**（不点选即生效——老板 2026-09-14）——切回「远程托管」
  /// 会立刻删掉已留存的明文，是有害操作。提交后还要过一道**确认弹窗**（标题=选项名
  /// 「远程托管」、内容=删除警示，老板 2026-10-15）：用户确认才真正执行。
  ///
  /// 「远程托管」在 onApply 里**只记录意图、不落地**——弹层关后才错峰弹确认窗；
  /// 确认 → 保存 + 清明文（勾了"所有秘境"= saveAll + 全局 clear；否则 save +
  /// clearSpace）；取消 → 什么都不做。内联红色警示随之撤掉（被确认弹窗取代）。
  Future<void> _showAttachmentStoragePicker() async {
    final l10n = AppLocalizations.of(context)!;
    var pendingSecured = false; // 选了远程托管、等确认
    var pendingScopeAll = false;
    await showOptionPickerSheet<void>(
      context: context,
      builder: (ctx) => OptionPickerSheet(
        title: l10n.chatPageMenuAttachmentStorage,
        note: l10n.chatPageAttachmentStorageNote,
        selected: _attachmentStorage,
        submitLabel: l10n.chatPageAttachmentStorageSubmit,
        // 「应用于本机所有秘境」勾选框（老板 2026-10-15；提交按钮上方）。
        // 单秘境时不传 = 整个不渲染（没有可作用的对象，老板 2026-10-17）
        scopeAllLabel: _hasMultipleSpaces ? l10n.settingsScopeAll : null,
        options: [
          for (final mode in kAttachmentStorageOptions)
            OptionPickerItem(
              value: mode,
              label: _attachmentStorageLabel(mode, l10n),
              description: _attachmentStorageDesc(mode, l10n),
            ),
        ],
        onApply: (mode, {bool scopeAll = false}) async {
          if (mode == 'secured') {
            // 有害操作：不在这里落地，等确认弹窗（见方法尾）
            pendingSecured = true;
            pendingScopeAll = scopeAll;
            return;
          }
          final settings = AttachmentStorageSettings(
              widget.db ?? LocalDatabase.shared,
              spaceId: widget.spaceId);
          if (scopeAll) {
            // 所有秘境：写全局键 + 清除各空间 per-space 覆盖
            await settings.saveAll(mode);
          } else {
            await settings.save(mode);
          }
        },
      ),
    );
    if (!pendingSecured || !mounted) return;
    // 与弹层关闭动画错开再开 dialog（Overlay 交叉卸载断言，同 _menuAction）
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      // 破坏性确认：禁误触关闭（点外面/系统返回都不行），必须点按钮（老板 2026-10-15）
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          // 标题 = 选项名「远程托管」（复用同一个 l10n 键，老板 2026-10-15）
          title: Center(child: Text(l10n.chatPageAttachmentStorageSecured)),
          // 内容 = 原弹层里那条红色警示（撤掉内联版后搬到这里）
          content: Text(
            l10n.chatPageAttachmentStorageWarnClear,
            style: TextStyle(
                fontSize: 12, color: Theme.of(ctx).colorScheme.error),
          ),
          actions: [
            CancelButton(onPressed: () => Navigator.of(ctx).pop(false)),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l10n.confirm),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    // 确认：保存 + 清明文。作用域与勾选框对齐——勾了"所有秘境"就清**全部空间**
    // 的留存明文（全局 clear），否则只清当前空间（全局 clear 会把别的空间的明文
    // 缓存一并误删，与其设置矛盾——老板 2026-10-14 指出；撤销/删空间也走
    // clearSpace）。
    final settings = AttachmentStorageSettings(
        widget.db ?? LocalDatabase.shared,
        spaceId: widget.spaceId);
    if (pendingScopeAll) {
      await settings.saveAll('secured');
      await AttachmentStore.clear();
    } else {
      await settings.save('secured');
      await AttachmentStore.clearSpace(widget.spaceId);
    }
  }

  /// 「更多设置」弹层（老板 2026-10-15）：把原先顶层菜单的「附件存储」与新的
  /// 「墓碑消息」收到一个二级弹层里（顶层菜单只留一个带设置图标的入口）。
  /// 行式样仿「高级安全」弹层（ListTile + pop 值），尾部带当前值。
  Future<void> _showMoreSettingsSheet() async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showModalBottomSheet<String>(
      context: context,
      // 允许用满窗高（与「高级安全」「我的设备通道」等弹层同口径）
      isScrollControlled: true,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        final valueStyle = TextStyle(fontSize: 12, color: scheme.outline);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 标题居中（与其它选项弹层口径一致）
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                child: Center(
                  child: Text(l10n.chatPageMoreSettingsTitle,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 16)),
                ),
              ),
              // 行尾当前值 + >：> 与顶层菜单的二级入口标识同款（老板 2026-10-15），
              // 暗示点进去还有下一级（各自的选择器）
              ListTile(
                leading: const Icon(Icons.attach_file_outlined),
                title: Text(l10n.chatPageMoreSettingsStorage),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                        _attachmentStorageLabel(_attachmentStorage, l10n),
                        style: valueStyle),
                    const SizedBox(width: 2),
                    const Icon(Icons.chevron_right, size: 18),
                  ],
                ),
                onTap: () => Navigator.of(ctx).pop('storage'),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: Text(l10n.chatPageMoreSettingsTombstone),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_tombstoneDisplayLabel(l10n), style: valueStyle),
                    const SizedBox(width: 2),
                    const Icon(Icons.chevron_right, size: 18),
                  ],
                ),
                onTap: () => Navigator.of(ctx).pop('tombstone'),
              ),
              // 底部留白（同「高级安全」弹层：末行不贴屏幕底边）
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
    if (picked == null || !mounted) return;
    // 与弹层关闭动画错开再开下一个弹层（Overlay 交叉卸载断言，同 _menuAction）
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    if (picked == 'storage') {
      await _showAttachmentStoragePicker();
    } else if (picked == 'tombstone') {
      await _showTombstonePicker();
    }
  }

  /// 墓碑消息显示模式当前值的展示文案（与选择器选项同名）。
  String _tombstoneDisplayLabel(AppLocalizations l10n) =>
      _tombstoneDisplay == 'hide'
          ? l10n.chatPageTombstoneHide
          : l10n.chatPageTombstoneKeep;

  /// 墓碑消息显示模式：**点选即生效**（无提交按钮——纯显示开关，无副作用数据
  /// 操作；同阅后即焚档位弹层）。选完即存即重建消息流。
  Future<void> _showTombstonePicker() async {
    final l10n = AppLocalizations.of(context)!;
    var picked = _tombstoneDisplay;
    var appliedToAll = false;
    await showOptionPickerSheet<void>(
      context: context,
      builder: (ctx) => OptionPickerSheet(
        title: l10n.chatPageTombstoneHeading,
        note: l10n.chatPageTombstoneNote,
        selected: _tombstoneDisplay,
        // 单选 + 提交（老板 2026-10-15：与附件存储同构——勾选框配提交按钮才
        // 防呆：提交前统一确认"选什么 + 作用域"）
        submitLabel: l10n.chatPageTombstoneSubmit,
        // 「应用于本机所有秘境」勾选框（提交按钮上方，提交时随 onApply 交出）。
        // 单秘境时不传 = 整个不渲染（老板 2026-10-17）
        scopeAllLabel: _hasMultipleSpaces ? l10n.settingsScopeAll : null,
        options: [
          OptionPickerItem(
            value: 'keep',
            label: l10n.chatPageTombstoneKeep,
            description: l10n.chatPageTombstoneKeepDesc,
          ),
          OptionPickerItem(
            value: 'hide',
            label: l10n.chatPageTombstoneHide,
            description: l10n.chatPageTombstoneHideDesc,
          ),
        ],
        onApply: (mode, {bool scopeAll = false}) async {
          picked = mode;
          appliedToAll = scopeAll;
          final settings = TombstoneSettings(widget.db ?? LocalDatabase.shared,
              spaceId: widget.spaceId);
          if (scopeAll) {
            // 勾了"所有秘境"：写全局键 + 清除各空间 per-space 覆盖
            await settings.saveAll(mode);
          } else {
            await settings.save(mode);
          }
        },
      ),
    );
    if (!mounted) return;
    // 模式没变就不重建（点着玩）；但"所有秘境"的确认照给——作用域落地本身
    // 就是效果，哪怕模式没变（勾选后点了同一个档位）
    if (picked != _tombstoneDisplay) {
      setState(() => _tombstoneDisplay = picked);
    }
    if (appliedToAll) {
      _notice(context, l10n.settingsScopeAllDone);
    }
  }

  /// 菜单行右侧「当前值」：超过 [kMenuValueMaxWidth] 即省略号、右对齐。
  ///
  /// 名字 / 通道名是用户可任意填的长文本，原先直接 `Text(value)` 无上限 → 撑破
  /// PopupMenu（老板 2026-09-24 实测 `right overflowed by 69 pixels`）。这里收口：
  /// **整菜单所有带值的行共用同一个上限**，不逐行各设一个数。
  Widget _menuValue(String value, TextStyle style) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kMenuValueMaxWidth),
        child: Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.end,
          style: style,
        ),
      );

  


  /// 顶栏的「品牌名（+ 多空间图标）」这一块。
  ///
  /// **任何空间数都画图标、都可点** → 打开「切换我的秘境」弹层（老板
  /// 2026-10-12：单空间也加，与多空间一致——图标是"空间弹层"的入口，
  /// 不是"有多个空间"的暗示，推翻 2026-09-24 的"单空间不可点"）。
  /// 图标放在标题文字右侧（老板 2026-09-28：原先是独立 IconButton，
  /// 自带的 8px 内边距把箭头推得很远，不像和标题是一体的）。
  Widget _brandTitle() {
    final l10n = AppLocalizations.of(context)!;
    final titleRow = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 11),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(l10n.chatPageTitleBrand,
                style: const TextStyle(fontSize: 17),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          // 颜色继承 AppBar 的 IconTheme（AppBar 给整个 toolbar 套了 IconTheme.merge）
          // 6px：旧小箭头（arrow_drop_down）字形小、图标框自带留白，视觉间隙
          // 差不多是这个数；换成 dynamic_feed 后字形几乎满框，2px 会紧贴标题
          // （老板 2026-10-09：不好看，留回小箭头时的间距）。
          const SizedBox(width: 6),
          // 与汉堡菜单「切换我的秘境」行同款图标（dynamic_feed 多窗口叠加，
          // 老板 2026-09-28 定稿）
          const Icon(Icons.dynamic_feed, size: 20),
        ],
      ),
    );
    return Tooltip(
      message: l10n.spaceListSwitch,
      child: InkWell(mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(10),
        onTap: _openSpacePicker,
        child: titleRow,
      ),
    );
  }

  /// 状态条上的头像。
  ///
  /// 边长 = [kStatusAvatarSize]：跟随"名字 + 红绿灯"两行的高度，**上下不留白**，
  /// 看着像嵌在胶囊两端（老板 2026-09-26）。
  ///
  /// - 没设头像时，底色按**性别**取淡粉/淡蓝（与空间卡片、状态芯片同一组色），
  ///   未登记性别回退淡灰；
  /// - 有头像时可点开**全屏大图**（老板 2026-09-26）；
  /// - [icon] 覆盖"没头像时"的默认图标（群空间用 `Icons.groups_outlined`）。
  /// - [saveName] 全屏大图「保存」图标圆钮用的文件名（通常传对方的显示名）。
  Widget _statusAvatar({
    Uint8List? bytes,
    String gender = '',
    VoidCallback? onTap,
    IconData icon = Icons.person,
    String? saveName,
  }) {
    return _StatusAvatar(
      bytes: bytes,
      tint: _genderTint(gender),
      icon: icon,
      // 默认：有头像才可点（看大图）；本人那头像由调用方传入 onTap（空头像也能点）
      onTap: onTap ??
          (bytes == null
              ? null
              : () => unawaited(_showAvatarFullscreen(bytes, saveName: saveName))),
    );
  }

  /// 性别底色：淡粉（女）/ 淡蓝（男）/ 淡灰（未登记）。
  /// 用**预乘到白的不透明色**，与状态芯片、空间卡片同一组（品牌粉 #D6529C /
  /// 品牌天蓝 #3BAFFD 的 18% tint）——半透明 tint 叠在 85% 白的胶囊上会透出背景
  /// 混色、观感发脏（老板 2026-09-25 模拟器实测）。
  Color _genderTint(String gender) {
    if (gender == 'female') return const Color(0xFFF8E0ED);
    if (gender == 'male') return const Color(0xFFDCF1FF);
    return const Color(0xFFF1F1F1);
  }

  /// 全屏看头像大图：状态条头像入口（老板 2026-10-17 起走**共享**的
  /// [showMyAvatarFullscreen]——与消息气泡旁头像 / 「我的资料」弹层头像同一份
  /// 实现，不再各写一套）。
  ///
  /// [allowReplace]：**本人的**头像为 true → 大图带「更换头像」和
  /// 「应用于本机所有秘境」按钮（后者把这份头像扇出到本机其它秘境）。
  /// 对方的头像不传这些回调——我们没有权限改别人的头像。
  /// 「保存」图标圆钮三处一致都给（[saveName] 是保存用的文件名）。
  Future<void> _showAvatarFullscreen(Uint8List bytes,
      {bool allowReplace = false, String? saveName}) async {
    await showMyAvatarFullscreen(
      context,
      bytes: bytes,
      onReplace:
          allowReplace ? () => unawaited(_showAvatarUpload()) : null,
      // 扇出用的就是全屏展示的这份 bytes（不再另读 _myAvatarBytes——状态可能
      // 已变，扇出去的必须和用户看的一致）；单秘境时按钮不出现
      onApplyAllSpaces: allowReplace && _hasMultipleSpaces
          ? (b) => _applyAvatarAllSpaces(b)
          : null,
      onSave: (b) => _saveAvatarImage(saveName, b),
    );
  }

  /// 状态灯 + 时刻（老板 2026-09-26 新设计）：**绿灯旁是上线时间、红灯旁是下线时间**。
  ///
  /// [sinceMs] 缺失（还没问到 / 服务端没给）就只留灯：宁可少显示，也不摆一个假的
  /// 00:00。格式复用 [_timeStampLabel]——当天 `HH:MM`、当年 `mm-dd HH:MM`、跨年带年份。
  /// [label] 用于"既不在线也不是普通离线"的状态（当前只有**对方尚未加入**）：
  /// 灯变灰、右侧显示这个短标签而不是时间（老板 2026-09-26：未加入时时间没有意义，
  /// 摆一个"上次离线时间"反而误导）。
  /// [connecting] 黄灯 = 正在连接（老板 2026-10-08：与 TUI「我的灯」统一四态思维
  /// 模型——灰=未连接服务 / 黄=连接中 / 绿=已连接 / 红=断线重连）；「我的」灯传
  /// WsStatus 得到，对方灯无此态。
  Widget _statusLine({
    required bool online,
    Color offlineColor = Colors.red,
    bool connecting = false,
    int? sinceMs,
    String? label,
  }) {
    final dotColor = label != null
        ? Colors.grey
        : (online ? Colors.green : (connecting ? Colors.amber : offlineColor));
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, size: 8, color: dotColor),
        if (label != null) ...[
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: Colors.black.withValues(alpha: 0.55),
            ),
          ),
        ] else if (sinceMs != null && sinceMs > 0) ...[
          const SizedBox(width: 4),
          Text(
            _timeStampLabel(sinceMs),
            style: TextStyle(
              fontSize: 11,
              color: Colors.black.withValues(alpha: 0.55),
            ),
          ),
        ],
      ],
    );
  }

  /// 群空间状态条左侧（老板 2026-10-09 改）：**成员头像条 + 两行文字**。
  ///
  /// 布局：`[头像位] [ 名字列 ]`，名字列两行——
  /// - 第一行 = **群组名字**（样式同「我的状态胶囊」的名字行：15 号 w500）；
  ///   空名字时只显示一个**编辑图标**（点击进 [\_showGroupNameDialog] 起名）；
  /// - 第二行 = **「在线人数/总人数」**，「在线人数」用**绿色**（同在线灯），
  ///   「/总人数」保持原灰。两个数都不含我自己（`_othersOnline` / `_othersTotal`）。
  ///
  /// - 头像位**恒在**：有人加入 = 成员头像条（按**加入先后**槽位升序排，不含
  ///   我自己——我在右侧那一块）；还没人加入 = **群组头像占位**（groups_outlined
  ///   圆底，与菜单「我的同伴」图标同款）。两者都可点 → 「我的同伴」弹层。
  ///   占位必须占着 40px：否则编辑图标/人数直接顶到状态条胶囊左缘（老板实测）；
  /// - **整块最多占状态条一半宽**（老板：最多顶到一半宽的最右侧）。名字列的宽度
  ///   **先占**（信息，不参与截断），**剩下的给头像**；名字过长时省略、头像装不下
  ///   时末尾**渐隐**。
  Widget _othersSummary(AppLocalizations l10n) {
    // 状态条胶囊宽 = 屏宽 − 左右 margin（各 12）；左半 = 一半。
    // ⚠️ 这个 24 与状态条 Container 的 `margin: fromLTRB(12, 4, 12, 6)` 耦合，
    // 改 margin 要一起改（与 top_notice 那个 46 是同一类耦合）。
    //
    // 再扣掉 `_buildPeerStatus` 那层 Padding 的**右 10**（两处要一起改；左边距
    // 是 0——头像条左缘贴边，见 `_buildPeerStatus` 的 pad 注释）——不扣的话
    // 内容会超出可用宽 10px（实测 RenderFlex overflow 10px）。
    const leadingPad = 10.0;
    // 再扣掉大胶囊自己的水平 Padding（老板 2026-10-12 起只留右：头像三面贴壁、
    // 左 0；2026-10-19 右 6→12 与 duo 对称）——不扣的话 Row 内容会超出胶囊
    // （实测 RenderFlex overflow；此前左右各 6 = 12，头像贴壁后减半）。
    const capsulePad = 12.0;
    final maxWidth =
        (MediaQuery.sizeOf(context).width - 24) / 2 - leadingPad - capsulePad;

    // 12 号：比 duo 那行时刻（11）略大一档——这一格没有别的大字，11 会显得发飘
    final countStyle = TextStyle(
      fontSize: 12,
      color: Colors.black.withValues(alpha: 0.55),
    );
    // 名字行：与「我的状态胶囊」的名字行同款（15 号 w500）
    const nameStyle = TextStyle(fontSize: 15, fontWeight: FontWeight.w500);

    final others = _otherMembers;
    final countLabel = '$_othersOnline/$_othersTotal';

    // 量宽用 TextPainter（**不是** LayoutBuilder：这一格在 IntrinsicHeight 里，
    // 而 IntrinsicHeight 查不了 LayoutBuilder 的固有尺寸）。
    // 样式要**先并入环境 DefaultTextStyle**、再带上 **textScaler**——渲染端
    // `Text` 就是这么解析的（style 并入 DefaultTextStyle + MediaQuery 的
    // textScaler）。只用裸 style 量，量出的宽会偏小，名字就被提前截断
    // （老板 2026-10-09 macOS 实测：离中线还很远就出现省略号）。
    double measure(String s, TextStyle st) {
      final p = TextPainter(
        text: TextSpan(
            text: s, style: DefaultTextStyle.of(context).style.merge(st)),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      return p.width;
    }

    const gap = 8.0;
    // 编辑图标占位宽（左右各 2 内边距 + 18 图标）；没有名字时第一行只摆它——
    // 曾试过在图标前加灰字「群名」占位，老板体验后撤掉：有的群就是不想要名字，
    // 常驻占位文案反而是干扰（2026-10-09）。
    const editIconWidth = 22.0;
    final countWidth = measure(countLabel, countStyle);
    final nameWidth =
        _groupName.isEmpty ? editIconWidth : measure(_groupName, nameStyle);

    // 量出来的名字宽**只用来给头像分预算**（名字是信息、优先，剩下的给头像），
    // **不再拿来钉死名字列宽**——TextPainter 量出的宽与真实渲染可能有出入（字体
    // 回退/字距等），偏小会把名字提前截断（老板 2026-10-09 macOS 实测：离中线
    // 还很远就出现省略号）。名字列给「去掉头像位后剩下的全部宽度」，要不要
    // 省略由文本自己按真实渲染宽决定。
    //
    // 头像位**恒在**：有人加入 = 成员头像条；还没人加入 = 群组头像占位（同样
    // 40px）——没有这个占位，编辑图标/人数会直接顶到状态条胶囊左缘（老板
    // 2026-10-09 实测"顶到边缘之外"）。
    const avatarMin = kStatusMemberAvatarSize;
    var want = nameWidth > countWidth ? nameWidth : countWidth;
    final wantCap = maxWidth - avatarMin - gap; // 至少留一个头像位 + 间距
    if (want > wantCap) want = wantCap;
    if (want < 0) want = 0;
    final avatarBudget = maxWidth - want - gap;
    final stripCount =
        others.isEmpty ? 0 : _stripAvatarCount(avatarBudget, others.length);
    final slotWidth = others.isEmpty
        ? avatarMin
        : stripCount * kStatusMemberAvatarSize;
    final nameColMax = (maxWidth - slotWidth - gap).clamp(0.0, maxWidth);

    // 第一行内容：有名字显示名字；没名字只显示编辑图标（点了起名）。
    // （2026-10-11 老板：群名/编辑图标与在线人数合并成**一个大胶囊**，
    // 原「单独可点的名字/编辑图标胶囊」去掉——见下方 return 处的包裹。）
    Widget nameContent = _groupName.isEmpty
        ? Icon(Icons.edit,
            size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant)
        : Text(_groupName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: nameStyle);

    // 第二行：「在线人数」绿 + 「/总人数」灰（在线灯同色，一眼看出谁在）
    final Widget countLine = Text.rich(
      TextSpan(children: [
        TextSpan(
            text: '$_othersOnline',
            style: countStyle.copyWith(color: Colors.green)),
        TextSpan(text: '/$_othersTotal', style: countStyle),
      ]),
      maxLines: 1,
    );

    // 头像位：有人加入 = 成员头像条；还没人加入 = **群组头像占位**（老板
    // 2026-10-09）——图标与菜单「我的同伴」行的 `groups_outlined` 同款，尺寸同
    // 成员头像（40），圆底用性别未知的中性灰（`_genderTint('')`，与「待加入」
    // 卡片同源）。**已并入下方的大胶囊**（2026-10-11：头像条 + 群名/人数是
    // 同一个可点胶囊，整体打开「我的同伴」弹层——不再有独立的头像小胶囊）。
    // 空群占位头像自带 tooltip「我的同伴」；已有成员时头像条里每个头像自带
    // 人名 tooltip（`_stripAvatar`）。
    final Widget avatarSlot = others.isEmpty
        ? Tooltip(
            // 三个「我的群组/同伴」文案（菜单项/弹层标题/本 tooltip）共享
            // 同一键（老板 2026-10-11）
            message: l10n.chatPageMembersTitle('group'),
            child: SizedBox(
              width: kStatusMemberAvatarSize,
              height: kStatusMemberAvatarSize,
              // 圆底用 **Ink** 画（不是 CircleAvatar/Container）：Ink 画在
              // Material 的墨水层上，外层 InkWell 的悬浮/按住高亮才能盖在
              // 它上面——不透明 child 会把高亮整个挡住（老板 2026-10-09）
              child: Ink(
                decoration: BoxDecoration(
                  color: _genderTint(''),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.groups_outlined, size: 22),
              ),
            ),
          )
        : _avatarStrip(others, avatarBudget);

    // **一个大胶囊**（2026-10-11 老板）：多人头像条 + 群名/编辑图标 + 在线
    // 人数整体包进同一个 StadiumBorder 胶囊，悬浮/按住显色，点击打开
    // 「我的群组」弹层（改名走弹层里的群名行）。tooltip 与菜单项/弹层标题
    // 共享同一文案键（2026-10-11 老板）。
    return Tooltip(
      message: l10n.chatPageMembersTitle('group'),
      child: Material(
        color: Colors.transparent,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(mouseCursor: SystemMouseCursors.click,
          onTap: _showMembersSheet,
          hoverColor: Colors.black.withValues(alpha: 0.05),
          highlightColor: Colors.black.withValues(alpha: 0.08),
          child: Padding(
            // 只给右侧留白（头像条↔群名侧）：头像沿用「三面贴壁」约定（左/上/
            // 下贴住胶囊内壁，老板 2026-10-12）——与 duo 大胶囊同款。
            // 右侧 6→12（老板 2026-10-19：与 duo 对称，文字不贴胶囊右缘）。
            padding: const EdgeInsets.fromLTRB(0, 0, 12, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                avatarSlot,
                const SizedBox(width: gap),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: nameColMax),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      nameContent,
                      const SizedBox(height: 1),
                      countLine,
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 除我之外的成员：**在线的在前**，同在线内按"上线时刻"**新近优先**；离线的
  /// 沉底，同离线内按"下线时刻"**新近优先**；都拿不到时刻的按加入先后（槽位）兜底
  /// （老板 2026-10-06：最新上线的排最前，下线的放最后）。
  List<MapEntry<String, int>> get _otherMembers {
    int since(String memberId) => _otherSinceMs[memberId] ?? 0;
    int slotOf(MapEntry<String, int> e) => e.value;
    bool online(MapEntry<String, int> e) => _onlineOthers.contains(e.key);
    int compare(MapEntry<String, int> a, MapEntry<String, int> b) {
      // 在线组排前；同组内时刻大的（更近）排前；无时刻的按槽位（加入先后）
      final group = online(b) == online(a) ? 0 : (online(b) ? 1 : -1);
      if (group != 0) return group;
      final sa = since(a.key);
      final sb = since(b.key);
      if (sa != 0 || sb != 0) return sb.compareTo(sa);
      return slotOf(a).compareTo(slotOf(b));
    }

    // 只列**在册**成员（不含墓碑——退出的人不该还在头像条里，2026-10-19）
    return _activeMembers
        .where((e) => e.key != _myMemberId)
        .toList()
      ..sort(compare);
  }

  /// 头像条里的**一个**头像。
  ///
  /// 桌面端鼠标悬停时显示**这个头像对应的人名**（`Tooltip`；触屏没有 hover，
  /// 天然不触发——与项目"不做平台判断、靠 hover 只对有鼠标的设备生效"的惯例一致）。
  /// 名字查不到（未命名成员）回落「未命名」，与成员弹层同口径。
  ///
  /// [memberId] 该成员**至少有一条通道在线**（`_onlineOthers`）时，在头像上叠一圈
  /// **绿环**——与状态条那颗"在线"绿灯同色（`Colors.green`），一眼看出这一串里谁在。
  ///
  /// 环画在头像**内侧边缘**、占位尺寸仍是 [kStatusMemberAvatarSize]，**不变大**：
  /// 头像条按"每个都占满 32"来算装得下几个（含末尾渐隐那段的换算），尺寸一变这整套
  /// 都得跟着动，还容易被 `Flexible` 判溢出。代价是头像可见区被环吃掉约 2.5px，
  /// 在 32 的尺寸上可以接受（Instagram/故事环也是这个做法）。
  Widget _stripAvatar(String memberId) {
    final avatar = _MessageAvatar(
      memberId: memberId,
      server: effectiveServer,
      api: widget.api,
      radius: kStatusMemberAvatarSize / 2,
      // 点按不打开头像全览：状态条这一串的点按应落到外层「我的同伴」胶囊。
      // 否则**有头像图片**的成员（与在线与否无关）会被 `_MessageAvatar` 抢走点击、
      // 误开全览页（老板 2026-10-08 报：离线头像点了开全览）。
      openFullscreenOnTap: false,
    );
    final Widget visual = _onlineOthers.contains(memberId)
        ? SizedBox(
            width: kStatusMemberAvatarSize,
            height: kStatusMemberAvatarSize,
            child: Stack(
              fit: StackFit.expand,
              children: [
                avatar,
                DecoratedBox(
                  // key 供测试数"谁在线"（头像本身没有可断言的视觉属性）
                  key: ValueKey('statusAvatarOnline-$memberId'),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.green, width: 2.5),
                  ),
                ),
              ],
            ),
          )
        : avatar;
    final name = _senderNameOf(memberId);
    return Tooltip(
      message: name.isEmpty
          ? AppLocalizations.of(context)!.chatPageMembersUnnamed
          : name,
      child: visual,
    );
  }

  /// 其他成员的头像条。[budget] = 分给它的宽度上限（**已扣掉人数那一段**）。
  ///
  /// - 装不下时末尾**渐隐**（而非 "+N"）：头像没法像文字那样省略，渐隐既省地方
  ///   又不引入新文案，一眼看出"后面还有人"；
  /// - **只构建装得下的那几个**：群大了也不该为看不见的头像去拉图（每个头像都是
  ///   一次带缓存的异步取图）。
  /// 头像条在 [budget] 宽内摆几个（**只构建装得下的那几个**）。
  /// 渐隐换算（`_avatarStrip` 的 ShaderMask 宽度）与名字列的头像预算共用这套算法，
  /// 改 `size`/`fade` 要连着渐隐那段一起看。
  int _stripAvatarCount(double budget, int total) {
    const size = kStatusMemberAvatarSize;
    // 渐隐区宽度：够看出一截"淡下去"，又不至于吞掉一整个头像
    const fade = 16.0;
    final natural = total * size; // 头像之间不留空隙（老板 2026-10-06：像连排印章）
    // 兜底：budget 太小时至少摆一个（超过一点也不会撑破胶囊——它只是"一半宽"的软上限）
    final usable = natural > budget ? budget - fade : budget;
    var count = usable ~/ size;
    if (count < 1) count = 1;
    if (count > total) count = total;
    return count;
  }

  Widget _avatarStrip(List<MapEntry<String, int>> others, double budget) {
    const size = kStatusMemberAvatarSize;
    // 头像之间**不留空隙**（老板 2026-10-06：像连排印章，与右侧我方头像同高顶满）
    const gap = 0.0;
    // 渐隐区宽度：够看出一截"淡下去"，又不至于吞掉一整个头像
    const fade = 16.0;
    final natural = others.length * size + (others.length - 1) * gap;
    final truncated = natural > budget;

    final count = _stripAvatarCount(budget, others.length);
    final shown = others.take(count).toList();
    final stripWidth = shown.length * size + (shown.length - 1) * gap;

    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < shown.length; i++) ...[
          if (i > 0) const SizedBox(width: gap),
          _stripAvatar(shown[i].key),
        ],
      ],
    );
    if (!truncated) return row;

    // 渐隐：`BlendMode.dstIn` + 不透明→透明的渐变（白 = 留、透明 = 丢）
    final fadeStart = ((stripWidth - fade) / stripWidth).clamp(0.0, 1.0);
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) => LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: const [Colors.white, Colors.white, Colors.transparent],
        stops: [0, fadeStart, 1],
      ).createShader(rect),
      // 定宽 = 头像条的自然宽：Row 恰好放得下，不会触发溢出（否则 Flex 会报黄条）
      child: SizedBox(width: stripWidth, height: size, child: row),
    );
  }

  /// 顶栏状态条左侧的「对方」这一块。
  ///
  /// - **2 个及以上空间** → 做成可按芯片（底色按对方性别取**淡粉/淡蓝** + 右侧圆角
  ///   + 下拉箭头），一点打开「选择秘境」弹层（老板 2026-09-24：省掉「☰ → 眼扫菜单 →
  ///   点切换」，与微信「左上角返回→选人」同一肌肉记忆）。位置放**对方名字**旁：空间
  ///   卡片上显示的就是对方名字，语义同源。
  /// - **只有 1 个空间** → 纯"圆点 + 名字"，**不给箭头、不给底色**（老板 2026-09-24：
  ///   单空间往往就是想和一个人用，别暗示这里能切；真要加空间去汉堡菜单里找）。
  ///
  /// 空间数取自内存里已解锁的 [VaultSession]（不触安全存储、不需要 PIN）；
  /// 取不到时（如测试直接构造 ChatPage）按单空间处理——最保守，入口仍在菜单里。
  Widget _buildPeerStatus(AppLocalizations l10n) {
    // 左/上/下都 0：这一格以**头像**打头，头像要**三面贴住胶囊内壁**（老板
    // 2026-09-26）；右 10 给箭头/右缘留白。行高由头像决定，头像即贴边。
    //
    // **群空间例外**（老板 2026-10-05；2026-10-09 改两行）：左侧摆**成员头像条**
    // + 右侧两行（群组名字 / 在线·总数），整块**竖直居中**（头像比胶囊矮）。
    // 左边距与 duo 同为 0（头像条左缘贴边）——2026-10-09 曾改成 left:10 再用
    // Transform 左移 10 补偿，胶囊收窄到只包头像条后那 10px 会灌进"头像↔群名"
    // 的视觉间距（比右侧"我的头像↔我的名字"明显宽），已一并收回。
    final pad = _isGroup
        ? const EdgeInsets.fromLTRB(0, 0, 10, 0)
        : const EdgeInsets.fromLTRB(0, 0, 10, 0);
    // 芯片内容**只到箭头为止**（老板 2026-09-25）：「邀请加入」链接在芯片外
    // 并排（见本方法末尾）——否则点它到底是邀请还是切换空间说不清。
    final content = _isGroup
        // 群空间：成员头像条 + 两行（**群组名字** / **在线·总数**），见 _othersSummary。
        // Align 只为竖直居中（外层 stretch 给到满高 40，内容比胶囊矮）；
        // **必须 widthFactor:1**——Align 默认横向撑满约束，会把左半条占满、
        // 把「邀请加入」链接推到状态条正中（老板 2026-10-06 实测），
        // 收缩到内容宽后 invite 紧跟人数（与 duo 未加入时同款位置）。
        ? Align(
            alignment: Alignment.centerLeft,
            widthFactor: 1.0,
            child: _othersSummary(l10n))
        : Tooltip(
            // 大胶囊 tooltip 与「My companion」弹层标题、菜单项共享同一文案键
            // chatPageMembersTitle('duo')（老板 2026-10-11，与 group 空间同款）。
            message: l10n.chatPageMembersTitle('duo'),
            child: Material(
              color: Colors.transparent,
              shape: const StadiumBorder(),
              clipBehavior: Clip.antiAlias,
              // 整块可点：头像 + 名字/在线状态一体，点击打开「My companion」弹层
              //（老板 2026-10-11：与 group 空间大胶囊同款交互）。
              child: InkWell(
                mouseCursor: SystemMouseCursors.click,
                onTap: _showMembersSheet,
                hoverColor: Colors.black.withValues(alpha: 0.05),
                highlightColor: Colors.black.withValues(alpha: 0.08),
                child: Padding(
                  // 右侧留白（头像↔名字间距 + 文字↔胶囊右缘）：头像沿用 duo 的
                  // 「三面贴壁」约定（左/上/下贴住胶囊内壁，老板 2026-09-26）——与
                  // group 大胶囊的 horizontal 6 不同（那边没有贴壁要求）。
                  // 右侧 6→12（老板 2026-10-19：名字/时间贴着胶囊右缘，没有内部留白）。
                  padding: const EdgeInsets.fromLTRB(0, 0, 12, 0),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 头像放**最左**（老板 2026-09-26 新设计）。**不用**
                      // `_statusAvatar`（它自带 MouseRegion 悬浮变色/点击）：
                      // 大胶囊（2026-10-12 老板）是**一个整体**，悬浮/点击都归
                      // 外层 InkWell——头像用 Ink 画在 Material 墨水层上（与群
                      // 占位头像同款），外层悬浮高亮才能盖在头像上面。
                      // ⚠️ 照片**不能用** `Ink.image + ClipOval`：Ink 画在 Material
                      // 墨水层画布上，不经过 widget 树里的 ClipOval——照片会糊成
                      // 方块（老板 2026-10-12 实测）。要圆就让 Ink 自己的
                      // decoration 是圆的（与下面无图分支同一口径）。
                      SizedBox(
                        width: kStatusAvatarSize,
                        height: kStatusAvatarSize,
                        child: _peerAvatarBytes != null
                            ? Ink(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  image: DecorationImage(
                                    image: MemoryImage(_peerAvatarBytes!),
                                    fit: BoxFit.cover,
                                  ),
                                ),
                              )
                            : Ink(
                                decoration: BoxDecoration(
                                  color: _genderTint(_peerGender),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.person, size: 22),
                              ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_peerName.isNotEmpty)
                              Flexible(
                                child: Text(_peerName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    // 15 号：要**明显大于**下面的状态行（11）但不喧宾夺主
                                    // ——名字是这一格的主信息，原来 13 与 11 几乎看不出主次
                                    // （老板 2026-09-26）
                                    style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w500)),
                              ),
                            const SizedBox(height: 1),
                            // 绿灯旁是上线时间、红灯旁是下线时间（老板 2026-09-26 设计）；
                            // **对方尚未加入**时灯变灰、右侧显示「待加入 / Waiting」——时间
                            // 对未加入的人没有意义，摆个"上次离线时间"反而误导（2026-09-26）
                            _statusLine(
                              online: _peerOnline,
                              offlineColor: Colors.red,
                              sinceMs: _peerSinceMs,
                              label: _peerJoined == false
                                  ? l10n.memberPending
                                  : null,
                            ),
                          ],
                        ),
                      ),
                      // 切换秘境的入口**不在这里**——已挪到顶部标题栏「logo + 我的秘境」右侧
                      // （老板 2026-09-26：挂在对方名字旁边，点它等于"要换掉对方"，有点伤人）。
                    ],
                  ),
                ),
              ),
            ),
          );

    final Widget inviteLink = _peerJoined != false
        ? const SizedBox.shrink()
        : Material(
            color: Colors.transparent,
            shape: const StadiumBorder(), // 胶囊：随状态条高度自适应（写死 24 会变圆角矩形）
            clipBehavior: Clip.antiAlias, // 让 ink 跟着圆角裁
            child: InkWell(mouseCursor: SystemMouseCursors.click,
              // 群聊一期（2026-10-03）：purpose 必传——这一块是"邀请对方来这个
              // 秘境"，必须是 invite（开新身份）。漏传会退化成 attach（绑定
              // 我自己的身份），对方拿去加入就变成"我"（2026-10-04 审查实测）。
              onTap: () => _showInviteDialog(purpose: 'invite'),
              // 与「我的」状态芯片同一档（那块也没有常驻底色）
              hoverColor: Colors.black.withValues(alpha: 0.05),
              highlightColor: Colors.black.withValues(alpha: 0.08),
              child: Padding(
                // **不能共用左块的 `pad`**（那个是给头像定制的：左/上/下都是 0，
                // 好让头像三面贴住胶囊内壁）。共用会让这里的左内边距变成 0——
                // 按住时的底色紧贴着 "I"（老板 2026-09-26 实测）。
                // 文字链接用左右**匀称**的留白，底色两边都留得出来。
                padding: const EdgeInsets.symmetric(horizontal: 12),
                // 背景高度取控件的统一值（32）而不是头像的 40：胶囊形是满高直边，
                // 撑到 40 会直接贴住状态条的上下边缘（老板 2026-09-26 实测）
                child: SizedBox(
                  height: kStatusControlSize,
                  child: Center(
                    child: Text(l10n.chatPageInviteJoinLink,
                        style: const TextStyle(
                            fontSize: 12,
                            // 链接蓝 = 品牌深蓝 #2271F7，与通道码弹窗里那条邀请链接
                            // （本文件 `_showInviteDialog`）同一个蓝，语义同源。
                            color: Color(0xFF2271F7))),
                  ),
                ),
              ),
            ),
          );
    // 「语音通话」：对方**已加入**才挂（未加入时这块位置让给「邀请加入」——
    // 两个互斥，见下面的 `trailing`）。与 invite 同口径：常态无底色、同一档
    // hover/highlight、同一个 `pad`、同一个 24 圆角；蓝色电话图标（品牌深蓝
    // #2271F7 与 invite 链接同源），文字省掉——电话图标语义够明确，状态条也挤。
    //
    // 群聊一期（2026-10-03）：**群空间不挂**——群内通话一期不做，服务端也会
    // 静默丢弃 call.* 信令（挂出来点了没人接，只能干等超时）。
    final Widget callButton = _peerJoined == true && !_isGroup
        ? Tooltip(
            message: l10n.voiceCallMenuCall,
            child: Material(
              color: Colors.transparent,
              shape: const CircleBorder(), // 真圆：状态条加高后 24 圆角成了圆角矩形
              clipBehavior: Clip.antiAlias,
              child: InkWell(mouseCursor: SystemMouseCursors.click,
                onTap: _startVoiceCall,
                hoverColor: Colors.black.withValues(alpha: 0.05),
                highlightColor: Colors.black.withValues(alpha: 0.08),
                child: const SizedBox(
                  width: kStatusAvatarSize,
                  height: kStatusAvatarSize,
                  child: Icon(Icons.call_outlined,
                      size: 20, color: Color(0xFF2271F7)),
                ),
              ),
            ),
          )
        : const SizedBox.shrink();

    // 芯片右侧挂一块：**未加入=邀请加入 / 已加入=语音通话**（老板 2026-09-26）。
    // 对方加入状态未知（null）时两块都不挂——与 invite 原本的口径一致，
    // 避免进页面先闪一下。
    final Widget trailing = _peerJoined == false ? inviteLink : callButton;

    // 芯片包 Flexible：本 Row 处于状态条 Flexible 的有界宽度里，非 flex 子项会被
    // Row 放到无界宽度 → 长名字不再被省略、冲出胶囊（长名字回归测试 2026-09-24）。
    // Flexible 让芯片先让出链接的宽度，剩下的给芯片内部继续省略。
    // 芯片**已去掉**（老板 2026-09-26）：对方这一格不再是"整块可按 + 常驻底色"的
    // 芯片，切换空间的入口交给箭头自己（见 content 里那个箭头按钮）。这样底色不再
    // 与头像的性别底色打架，也不会让人误以为点名字/头像能切换空间。
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Flexible(child: Padding(padding: pad, child: content)),
      // 与「名字/状态」的间距：靠 pad.right(10) + Invite 自带的内边距(12) = 22px。
      // **两侧要一样宽**（老板 2026-09-26）——此前这里额外加了 12px，导致对方一侧
      // 的间距（34）明显比我方（22）宽，看着不匀。
      trailing,
    ]);
  }

  /// 「切换空间」：弹「选择秘境」弹层（小卡片瀑布流）→ 选中即**直接换到那个空间**（不跳页）。
  /// 弹层底部还有「＋ 新建/加入空间」通往第一屏（需要先过一次锁屏码，见 addSpaceFlow）。
  ///
  /// 不再需要 `onSwitchSpace` / `onManageSpaces` 这类"由入口注入"的回调：切换空间**不需要
  /// 锁屏码**（当前空间落明文键），其它空间的凭证在内存会话 [VaultSession] 里。
  Future<void> _openSpacePicker() async {
    final pick = await showSpacePicker(context, db: widget.db, api: widget.api);
    // 弹层关掉后刷新一次未读（可能刚切过空间，也可能只是看了看）
    unawaited(_refreshOtherUnread());
    if (!mounted || pick == null) return;
    if (pick.add) {
      await addSpaceFlow(context, db: widget.db, api: widget.api);
      return;
    }
    final id = pick.spaceId;
    if (id == null || id == widget.spaceId) return; // 选的是当前空间：什么都不做
    await switchToSpace(context, id, db: widget.db);
  }

  /// 顶栏 🎨：切换界面主题（素雅纯色/渐变粉蓝）。弹窗内点选即生效并立即关闭，
  /// 回到对话消息页（老板要求 2026-09-13；此前是保持打开供边看边试）。
  Future<void> _showStylePicker() async {
    await showModalBottomSheet<void>(
      context: context,
      // 允许用满窗高（与「我的通道」等弹层同口径，老板 2026-10-02）
      isScrollControlled: true,
      builder: (_) => UiStylePickerSheet(
        settings: UiStyleSettings(widget.db ?? LocalDatabase.shared),
      ),
    );
  }

  /// 开通通道：生成一次性 join token（POST /spaces/{id}/join-tokens，Multiverse
  /// v2，24h 一次性、需本人会话认证；旧 v1 createInvite 已废弃，不再生成 v1 邀请码）。
  /// 二维码与展示内容 = 邀请链接（`https://einz.tic.cc/join/<token>`），对方 App/
  /// CLI 可扫码或粘贴链接加入；口令由对方加入时另行输入（降级 B，与 TUI 一致）。
  ///
  /// [purpose]（2026-10-04 收敛）：`invite` = 开**新身份**（邀请新成员）；
  /// `attach` = 进**已有身份**（缺省=我自己换设备；指向别人 = 帮对方找回）。
  /// **必传**：两种码语义相反，share 错一种等于把对方变成我（2026-10-04 审查
  /// 实测的 P0）。弹层内「重新生成」必须沿用同一组参数。
  ///
  /// [targetMemberId] / [passphrase]（2026-10-04 定向 token）：`attach` 指向
  /// **别人**时用——passphrase 是"对别人的身份动手"的授权因子，由调用方先向
  /// 用户要到（见 [_promptSharedPassphrase]）。
  ///
  /// [targetName] 仅用于**找回**场景的说明文案（"把这个码发给「X」"）。调用方
  /// 已经知道要找的是谁，顺手传进来；缺省（拿不到名字）则文案退成"对方"。
  ///
  /// 呈现为**底部弹层**（老板 2026-10-15，原来是 AlertDialog）：无输入框，点
  /// 遮罩/下滑即关，故底部不放「关闭」按钮，只留一个居中、不占满宽度的
  /// 「重新生成」（可按可不按，不做成满宽提交按钮那种"必须决定"的口气）。
  /// 布局与 OptionPickerSheet 同口径：标题+备注固定在顶部（备注归标题组、
  /// 居中、不滚动），中部（二维码/通道码/链接）Flexible+ListView 内部滚动，
  /// 「重新生成」固定底部——矮窗不溢出、常用入口不滚走。
  Future<void> _showInviteDialog({
    required String purpose,
    String? targetMemberId,
    String? targetName,
    String? passphrase,
  }) async {
    // 老板决策：点顶栏添加按钮直接生成通道码（不再先弹"开通通道"确认窗）
    try {
      final api = widget.api ?? ApiClient(effectiveServer);
      var r = await _withAuth((t) => api.createJoinToken(
            widget.spaceId,
            t,
            purpose: purpose,
            targetMemberId: targetMemberId,
            passphrase: passphrase,
          ));
      if (!mounted) return;
      // 「重新生成」进行中的标记（放在 builder 外：StatefulBuilder 用箭头函数，没地方声明）
      var busy = false;
      final l10n = AppLocalizations.of(context)!;
      // 三种场景各说各的话（老板 2026-10-04：原来标题/说明是共享的，
      // "发送给伴侣或自己的其他设备"会把小白绕晕——尤其是**找回**：码不该发给
      // 伴侣本人以外的人，而 invite 的码给错人等于让陌生人进群）。判定规则：
      //   invite              → 邀请加入（开新身份）
      //   attach + 目标是别人 → re-invite（再次邀请：帮对方在新设备加入）
      //   attach + 缺省/是我  → 我的新通道码（我本人在新设备加入）
      final isReinvite = purpose == 'attach' &&
          targetMemberId != null &&
          targetMemberId != _myMemberId;
      final title = isReinvite
          ? l10n.chatPageInviteDialogTitleReinvite
          : purpose == 'invite'
              ? l10n.chatPageInviteDialogTitleInvite
              : l10n.chatPageInviteDialogTitleAttachSelf;
      final hint = isReinvite
          ? l10n.chatPageInviteDialogHintReinvite(
              (targetName ?? '').trim().isEmpty
                  ? l10n.chatPageInviteDialogReinviteFallbackName
                  : targetName!.trim())
          : purpose == 'invite'
              ? l10n.chatPageInviteDialogHintInvite
              : l10n.chatPageInviteDialogHintAttachSelf;
      await showModalBottomSheet<void>(
        context: context,
        // 允许用满窗高（与「我的通道」「更多设置」等弹层同口径，老板 2026-10-02）
        isScrollControlled: true,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setLocal) {
            final scheme = Theme.of(ctx).colorScheme;
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 标题居中（与其它选项弹层口径一致）
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 5),
                    child: Center(
                      child: Text(title,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 16)),
                    ),
                  ),
                  // 标题下的备注（与 OptionPickerSheet 的 note 同款口径）：
                  // **固定不随中部滚动**——贴着标题（上 0）、离内容远一点（下
                  // 14）、居中，表明它归标题那一组，不是内容主体（老板
                  // 2026-10-15：各弹层口径一致，备注不滚）
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 14),
                    child: Center(
                      child: Text(
                        hint,
                        // 换行后的每一行都要居中（Center 只管整块，不管行内对齐）
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12, height: 1.4, color: scheme.outline),
                      ),
                    ),
                  ),
                  // 中部（二维码+通道码+链接）**可滚动**：Flexible(loose) +
                  // ListView(shrinkWrap)——内容短时贴着内容（弹层不撑高），窗口
                  // 矮/内容超高时在这一块内部滚动，不再整体溢出（老板 2026-10-15
                  // 实测：高度不够时 bottom overflowed 且无法滚动）。标题、备注与
                  // 「重新生成」固定在两端：它们是随时要用的入口，滚出去找不回来
                  // （与 ScrollableCardArea 同一套路，见其注释）。
                  Flexible(
                    fit: FlexFit.loose,
                    child: Scrollbar(
                      child: ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 14),
                        children: [
                          // 自绘二维码：QrImageView 的 LayoutBuilder 会触发固有尺寸
                          // 异常（见 _InviteQrCode 注释），此处不用它
                          Center(child: _InviteQrCode(data: r.link)),
                          const SizedBox(height: 12),
                          // 顺序（老板 2026-09-22）：**纯通道码在上、邀请链接在下**——
                          // 多数人是直接复制通道码；链接留给『点开看邀请页』的场景。
                          Row(
                            children: [
                              Expanded(
                                child: SelectableText(r.joinToken,
                                    // 通道码是主体：颜色深（跟随主题 onSurface，浅色下近黑）+ 加粗；
                                    // 字号与链接同为 12——老板 2026-09-22：16 号太大，回到 12
                                    style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        letterSpacing: 0.5,
                                        color: scheme.onSurface)),
                              ),
                              IconButton(
                                icon: const Icon(Icons.copy, size: 16),
                                color: scheme.onSurfaceVariant,
                                tooltip: l10n.chatPageInviteCopyCodeTooltip,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                visualDensity: VisualDensity.compact,
                                onPressed: () async {
                                  await Clipboard.setData(ClipboardData(text: r.joinToken));
                                  if (!ctx.mounted) return;
                                  _notice(ctx, l10n.chatPageInviteCodeCopied);
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          // 邀请链接 + 拷贝图标（点击即复制，弹层不关闭——根 Overlay 通知
                          // 在弹层之上可见，老板 2026-09-11）
                          Row(
                            children: [
                              Expanded(
                                child: SelectableText(r.link,
                                    // 链接退为次要：字号 14 → 12（保留品牌蓝与加粗，保证小字也看得清）
                                    style: const TextStyle(
                                        fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF2271F7))),
                              ),
                              IconButton(
                                icon: const Icon(Icons.copy, size: 16),
                                color: const Color(0xFF2271F7),
                                tooltip: l10n.chatPageInviteCopyLinkTooltip,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                visualDensity: VisualDensity.compact,
                                onPressed: () async {
                                  await Clipboard.setData(ClipboardData(text: r.link));
                                  if (!ctx.mounted) return;
                                  _notice(ctx, l10n.chatPageInviteLinkCopied);
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  // 底部只要一个「重新生成」，**居中且不占满宽度**（老板 2026-10-15）：
                  // 附件存储那种满宽提交按钮是"必须做决定"的口气，而重新生成可按可不
                  // 按；关闭走弹层惯例外（点遮罩/下滑），不再给「关闭」按钮。
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: TextButton(
                      // 淡灰底+悬浮/按压变深（老板 2026-10-18）：与弹窗「取消」
                      // 按钮共用 grayButtonStyle，同类低强调按钮观感一致
                      style: grayButtonStyle().copyWith(
                        overlayColor: WidgetStateProperty.resolveWith((states) {
                          if (states.contains(WidgetState.pressed)) {
                            return Colors.black.withValues(alpha: 0.09);
                          }
                          if (states.contains(WidgetState.hovered)) {
                            return Colors.black.withValues(alpha: 0.05);
                          }
                          return Colors.transparent;
                        }),
                      ),
                      onPressed: busy
                          ? null
                          : () async {
                              if (busy) return; // 进行中：忽略重复点击
                              setLocal(() => busy = true);
                              try {
                                final fresh = await _withAuth((t) => api.createJoinToken(
                                      widget.spaceId,
                                      t,
                                      purpose: purpose,
                                      targetMemberId: targetMemberId,
                                      passphrase: passphrase,
                                    ));
                                if (!ctx.mounted) return;
                                r = fresh; // 就地刷新：二维码 / 通道码 / 链接 ✓
                                setLocal(() {});
                              } on ApiException catch (e) {
                                if (!ctx.mounted) return;
                                _notice(
                                    ctx, backendError(l10n, l10n.chatPageInviteFailed(e.message)));
                              } catch (e) {
                                if (!ctx.mounted) return;
                                _notice(ctx, l10n.chatPageInviteFailed('$e'));
                              } finally {
                                if (ctx.mounted) setLocal(() => busy = false);
                              }
                            },
                      child: busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2.4))
                          : Text(l10n.chatPageInviteRegenerate),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      _notice(context, backendError(l10n, l10n.chatPageInviteFailed(e.message)));
    } catch (e) {
      if (!mounted) return;
      _notice(
          context, AppLocalizations.of(context)!.chatPageInviteFailed('$e'));
    }
  }

  /// 补设/重设启动锁（跳过 PIN 后某天想设置时用；复用 PIN 表单）。
  /// 用当前会话的 Space Key 包 setPin 加密落盘（内部会清掉明文副本）。
  Future<void> _showSetLockDialog() async {
    final payload = AppLockPayload(
      spaceId: widget.spaceId,
      entranceId: widget.entranceId,
      spaceKeyB64: base64Encode(widget.spaceKey),
      keyVersion: widget.keyVersion,
      token: _session.token, // 会话里的**当前** token（不写旧副本进锁包）
      publicKeyB64: widget.publicKeyB64,
      privateKeyB64: widget.privateKeyB64,
    );
    // 弹窗内容抽为 _SetLockDialog（StatefulWidget）：controller 生命周期随 State
    // 卸载同步释放，避免"点设置后 dispose 竞态"（TextField 卸载动画中向已销毁
    // controller 加 listener → debugAssertNotDisposed / _dependents.isEmpty 红屏，
    // 2026-09-05 真机定位）。
    // 是否已设锁屏码**在开弹窗前读好再传进去**（老板 2026-09-14）：弹窗里要据此决定
    // 出不出现"当前锁屏码"验证框，异步读会有毫秒级窗口让验证被跳过
    final db = widget.db ?? LocalDatabase.shared;
    final hasPin = await AppLockService(db).isSetup;
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      // 含输入框：禁误触关闭（点外面/系统返回都不行），必须点按钮（老板 2026-10-15）
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: _SetLockDialog(
          payload: payload,
          db: db,
          hasPin: hasPin,
        ),
      ),
    );
    if (ok == true && mounted) {
      // 设置或清空成功：不再猜结果（此前写死 _hasPin=true，清空后菜单仍显示
      // 「已设置」——老板 2026-09-15 实测），按落盘后的真实状态刷新菜单
      await _refreshPinStatus();
      // 时长也可能刚被改（弹窗里的时长轴；只调时长也会回 true）——重载一遍，
      // 菜单右侧「已设置 · 时长」的显示随弹窗关闭即时刷新（老板 2026-10-18）
      await _loadLockSeconds();
    }
  }

  /// 刷新本机 PIN 状态（菜单项「PIN: 已设置/未设置」；initState 时读取）。
  Future<void> _refreshPinStatus() async {
    final has = await AppLockService(widget.db ?? LocalDatabase.shared).isSetup;
    if (!mounted || has == _hasPin) return;
    setState(() => _hasPin = has);
    // PIN 状态刚确定（如 initState 首读完成）→ 重排 idle 计时器：
    // 设了 PIN 才开始计（_armIdleLock 内会判 _hasPin），没设则清空
    _armIdleLock();
  }

  /// 恢复用户自选的锁屏时长（「设置锁屏码」弹窗的滚动轴写入；默认 30s）。
  /// 前台闲置锁与后台锁共用同一阈值：回填 [_lockSeconds]（idle Timer 下次重排生效）
  /// 与 [_lockTimer.backgroundLockSeconds]（回前台判定即时生效），并重排 idle。
  Future<void> _loadLockSeconds() async {
    final seconds = await AppLockService(widget.db ?? LocalDatabase.shared).loadLockSeconds();
    if (!mounted) return;
    setState(() => _lockSeconds = seconds);
    _lockTimer.backgroundLockSeconds = seconds;
    _armIdleLock();
  }

  /// 「邮件通知」菜单项右侧的当前值（没设置/没拉到 → null，不显示）。
  Widget? _notifyMenuValue(AppLocalizations l10n, TextStyle valueStyle) {
    final status = _notifyEmail;
    if (status == null || status.isNone) return null;
    if (status.isVerified) return _menuValue(l10n.chatPageNotifyOnValue, valueStyle);
    if (status.isPending) return _menuValue(l10n.chatPageNotifyPendingValue, valueStyle);
    return _menuValue(l10n.chatPageNotifyOffValue, valueStyle); // inactive（已退订/硬退信）
  }

  /// 拉取邮件通知状态（GET /notify/email）。best-effort：拉不到就保持原值/null——
  /// 它是菜单上一个装饰性的当前值，不值得为它弹任何错误（老板 2026-09 定的
  /// "可观测性放代码里，不放 UI"）。
  ///
  /// 刷新时机（**翻转只可能发生在 App 外面**，所以光靠 initState 一次不够）：
  ///   · initState
  ///   · 从后台回到前台（去浏览器点链接再回来，是最常见的那条路径）
  ///   · 打开设置弹窗前
  ///   · 保存/停用之后
  ///   · 还停在"待确认"时每 20s 轮询一次（见 [_syncNotifyTicker]，翻了就停）
  Future<void> _refreshNotifyEmail() async {
    if (!mounted || _session.token.isEmpty || effectiveServer.isEmpty) return;
    try {
      final api = widget.api ?? ApiClient(effectiveServer);
      final status = await _withAuth((t) => api.getNotifyEmail(t));
      if (!mounted) return;
      setState(() => _notifyEmail = status);
      _syncNotifyTicker();
    } catch (_) {
      // 离线/服务端未启用：保持未知
    }
  }

  /// 只在 `pending` 期间挂着 20s 的轮询：等那封确认邮件被点开。
  /// 一旦翻转（生效/没设置/已关闭）就撤掉——不给一个只在极少数时候有用的值常驻轮询。
  void _syncNotifyTicker() {
    final pending = _notifyEmail?.isPending ?? false;
    if (pending && _notifyTicker == null) {
      _notifyTicker = Timer.periodic(const Duration(seconds: 20), (_) {
        unawaited(_refreshNotifyEmail());
      });
    } else if (!pending && _notifyTicker != null) {
      _notifyTicker?.cancel();
      _notifyTicker = null;
    }
  }

  /// 把某个操作**扇出到本机其它空间**（2026-10-01 起的"按设备共享"一族共用：
  /// 邮箱通知、身份/通道改名）。逐空间走它自己的会话调 [action]，全部
  /// best-effort——某个空间会话过期/离线就跳过，不影响其它空间，也不打扰用户
  /// （与 _refreshNotifyEmail 同一条"装饰性功能不弹错"原则）。当前空间由调用方
  /// 自己处理，这里跳过。
  Future<void> _fanoutOtherSpaces(Future<void> Function(String token) action) async {
    final vault = VaultSession.current;
    final spaces = vault?.spaces ?? const <AppLockPayload>[];
    if (spaces.length < 2) return;
    for (final space in spaces) {
      if (space.spaceId == widget.spaceId) continue; // 当前空间已由调用方处理
      if ((space.token ?? '').isEmpty) continue;
      try {
        // 走各空间的会话（同 _refreshOtherUnread）：直接用 Vault 里的旧 token 会 401
        await SpaceSessions.ofPayload(space, db: widget.db).call(action);
      } catch (_) {
        // 单个空间失败不阻塞其余空间
      }
    }
  }

  /// 把本机其它空间的**本地 profile** 里某个字段改写（扇出改名用：服务端改了，
  /// 本地各空间的 profile 也得跟着改，否则切过去/重启后还是旧名）。逐空间
  /// loadProfile → 只替换 [memberName]/[entranceName] 之一 → saveProfile 整份
  /// 写回——saveProfile 是覆盖写，必须把原值带回去；mode/otherMembers/
  /// groupName 传 null = 保持原值（它们的"不知道就别抹掉"语义）。best-effort，
  /// 单个空间失败静默。Spaces 行的名字也由 saveProfile 一并更新（切空间卡片
  /// 显示的就是它）。
  Future<void> _rewriteOtherSpacesProfile(
      {String? memberName, String? entranceName}) async {
    final vault = VaultSession.current;
    final spaces = vault?.spaces ?? const <AppLockPayload>[];
    if (spaces.length < 2) return;
    final db = widget.db ?? LocalDatabase.shared;
    final lock = AppLockService(db);
    for (final space in spaces) {
      if (space.spaceId == widget.spaceId) continue; // 当前空间已由调用方处理
      try {
        final p = await lock.loadProfile(spaceId: space.spaceId);
        await lock.saveProfile(
          spaceId: space.spaceId,
          memberName: memberName ?? (p['memberName'] as String?) ?? '',
          peerName: (p['peerName'] as String?) ?? '',
          entranceName: entranceName ?? (p['entranceName'] as String?) ?? '',
          myGender: (p['myGender'] as String?) ?? '',
          peerGender: (p['peerGender'] as String?) ?? '',
          mySlot: (p['mySlot'] as int?),
          peerSlot: (p['peerSlot'] as int?),
          groupName: (p['groupName'] as String?) ?? '',
        );
      } catch (_) {
        // 单个空间失败不阻塞其余空间
      }
    }
  }

  /// 本机是否有 ≥2 个秘境：「应用于本机所有秘境」一族控件（各弹层勾选框 /
  /// 头像全屏按钮）只在多秘境时出现——单秘境时"应用所有"没有任何可作用的
  /// 对象，摆着纯误导（老板 2026-10-17）。与 [_fanoutOtherSpaces] 同一个
  /// 数据源（VaultSession 内存态，解锁后的聊天页里必然非空；取不到时按
  /// false 处理 = 不显示，保守方向）。
  bool get _hasMultipleSpaces =>
      (VaultSession.current?.spaces.length ?? 0) >= 2;

  /// 把当前头像扇出到本机其它秘境（老板 2026-10-17，头像全屏里的
  /// 「应用于本机所有秘境」按钮）：逐空间用 bytes 再走一遍 uploadAvatar。
  /// 与 _fanoutOtherSpaces 同款 best-effort——单个空间失败不影响其余，也不打扰
  /// 用户。当前空间在上传时已经处理过，这里跳过。
  Future<void> _applyAvatarAllSpaces(Uint8List bytes) async {
    final spaces = VaultSession.current?.spaces ?? const <AppLockPayload>[];
    if (spaces.length < 2) return; // 单秘境：没什么可扇出的（按钮本就不该出现）
    for (final space in spaces) {
      if (space.spaceId == widget.spaceId) continue; // 当前空间已处理
      if ((space.token ?? '').isEmpty) continue;
      try {
        await SpaceSessions.ofPayload(space, db: widget.db)
            .call((t) => ApiClient(effectiveServer).uploadAvatar(bytes, t));
      } catch (_) {
        // 单个空间失败不阻塞其余空间
      }
    }
    if (!mounted) return;
    _notice(context, AppLocalizations.of(context)!.settingsScopeAllDone);
  }

  /// 邮件通知设置（菜单项，2026-10-01）：填邮箱 → 服务端发一封确认信 → 点信里链接生效。
  ///
  /// **必须把"已填但没确认"这一档显示出来**：否则用户填完以为已经开了，其实一封也收不到。
  /// 已设置时额外给一个「停用」（DELETE）：停用即关弹窗、顶部发一条通知（老板 2026-10-15，
  /// 原地切回输入界面让人混淆）；改地址＝重开弹窗重填再保存。
  Future<void> _showNotifyDialog() async {
    final l10n = AppLocalizations.of(context)!;
    // 开弹窗前先拉一次最新状态：它可能已经在 App 外面被翻转（确认邮件点过了），
    // 而缓存的 `_notifyEmail` 还停在旧值上——照旧值弹窗会把用户带偏（比如又显示一遍
    // "待确认"，或者输入框里填着已经被删掉的地址）。
    await _refreshNotifyEmail();
    if (!mounted) return;
    final before = _notifyEmail;
    final ctrl = TextEditingController(text: before?.email ?? '');
    // 红字警示（空/格式不对/后台失败）与提交中标记，都只在弹窗内有效
    final error = ValueNotifier<String?>(null);
    final busy = ValueNotifier<bool>(false);
    // 「已设置 ↔ 未设置」两阶段（老板 2026-10-02）：已设置时输入框只读、只给「停用」。
    // 初始值取开弹窗时的状态；停用成功后弹窗直接关闭（老板 2026-10-15），不再原地切态。
    final active = !(before?.isNone ?? true);
    // 邮箱输入框的焦点节点（随弹窗释放）：只读态靠 TextField 的 canRequestFocus
    // 拦住聚焦——注意 TextField.initState 会用**自己的** canRequestFocus 覆写节点
    // 上的同名属性，所以两个都要给，只给节点会被重置掉（老板 2026-10-15）
    final emailFocus = FocusNode();
    // 应用范围勾选（老板 2026-10-02）：勾选＝本次保存/停用同步扇出到本机所有
    // 秘境；不勾＝只作用于当前秘境。**每次开弹窗都默认不勾选**（老板 2026-10-15）：
    // 纯一次性开关，不持久化——新空间自动继承邮箱的功能已取消（服务端地址级验证，
    // 老地址重填直接 verified、不再发确认信），扇出必须是每次显式 opt-in。
    // 服务端本来就是地址级验证 + 空间级绑定，扇不扇出纯客户端决定，不冲突。
    final allSpaces = ValueNotifier<bool>(false);
    // 正文语言：服务端不知道收件人读哪种语言，按本机界面语言上报（zh / 其它一律 en）
    final lang = Localizations.localeOf(context).languageCode == 'zh' ? 'zh' : 'en';

    final saved = await showDialog<bool>(
      context: context,
      // 含输入框：禁误触关闭（点外面/系统返回都不行），必须点按钮（老板 2026-10-15）
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Center(child: Text(l10n.chatPageNotifyTitle)),
          // 标题→备注 4 / 备注→内容 14（参考底部弹层的节奏；M3 默认标题→内容 16
          // 对"标题+备注"的弹窗偏大，备注贴内容又偏近——老板 2026-10-15）
          contentPadding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.chatPageNotifyHint,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(ctx).colorScheme.outline,
                ),
              ),
              const SizedBox(height: 14),
              // 已设置 → 只读；未设置 → 正常输入
              TextField(
                controller: ctrl,
                focusNode: emailFocus,
                readOnly: active,
                // 只读态**不许聚焦**（老板 2026-10-15）：readOnly 只挡键盘，不挡
                // 聚焦——默认点一下边框就变蓝，像能改其实不能。必须传给 TextField
                // 本身：它 initState 时会用自己的这个值覆写 focusNode 上的
                // canRequestFocus（只设节点会被重置掉）
                canRequestFocus: !active,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  labelText: l10n.chatPageNotifyEmailLabel,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) {
                  if (error.value != null) error.value = null;
                },
              ),
              // 应用范围勾选（老板 2026-10-02）：勾选＝本次保存/停用同步到本机
              // 所有秘境（原静态文案「保存后应用于本机所有秘境。」升级为可选项）。
              // 放在 Email 输入框下方（老板 2026-10-02）。
              // 2026-10-15：复用 LabeledCheckbox——与设置弹层的「应用于本机所有
              // 秘境」同模块、同居中式样，文案也收敛到共享键 settingsScopeAll。
              // **纯一次性开关**：不持久化、每次开弹窗默认不勾选（老板 2026-10-15；
              // 新空间自动继承邮箱的功能已一并取消）——扇出必须是每次显式 opt-in。
              // 单秘境时整个不渲染（没有"其它秘境"可同步，老板 2026-10-17）
              if (_hasMultipleSpaces)
                ValueListenableBuilder<bool>(
                  valueListenable: allSpaces,
                  builder: (_, all, _) => LabeledCheckbox(
                    value: all,
                    label: l10n.settingsScopeAll,
                    onChanged: (v) => allSpaces.value = v,
                  ),
                ),
              // 已填但还没点链接：这一档不点明，用户会以为已经生效
              if (before?.isPending ?? false) ...[
                const SizedBox(height: 10),
                Text(
                  l10n.chatPageNotifyStatePending,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(ctx).colorScheme.outline,
                  ),
                ),
              ],
              ValueListenableBuilder<String?>(
                valueListenable: error,
                builder: (_, err, _) => err == null
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          err,
                          style: const TextStyle(
                            color: Colors.red,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
              ),
            ],
          ),
          actions: [
            CancelButton(onPressed: () => Navigator.of(ctx).pop(false)),
            // 按钮互斥（老板 2026-10-02）：已设置只给「停用」，未设置只给「保存」。
            if (active)
              ValueListenableBuilder<bool>(
                valueListenable: busy,
                builder: (_, isBusy, _) => TextButton(
                  // 红底白字警告色（老板 2026-10-18）：停用是警告级动作；
                  // 不特地做小，大小与「取消」/「保存」提交按钮同款
                  style: TextButton.styleFrom(
                    backgroundColor: Theme.of(ctx).colorScheme.error,
                    foregroundColor: Theme.of(ctx).colorScheme.onError,
                    // 与「取消」/「保存」提交按钮同块头（96x50、17 号粗体，
                    // 同 main.dart 的 FilledButton 主题），不特地做小
                    minimumSize: const Size(96, 50),
                    textStyle: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                  onPressed: isBusy
                      ? null
                      : () async {
                          busy.value = true;
                          try {
                            final api = widget.api ?? ApiClient(effectiveServer);
                            await _withAuth((t) => api.deleteNotifyEmail(t));
                            if (!mounted) return;
                            // 勾选「应用于本机所有秘境」才扇出（老板 2026-10-02）；
                            // 不勾＝只停当前秘境，其它秘境的绑定原样保留
                            if (allSpaces.value) {
                              unawaited(_fanoutOtherSpaces(
                                  (t) => api.deleteNotifyEmail(t))); // 其它空间同步撤，best-effort
                            }
                            await _refreshNotifyEmail();
                            // 停用即关弹窗 + 顶部通知一句，与保存成功后的反馈一致
                            // （老板 2026-10-15；原地切回输入界面只会让人混淆）
                            if (ctx.mounted) Navigator.of(ctx).pop(true);
                            if (mounted) _notice(context, l10n.chatPageNotifyRemoved);
                          } on ApiException catch (e) {
                            if (ctx.mounted) {
                              error.value =
                                  backendError(l10n, l10n.chatPageNotifyFailed(e.message));
                            }
                          } catch (e) {
                            if (ctx.mounted) error.value = l10n.chatPageNotifyFailed('$e');
                          } finally {
                            busy.value = false;
                          }
                        },
                  // busy 期间请求要好几秒才回，换旋转图标，同保存按钮（老板 2026-10-01）
                  child: isBusy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2.4),
                        )
                      : Text(l10n.chatPageNotifyStop),
                ),
              )
            else
              ValueListenableBuilder<bool>(
                valueListenable: busy,
                builder: (_, isBusy, _) => FilledButton(
                  onPressed: isBusy
                      ? null
                      : () async {
                          final email = ctrl.text.trim();
                          if (email.isEmpty) {
                            error.value = l10n.chatPageNotifyEmptyError;
                            return;
                          }
                          // 本机先粗筛（服务端另有 400 兜底）：只卡"有 @ 且两段都非空、不含空格"
                          if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
                            error.value = l10n.chatPageNotifyInvalidError;
                            return;
                          }
                          busy.value = true;
                          try {
                            final api = widget.api ?? ApiClient(effectiveServer);
                            final status =
                                await _withAuth((t) => api.setNotifyEmail(email, t, lang: lang));
                            if (!mounted) return;
                            // 勾选「应用于本机所有秘境」才扇出（老板 2026-10-02）；
                            // 不勾＝只绑当前秘境，其它秘境不动
                            if (allSpaces.value) {
                              unawaited(_fanoutOtherSpaces(
                                  (t) => api.setNotifyEmail(email, t, lang: lang))); // 其它空间同步绑，best-effort
                            }
                            await _refreshNotifyEmail();
                            if (ctx.mounted) Navigator.of(ctx).pop(true);
                            if (mounted) {
                              _notice(
                                context,
                                status.isVerified
                                    ? l10n.chatPageNotifyDone(email)
                                    : l10n.chatPageNotifySent(email),
                              );
                            }
                          } on ApiException catch (e) {
                            if (ctx.mounted) {
                              error.value =
                                  backendError(l10n, l10n.chatPageNotifyFailed(e.message));
                            }
                          } catch (e) {
                            if (ctx.mounted) error.value = l10n.chatPageNotifyFailed('$e');
                          } finally {
                            busy.value = false;
                          }
                        },
                  // busy 期间请求要好几秒才回（服务端要发确认信），换成旋转图标，
                  // 否则按钮灰着没动静，用户会以为没点上（老板 2026-10-01）
                  child: isBusy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2.4),
                        )
                      : Text(l10n.chatPageEmailSubmit),
                ),
              ),
          ],
        ),
      ),
    );
    // 对话框 route 关闭动画完成后才 dispose（与改名弹窗同款：立刻 dispose 会触发
    // TextField 卸载后向已销毁 controller 加 listener 的红屏断言）
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      ctrl.dispose();
      emailFocus.dispose();
      error.dispose();
      busy.dispose();
      allSpaces.dispose();
    });
    if (saved == true && mounted) await _refreshNotifyEmail();
  }

  /// 修改口令（escrow 托管口令，空间级）：旧口令验证 → 新口令重加密上传
  /// （本地不落共享口令，与 TUI 对齐）。
  Future<void> _showChangePassphraseDialog() async {
    final changed = await showDialog<bool>(
      context: context,
      // 含输入框：禁误触关闭（点外面/系统返回都不行），必须点按钮（老板 2026-10-15）
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: _ChangePassphraseDialog(
          server: effectiveServer,
          spaceKeyB64: base64Encode(widget.spaceKey),
          spaceId: widget.spaceId,
          keyVersion: widget.keyVersion,
          spaceMode: _isGroup ? 'group' : 'duo',
          session: _session,
          api: widget.api,
          onPassphraseUpdated: (updatedAt) {
            if (mounted) _escrowUpdatedAt = updatedAt ?? _escrowUpdatedAt;
          },
        ),
      ),
    );
    if (changed == true && mounted) {
      _notice(context, AppLocalizations.of(context)!.chatPageChangePassphraseDone(_isGroup ? 'group' : 'duo'));
    }
  }

  /// 「让上一条 route 收完、再开下一条」的错峰等待。
  ///
  /// route 刚 pop、exit 动画还没跑完就直接 push 下一条（`showDialog` /
  /// `showModalBottomSheet`），两条 route 会在 Overlay 里**交叉卸载** → 触发
  /// `InheritedElement` 的 `_dependents` 断言（整屏红底黄字：framework.dart 的
  /// "check that it really is our descendant"）。300ms 取 Material 各类 route
  /// exit 动画的上界。（2026-09-05 首修；2026-10-05 re-invite 又踩到。）
  ///
  /// 凡是"弹层/弹窗里点一下 → 换另一个弹层/弹窗"的衔接都要过这里。
  static const Duration _kRouteHandoff = Duration(milliseconds: 300);
  Future<void> _waitRouteHandoff() => Future<void>.delayed(_kRouteHandoff);

  /// 过渡动作（fire-and-forget 版）：等上一条 route 收完再执行。
  void _menuAction(VoidCallback action) {
    unawaited(_waitRouteHandoff().then((_) {
      if (!mounted) return;
      action();
    }));
  }

  /// 对话页的通知：锚在**状态胶囊下方**（`kNoticeExtraTopBelowStatusBar`）。
  ///
  /// 胶囊里现在有可点对象（对方芯片 / 我方头像 / 未加入时的「邀请链接」），通知别再盖它
  /// （老板 2026-10-05 改版式；此前 2026-09-10 是"故意盖住状态条"以躲开标题栏的汉堡菜单）。
  /// 其它页面（向导 / 锁屏 / 重置）没有这条胶囊，继续用默认位置（AppBar 正下方）。
  void _notice(BuildContext context, String message,
          {Duration duration = const Duration(seconds: 4)}) =>
      showTopNotice(context, message,
          duration: duration, extraTop: kNoticeExtraTopBelowStatusBar);

  /// 「通道列表」底部弹层：**当前通道（带绿勾、列第一位）+ 我本人在本空间的其他通道**
  /// （老板 2026-09-25：多设备登录时一眼看到"我还有哪些线挂着、在不在线"；
  /// 即使只有自己一条通道也要显示自己；对方 member 的通道不列）。
  /// 每条通道 = **卡片**（边框 + 名称 + 状态红绿灯；本机那张右上角一个**绿勾**、恒列第一位）；
  /// 列表下方「新建通道」（与「切换我的秘境」弹层的「添加秘境」同款外观：
  /// 常态淡灰底、图标+文字居中）→ 生成通道码弹窗（_showInviteDialog）。
  ///
  /// 数据源 = GET /entrances（在线判定与顶栏同源：connected_at 非 null 即在线，
  /// 旧服务端无该字段时退回 last_seen<60s）。红绿灯：绿=在线 红=离线 灰=已撤销
  /// （已撤销的通道照列，并给整卡蒙版 + 右上角阻止图标）。
  /// 时间行：在线显示上线时刻，离线/已撤销显示**下线时刻**
  /// （max(last_seen, offline_since)，见卡片内注释）。
  /// 服务端拉不到时仍显示当前通道（离线不影响"我是谁"），只把其他通道区换成失败提示。
  ///
  /// **标题右端的「刷新」**（老板 2026-09-26）：就地重拉 /entrances 重建卡片——只想看
  /// "现在谁在线"时不用退出弹层，也不用等 30s 的对方在线轮询。为它把弹层主体套进
  /// StatefulBuilder（卡片/失败提示读它承载的可变状态），拉取逻辑收在 `load()` 里
  /// 供"初次打开"与"刷新"共用。
  /// 索要共享口令（2026-10-04）：**对别人的身份动手**时的授权因子——与"撤销
  /// 别人的通道"同一档（`revokeEntrance` 也要口令）。返回 null = 用户取消。
  ///
  /// 为什么不复用 `_ChangePassphraseDialog`：那个是"改口令"的完整表单（新旧两个
  /// 输入 + 轮换逻辑），这里只要一个"证明你是持口令者"的输入框。
  Future<String?> _promptSharedPassphrase({
    required String title,
    required String hint,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final ctrl = TextEditingController();
    var obscure = true;
    final ok = await showDialog<bool>(
      context: context,
      // 含输入框：禁误触关闭（点外面/系统返回都不行），必须点按钮（老板 2026-10-15）
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            title: Center(child: Text(title)),
            // 标题→备注 4 / 备注→内容 14（参考底部弹层的节奏；老板 2026-10-15）
            contentPadding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(hint, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 14),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  obscureText: obscure,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    hintText: l10n.chatPagePassphraseFieldHint,
                    suffixIcon: IconButton(
                      icon: Icon(obscure ? Icons.visibility_off : Icons.visibility),
                      tooltip: obscure
                          ? l10n.chatPagePassphraseShow
                          : l10n.chatPagePassphraseHide,
                      onPressed: () => setLocal(() => obscure = !obscure),
                    ),
                  ),
                  onSubmitted: (_) => Navigator.of(ctx).pop(true),
                ),
              ],
            ),
            actions: [
              CancelButton(onPressed: () => Navigator.of(ctx).pop(false)),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(MaterialLocalizations.of(ctx).okButtonLabel),
              ),
            ],
          ),
        ),
      ),
    );
    final text = ctrl.text.trim();
    // 对话框 route 关闭动画完成后才 dispose（TextField 卸载后不再依赖 controller；
    // 立即 dispose 会触发"向已销毁 controller 加 listener"的红屏断言——表现正是
    // **闪一下红底黄字又自己恢复**，因为错只发生在退出动画那几帧里）。
    // 与改名弹窗 / 设锁屏码弹窗同一手法（见 _showRenameEntranceDialog 等处的注释）。
    Future<void>.delayed(const Duration(milliseconds: 400), ctrl.dispose);
    if (ok != true || text.isEmpty) return null;
    return text;
  }

  /// 空间成员弹层。**group 与 duo 两套版式**（duo 2026-10-18 改版，老板定）：
  ///
  /// **group（我的群组）**：每行一张成员卡——底色=该成员性别色（男浅蓝 / 女浅粉 /
  /// 性别未知=中性灰）；左：真实头像 + 名字；右：可点的文字按钮（已有成员=
  /// 「重新邀请」）。
  /// - **不列我自己**；卡片流下方**不再**有独立的邀请/重新邀请按钮与说明；
  /// - 未满员时列表末尾是「邀请新同伴」大按钮；
  /// - **整张卡可点**（老板偏好：别让人去点中某个小控件）；
  /// - 群组满员时，末尾那张卡**变灰**（不可点、无按钮），只写「成员已满（n/m）」；
  /// - 「给自己加一台设备」不在这里（那是"我的线"，在菜单「我的通道」→「新建通道」）；
  /// - 底部「退出群组」红字项（2026-10-19 自愿退群）：**身份级**离场——本机数据
  ///   全清、同身份其他设备一并掉线自毁、历史消息留在别人设备上。duo 没有这项
  ///   （ duo 想离开只有「销毁本通道」，身份仍在册）。
  ///
  /// **duo（我的同伴）**：改走 [_showDuoPeerSheet]——与「我的资料」同款的单张
  /// 只读身份卡（duo 只有对方一个人，成员卡列表反而零碎）。
  Future<void> _showMembersSheet() async {
    if (!_isGroup) {
      await _showDuoPeerSheet();
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    // 其他**在册**成员（不含我、不含墓碑——退出者不该再列出来，2026-10-19），
    // 按加入先后（槽位升序 = 入群顺序）排
    final others = _activeMembers
        .where((e) => e.key != _myMemberId)
        .toList()
      ..sort((a, b) => a.value.compareTo(b.value));

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true, // 与「我的通道」等弹层同口径（老板 2026-10-02）
      builder: (ctx) {
        return SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Center(
                      child: Text(
                          l10n.chatPageMembersTitle(_isGroup ? 'group' : 'duo'),
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 16)),
                    ),
                  ),
                  // 群空间：成员列表前放「群名胶囊」行（老板 2026-10-17：与
                  // 「我的资料」弹层的名字胶囊同款——实底 + Material/InkWell 水波，
                  // 文字+编辑图标一眼可点）。底色淡蓝 tertiaryContainer（老板：
                  // 胶囊底不要粉色，淡蓝/灰皆可——两处胶囊统一淡蓝）。未设置 →
                  // 淡色占位词；点击打开改群名弹窗（同状态条点群名）。
                  if (_isGroup)
                    Padding(
                      padding: const EdgeInsets.only(top: 2, bottom: 14),
                      child: Center(
                        child: Material(
                          // 与「添加秘境」/「新建通道」/「邀请新同伴」大按钮同款淡灰
                          // （老板 2026-10-17：胶囊底也统一成淡灰，不再用淡蓝）
                          color: Colors.black.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(999),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            // key 供测试定位群名行（状态条上可能有同文案，需区分）
                            key: const ValueKey('membersSheetGroupNameRow'),
                            mouseCursor: SystemMouseCursors.click,
                            onTap: () {
                              // 先收起成员弹层；等它收完再弹改群名弹窗（同
                              // 「重新邀请」的 route 交接处理，见其注释）
                              Navigator.of(ctx).pop();
                              _menuAction(_showGroupNameDialog);
                            },
                            child: Padding(
                              padding:
                                  const EdgeInsets.fromLTRB(16, 9, 12, 9),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Flexible(
                                    child: Text(
                                      // 占位词与改群名弹窗标题共用同一键（老板
                                      // 2026-10-11：合并为一个文案「群组名称/
                                      // Group name」，不另设占位词键）
                                      _groupName.isEmpty
                                          ? l10n.chatPageGroupNameTitle
                                          : _groupName,
                                      style: TextStyle(
                                        // 占位词单独降档（老板 2026-10-11）：字号
                                        // 小一档 + 更浅的 outline 色，别与真群名
                                        // 的 20/w700 深色抢眼；有名字 → 胶囊里
                                        // 最显眼（20/w700，与「我的资料」名字
                                        // 胶囊同档）
                                        fontWeight: FontWeight.w700,
                                        fontSize: _groupName.isEmpty ? 18 : 20,
                                        height: 1.2,
                                        color: _groupName.isEmpty
                                            ? Theme.of(ctx).colorScheme.outline
                                            : null,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Icon(Icons.edit_outlined,
                                      size: 18,
                                      color: Theme.of(ctx)
                                          .colorScheme
                                          .onSurfaceVariant),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  for (final e in others)
                    _membersCard(
                      memberId: e.key,
                      gender: _memberGenders[e.key] ?? '',
                      name: _memberNames[e.key],
                      actionLabel: l10n.chatPageMembersReinvite,
                      onAction: () {
                        // 先收起成员弹层；**等它收完再弹口令框**——紧接着 showDialog
                        // 会让两条 route 在 Overlay 里交叉卸载（见 _waitRouteHandoff）。
                        Navigator.of(ctx).pop();
                        _menuAction(() => _reinviteMemberIdentity(
                            e.key, _memberNames[e.key]));
                      },
                    ),
                  // 未满 → 「邀请新同伴」大按钮（加号图标 + 文字整体居中，
                  // 老板 2026-10-06；duo 的邀请在「我的同伴」身份卡里，不走这里）
                  if (_canInvite)
                    // 与成员卡片拉开一组间距：卡片间仅 8px（各自 vertical 4），
                    // 这里给 12（合计 16），示意按钮不属于成员卡那一组（老板 2026-10-19）
                    Column(
                      children: [
                        const SizedBox(height: 12),
                        Material(
                          // 与「添加秘境」/「新建通道」大按钮同款淡灰底（老板 2026-10-17：
                          // 三个大按钮底色统一）；hover/按住加深同口径
                          color: Colors.black.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(12),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(mouseCursor: SystemMouseCursors.click,
                            onTap: () {
                              Navigator.of(ctx).pop();
                              _menuAction(
                                  () => _showInviteDialog(purpose: 'invite'));
                            },
                            hoverColor: Colors.black.withValues(alpha: 0.10),
                            highlightColor: Colors.black.withValues(alpha: 0.14),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.add),
                                  const SizedBox(width: 6),
                                  Text(l10n.chatPageMembersInviteNew),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    )
                  else if (_isGroup)
                    // 群组满员：末尾那张卡变灰（不可点、无按钮），只说"已满"。
                    // duo 满员不走这里——duo 用成员卡上的「重新邀请」表达"满"。
                    _membersCard(
                      memberId: null,
                      gender: '',
                      name: l10n.chatPageMembersFullWithMax(
                          _memberCount, _maxMembers),
                      muted: true,
                    ),
                  // 「退出群组」（2026-10-19，aimemo/groupExitDesign.md §6.1）：
                  // destructive 红字项。与「邀请新同伴」大按钮同款淡灰底（老板
                  // 2026-10-17 统一口径），红图标+红字表达破坏性；**整块可点**
                  // （老板偏好：别让人去点中某个小控件）。
                  if (_isGroup)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Material(
                        color: Colors.black.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(12),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          mouseCursor: SystemMouseCursors.click,
                          onTap: () {
                            // 先收弹层；等它收完再走确认闸门（route 交接，
                            // 见 _waitRouteHandoff）
                            Navigator.of(ctx).pop();
                            _menuAction(_exitGroup);
                          },
                          hoverColor: Colors.black.withValues(alpha: 0.10),
                          highlightColor: Colors.black.withValues(alpha: 0.14),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.logout,
                                    color: Theme.of(ctx).colorScheme.error),
                                const SizedBox(width: 6),
                                Text(
                                  l10n.exitGroupMenuItem,
                                  style: TextStyle(
                                    color: Theme.of(ctx).colorScheme.error,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 退出群组（2026-10-19，aimemo/groupExitDesign.md §6.3）：确认闸门 →
  /// 服务端 leaveSpace → 本地 removeSpace → 导航收尾。
  ///
  /// 执行链的顺序不能反：**leaveSpace 成功之后再清本地**（凭证在本地，清完就
  /// 再也调不动服务端）。失败不清本地（confirmExitGroup 内部已报顶部通知），
  /// 直接 return 留在群里。
  ///
  /// 导航收尾与「销毁本通道」同款：还有其他空间 → 切到下一个；一个都不剩 →
  /// 回向导（VaultPayload.remove 已把 active 让给剩下的第一个）。
  Future<void> _exitGroup() async {
    final hasPin =
        await AppLockService(widget.db ?? LocalDatabase.shared).isSetup;
    if (!mounted) return;
    final left = await confirmExitGroup(
      context,
      db: widget.db,
      api: widget.api,
      spaceId: widget.spaceId,
      session: _session,
      groupName: _groupName,
      hasPin: hasPin,
    );
    if (!left || !mounted) return;
    SpaceSessions.forget(widget.spaceId); // 凭证已随 removeSpace 删掉，会话一并丢掉
    final vault = VaultSession.current;
    final database = widget.db ?? LocalDatabase.shared;
    final next = vault == null
        ? null
        : await AppLockService(database).resolveActivePayload(vault);
    if (!mounted) return;
    if (next == null) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const SetupPage()),
        (route) => false,
      );
      return;
    }
    await switchToSpace(context, next.spaceId, db: widget.db);
  }

  /// duo 的「我的同伴」弹层（老板 2026-10-18 改版）：与「我的资料」弹层**同款
  /// 布局的单张身份卡**，但**全部只读**——不能编辑（改名/换头像是「我的资料」
  /// 的权利，对方的资料我们没有权限动）。
  ///
  /// - 左：头像（粉蓝渐变细环 + surface 留白，与「我的资料」同款）。**点头像 =
  ///   打开头像全屏**——与消息气泡旁对方头像同一份共享全屏实现（底部「保存」
  ///   可下载；没有「更换头像」：不给改别人的图）。没头像时点它没有动作
  ///   （[_MessageAvatarState.handleTap] 自己按图缓存决策，我们不替它猜）。
  /// - 右两行：名字（上）+ 性别（下），左对齐。
  ///   - 名字：对方名字；没名字时按状态给占位词——还没加入 = 「待加入」
  ///     （`memberPending`），已加入但没命名 = 「未命名」（`chatPageMembersUnnamed`）；
  ///   - 性别：只读性别图标（老板 2026-10-18：不显示男/女文字；性别为空
  ///     整行不显示性别部分）。
  /// - **邀请 / 重新邀请按钮放在性别那一行、右端对齐**（老板 2026-10-18）：
  ///   对方已加入 = 「重新邀请」（先要共享口令，见 [_reinviteMemberIdentity]）；
  ///   还没加入 = 「邀请」（[_showInviteDialog] purpose=invite）。原来它们挂在
  ///   成员卡右侧 / 状态条尾部，改版后收进身份卡；状态条尾部只留语音通话。
  ///
  /// 桌面端限宽 [kMyProfileSheetMaxWidth]（与「我的资料」同口径：宽屏下不拉成
  /// 空旷长带）；点按衔接同样走「先收弹层、错峰 300ms 再开下一条」。
  Future<void> _showDuoPeerSheet() async {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    // 对方 member：duo 只有一位——槽位表里除我之外那个（含未命名成员）；
    // 槽位里没有他 = 还没加入（duo 满 2 人即永久关闭邀请，见 [_canInvite]）。
    final others = _memberSlots.entries
        .where((e) => e.key != _myMemberId)
        .toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final peerId = others.isNotEmpty ? others.first.key : null;
    final peerJoined = peerId != null;
    // 性别配色：男女各用 Logo 里的粉/蓝（与「我的资料」、向导、改名弹窗同色）
    final isFemale = _peerGender == 'female';
    final isMale = _peerGender == 'male';
    final genderColor = isFemale
        ? const Color(0xFFD6529C)
        : isMale
            ? const Color(0xFF3BAFFD)
            : scheme.outline;
    final genderLabel =
        isFemale ? l10n.wizardGenderFemale : isMale ? l10n.wizardGenderMale : '';
    // 名字占位词：还没来 = 「待加入」（与状态条同一口径）；来了没命名 = 「未命名」
    final peerName = _peerName.isNotEmpty
        ? _peerName
        : peerJoined
            ? l10n.chatPageMembersUnnamed
            : l10n.memberPending;
    final nameIsPlaceholder = _peerName.isEmpty;
    // 头像组件句柄：外层方形热区（头像 + 渐变环）通过它触发头像自己的点按决策
    // （有图 → 全屏 / 没图 → 无动作），内层传 openFullscreenOnTap:false 让出
    // 点击——与「我的资料」弹层同手法（老板 2026-10-17）。
    final avatarKey = GlobalKey<_MessageAvatarState>();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true, // 与「我的通道」等弹层同口径（老板 2026-10-02）
      // 桌面端限宽（与「我的资料」同口径，老板 2026-10-17）：不限宽时整张
      // 身份卡随窗口拉长，头像和名字之间会隔出一大片空白。
      constraints: const BoxConstraints(maxWidth: kMyProfileSheetMaxWidth),
      builder: (ctx) {
        return SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 18),
                    child: Center(
                      child: Text(l10n.chatPageMembersTitle('duo'),
                          style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 16,
                              color: scheme.onSurface)),
                    ),
                  ),
                  Row(
                    children: [
                      // 头像（左侧大图）= **一个方形热区**（与「我的资料」同款）：
                      // 点头像、点渐变环的空白都算——去向由 _MessageAvatar 按它
                      // 自己的图缓存决定（有图 → 全屏；没图 → 没有动作）。
                      Clickable(
                        behavior: HitTestBehavior.opaque, // 方角空白也算热区
                        circle: true, // 反馈遮罩仍跟圆走，方角不染色
                        onTap: () => avatarKey.currentState?.handleTap(),
                        // key 供测试定位头像热区（弹层外状态条上也有头像）
                        key: const ValueKey('duoPeerSheetAvatar'),
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              colors: [Color(0xFF3BAFFD), Color(0xFFD6529C)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                          ),
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: scheme.surface,
                            ),
                            child: _MessageAvatar(
                              key: avatarKey,
                              memberId: peerId,
                              server: effectiveServer,
                              api: widget.api,
                              radius: 40,
                              // 点击交给外层方形热区（统一一个动作）
                              openFullscreenOnTap: false,
                              // 别人的头像：只有「保存」可下载，不给换/不给扇出
                              onSaveImage: (bytes) => _saveAvatarImage(
                                  _senderNameOf(peerId), bytes),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 18),
                      // 右侧两行：名字（上）+ 性别（下），左对齐
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 名字：纯文字（**不能编辑**，不做成「我的资料」那种
                            // 带编辑图标的胶囊——那是在邀请点击，这里没有可点的）。
                            // 占位词单独降档（浅色），与「我的资料」未设名同口径。
                            Text(
                              peerName,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 20,
                                height: 1.2,
                                color:
                                    nameIsPlaceholder ? scheme.outline : null,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 8),
                            // 性别行：只读性别图标（老板 2026-10-18：不显示男/女
                            // 文字）+ 右端对齐的邀请/重新邀请按钮
                            Row(
                              children: [
                                if (genderLabel.isNotEmpty)
                                  Semantics(
                                    // 只有一枚性别图标，读屏补上「性别」二字
                                    // （与「我的资料」弹层同口径）
                                    label: '${l10n.chatPageGenderLabel} '
                                        '$genderLabel',
                                    child: Icon(
                                      isFemale ? Icons.female : Icons.male,
                                      size: 16,
                                      color: genderColor,
                                    ),
                                  ),
                                const Spacer(),
                                // 已加入 = 「重新邀请」（需共享口令）；还没加入 =
                                // 「邀请」。duo 满员后不再有邀请（_canInvite 关）。
                                if (peerJoined || _canInvite)
                                  TextButton(
                                    key: const ValueKey(
                                        'duoPeerSheetActionButton'),
                                    onPressed: () {
                                      // 先收起弹层；等它收完再弹下一条
                                      // （route 交接，见 _waitRouteHandoff）
                                      Navigator.of(ctx).pop();
                                      if (peerJoined) {
                                        _menuAction(() =>
                                            _reinviteMemberIdentity(
                                                peerId, _peerName));
                                      } else {
                                        _menuAction(() => _showInviteDialog(
                                            purpose: 'invite'));
                                      }
                                    },
                                    style: TextButton.styleFrom(
                                      // 链接蓝 = 品牌深蓝，与状态条「邀请加入」
                                      // 链接、通道码弹窗邀请链接同源
                                      foregroundColor: const Color(0xFF2271F7),
                                      visualDensity: VisualDensity.compact,
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 10),
                                      textStyle: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600),
                                    ),
                                    child: Text(peerJoined
                                        ? l10n.chatPageMembersReinvite
                                        : l10n.chatPageMembersInvite),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 成员卡（每行一张）：底色=性别色；左头像+名字，右文字按钮。
  /// **只有右侧按钮可点**（老板 2026-10-06：整卡可点不需要，误触会直接弹出口令框）。
  /// [memberId] 为空 = "尚未加入"的占位卡（默认头像、不显示名字）。
  Widget _membersCard({
    required String? memberId,
    required String gender,
    required String? name,
    String? actionLabel, // null / muted = 不放按钮（"已满"卡）
    VoidCallback? onAction, // null = 不可点
    bool muted = false,
    bool faintName = false, // 名字是"待加入"这类占位词 → 淡色
  }) {
    final hasName = (name ?? '').trim().isNotEmpty;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: muted ? _genderTint('') : _genderTint(gender),
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        // 卡片本体不再是 InkWell（原来整卡 onTap=onAction）；只留普通容器。
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              _MessageAvatar(
                memberId: memberId,
                server: effectiveServer,
                api: widget.api,
                radius: 20,
                onSaveImage: (bytes) =>
                    _saveAvatarImage(_senderNameOf(memberId), bytes),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  hasName ? name! : '', // 尚未加入：不显示名字
                  style: TextStyle(
                    fontSize: 15,
                    color:
                        (muted || faintName) ? scheme.onSurfaceVariant : null,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // 有动作才放按钮；"已满"卡（muted）没有按钮
              if (actionLabel != null) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: onAction,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(actionLabel),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// **re-invite**（再次邀请）：把某个成员的身份接回一台新设备——定向 attach token。
  /// （2026-10-05 定名：内部场景名 `recover` → `re-invite`，与 `invite` 同族；
  /// 用户可见动词统一为「加入」。）
  ///
  /// 场景：对方丢了手机 / 重装了 App，而他自己**没有任何安装**可以自己签发——
  /// 这时只有别的成员能把他接回来。只要空间里还有一个安装存在，这个空间就不会
  /// 作废（这是结构性保证，不是给 duo 打的补丁）。
  ///
  /// 对**别人的身份**动手要共享口令（与"撤销别人的通道"同一档授权）：先要口令，
  /// 再签码；用户取消就什么都不做。
  Future<void> _reinviteMemberIdentity(String memberId, String? memberName) async {
    final l10n = AppLocalizations.of(context)!;
    final who = (memberName ?? '').trim();
    // 说明文案里嵌「重新邀请 <谁>」；这人没设过名字 → 退回「对方」
    // （`chatPageMembersUnnamed`「未命名」是列表里的占位名，塞进整句读着生硬；
    //  也与紧跟着的开通码弹窗同一兜底，两处一致）
    final name = who.isEmpty
        ? l10n.chatPageInviteDialogReinviteFallbackName
        : who;
    final passphrase = await _promptSharedPassphrase(
      title: l10n.chatPageReinvitePassphraseTitle,
      hint: l10n.chatPageReinvitePassphraseHint(name),
    );
    if (passphrase == null || !mounted) return;
    // 口令弹窗刚 pop（exit 动画还没跑完）→ 直接开通道码弹窗会交叉卸载，同上。
    await _waitRouteHandoff();
    if (!mounted) return;
    await _showInviteDialog(
      purpose: 'attach',
      targetMemberId: memberId,
      // 说明文案里要出现"发给谁"；名字空 → 弹窗退成「对方」
      targetName: memberName,
      passphrase: passphrase,
    );
  }

  Future<void> _showEntranceListSheet() async {
    final l10n = AppLocalizations.of(context)!;
    final api = widget.api ?? ApiClient(effectiveServer);
    // 弹层内的可变状态（StatefulBuilder 重建时读它；标题右端的「刷新」就地重拉）
    List<Map<String, dynamic>>? rows;
    // "我是谁"（_myMemberId 可能为 null：离线且 profile 未缓存）：兜底反查一次
    String? myMemberId = _myMemberId;
    int localSinceMs = 0;
    bool refreshing = false;

    /// 拉一次 /entrances 并算好展示所需的状态；失败 → rows = null
    /// （弹层里只显示当前通道 + 「无法获取其他通道」提示）。初次打开与点「刷新」共用。
    Future<void> load() async {
      List<Map<String, dynamic>>? fetched;
      try {
        // 先落到**非空**局部：直接赋给可空变量的话，_withAuth 的 T 会被推成可空，
        // 后面的空提升就断了（analyze 的 unchecked_use_of_nullable_value）
        final fresh = await _withAuth((t) => api.listEntrances(t));
        fetched = fresh;
        // 局部副本：myMemberId 是被闭包改写的捕获变量，Dart 不对它做空提升
        final known = myMemberId;
        if (known == null || known.isEmpty) {
          for (final d in fresh) {
            if (d['entrance_id'] == widget.entranceId) {
              myMemberId = d['member_id'] as String?;
              break;
            }
          }
        }
      } catch (_) {
        fetched = null; // 离线/出错：当前通道照列，其他通道区显示失败提示
      }
      // 本机卡片的 since = 服务端自己这一行的上线时刻（online_since，兜底 connected_at；
      // 服务端拉不到时 0 → 不显示，避免显示"当前时刻"这种假上线时间）
      var since = 0;
      if (fetched != null) {
        for (final d in fetched) {
          if (d['entrance_id'] == widget.entranceId) {
            since = (d['online_since'] as num?)?.toInt() ??
                (d['connected_at'] is num ? (d['connected_at'] as num).toInt() : 0);
            break;
          }
        }
      }
      rows = fetched;
      localSinceMs = since;
    }

    await load();
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      // 允许弹层用到满窗高：默认上限是 9/16 屏，窗口矮时标题/备注/「新建通道」
      // 这些固定项之和就可能超过它，Flexible 缩到 0 也不够 → 底部黑黄条纹
      // "Bottom overflowed"（老板 2026-10-02 mac 实测）。开起来后只有窗口矮到
      // 固定项本身装不下（<约 180px）才会溢出，正常窗口都由中间卡片区内部滚动吸收。
      isScrollControlled: true,
      // StatefulBuilder：「刷新」按钮要就地重建卡片（老板 2026-09-26）——关掉弹层
      // 再开一次会有"收起+展开"两段动画，看着像卡了一下
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final scheme = Theme.of(ctx).colorScheme;
          // 局部 final：rows / myMemberId 是被 load() 改写的捕获变量，Dart 不做空提升
          final loaded = rows;
          final myId = myMemberId ?? '';
          // 行 = 当前通道（必有，标「本机」）+ 我本人的其他通道（同 member，排除当前）
          final myRows = <Map<String, dynamic>>[
            {
              'entrance_id': widget.entranceId,
              'entrance_name': _myEntranceName,
              'member_id': myId,
              'connected_at': DateTime.now().millisecondsSinceEpoch,
              'status': 'active',
              '_local': true,
              // 本机的客户端信息：App + 本机版本号（读不到版本 → 客户端段不显示）
              'client': 'app',
              'app_version': _myAppVersion,
            },
            if (loaded != null)
              for (final d in loaded)
                if (d['entrance_id'] != widget.entranceId &&
                    myId.isNotEmpty &&
                    d['member_id'] == myId)
                  d,
          ];
          return SafeArea(
            child: Padding(
              // 顶边 0：标题自己的 Padding 负责上 14 留白（同参照弹层）
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 标题**居中**、上 14 下 5（与「界面语言」等弹层标题的居中与
                  // 留白口径对齐）。右端挂「刷新」：就地重拉 /entrances 重建卡片，
                  // 不用退出弹层、也不用等 30s 轮询。横向 padding 由 16 收到 0，
                  // 让刷新按钮与下面的卡片**右对齐**；左边放同宽占位，标题仍在弹层
                  // 正中（不会被按钮推歪）。
                  Padding(
                    padding: const EdgeInsets.fromLTRB(0, 4, 0, 5),
                    child: Row(
                      children: [
                        const SizedBox(width: _entranceRefreshSize),
                        Expanded(
                          child: Center(
                            child: Text(l10n.chatPageMenuEntranceList,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600, fontSize: 16)),
                          ),
                        ),
                        SizedBox(
                          width: _entranceRefreshSize,
                          height: _entranceRefreshSize,
                          // 拉取中换成同尺寸的转圈：位置与大小都不跳
                          child: refreshing
                              ? const Center(
                                  child: SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2)),
                                )
                              : IconButton(
                                  icon: const Icon(Icons.refresh, size: 20),
                                  tooltip: l10n.chatPageEntranceListRefresh,
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () async {
                                    setSheetState(() => refreshing = true);
                                    await load();
                                    // 弹层可能在这期间被关掉 → 不能再 setState
                                    if (!ctx.mounted) return;
                                    setSheetState(() => refreshing = false);
                                  },
                                ),
                        ),
                      ],
                    ),
                  ),
                  // 标题下备注行：沿用原「当前通道」弹窗的说明文案，式样同「阅后即焚」
                  // 弹层标题下的说明（淡色小字、居中）。
                  Center(
                    child: Text(
                      l10n.chatPageEntranceScopeHint,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(ctx).colorScheme.outline),
                    ),
                  ),
                  const SizedBox(height: 20),
                  // 通道卡片：**一卡占满整行**（老板 2026-10-11：不再一行 3 张）。
                  // 卡片 = 边框 + 名称 + 状态红绿灯（绿在线/红离线/灰已撤销）+ 时间
                  // （在线→上线时刻；离线/已撤销→下线时刻；无数据不显示）；
                  // 右上角固定角标：本机=编辑图标（点击改名）、已撤销=阻止图标+整卡蒙版
                  // （老板 2026-10-02：当前通道改名改从本机卡片进，弹层不再放改名行）
                  // 通道多 + 窗口矮 → 随中间整块在外层 ScrollableCardArea 里滚动。
                  ScrollableCardArea(
                    child: Wrap(
                      runSpacing: _entranceCardSpacing,
                      children: [
                        for (final d in myRows)
                          () {
                                final name = (d['entrance_name'] as String? ?? '').trim();
                                final entranceId = d['entrance_id'] as String? ?? '';
                                final isLocal = d['_local'] == true;
                                // 三态判定与时刻口径走 shared 唯一实现（与 TUI 同源，
                                // 2026-10-08 合并）：已撤销是独立状态（区别于离线，
                                // 卡片灰灯 + 蒙版 + 阻止角标）；时间戳：在线 → 上线
                                // 时刻（online_since 兜底 connected_at）；离线/已撤销
                                // → 下线时刻 max(last_seen, offline_since)（详见
                                // shared entrance_status.dart 注释）。
                                // 判定用纯服务端口径（不传 myEntranceId——卡片里**每行**
                                // 的灯都按服务端 connected_at/last_seen 走，与合并前
                                // 行为一致；本机灯"以本地 WS 为准"只用在标题栏「我的」
                                // 那一处，见 _statusLine 调用点）。
                                final rowState = entranceRowState(d);
                                final revoked =
                                    rowState == EntranceRowState.revoked;
                                final online = rowState == EntranceRowState.online;
                                final int stamp;
                                if (isLocal) {
                                  stamp = localSinceMs;
                                } else {
                                  stamp = rowSince(d, online: online);
                                }
                                // 第二行：时间靠左、客户端段（App 版本/TUI，
                                // 老板 2026-10-14）**靠右**（老板同日要求右对齐）。
                                // 客户端段放第二行而非名称行：名称可能很长，第二行
                                // 才有稳定空间。时间没有可显示的值时给一个空格
                                // （不是空串——空串在部分平台量出 0 高），否则这张卡
                                // 会比别的矮一截（老板 2026-09-26 实测）。
                                final clientLabel = entranceClientLabel(d);
                                final timeText =
                                    stamp > 0 ? _timeStampLabel(stamp) : ' ';
                                // 右上角固定角标：已撤销 = 阻止图标（本机的编辑
                                // 入口不在角标位——见下面第一行的可点击胶囊）
                                // 撤销卡的名称行让出角标宽度，长名字不会钻到图标底下
                                final hasCornerBadge = revoked;
                                return SizedBox(
                                  // 一卡占满整行（老板 2026-10-11）；高度仍由
                                  // 内容（名称 + 状态行）自然撑出
                                  width: double.infinity,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                          color:
                                              Colors.black.withValues(alpha: 0.12)),
                                      // 已撤销：极淡灰底 —— "这张卡失效了"的第一层蒙版
                                      // （第二层是整个内容降透明度，见下面的 Opacity）
                                      color: revoked
                                          ? Colors.black.withValues(alpha: 0.04)
                                          : null,
                                    ),
                                    // Stack：内容照常流式排布，角标**固定**在卡片右上角
                                    // （老板 2026-09-26：绿勾原先紧贴名称，位置随名字长短跑）
                                    child: Stack(
                                      children: [
                                        Opacity(
                                          opacity: revoked ? 0.55 : 1,
                                          child: Padding(
                                            padding: const EdgeInsets.all(8),
                                            // mainAxisSize.min：Wrap 给子项的高度约束无限，
                                            // 不能用 Spacer/flex（RenderFlex 断言）
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                // 第一行：名称。**本机卡 = 名字 +
                                                // 编辑图标组成的可点击胶囊**（老板
                                                // 2026-10-14：图标跟在名字后，不再
                                                // 固定卡片最右；点整颗胶囊进改名）。
                                                // 已撤销卡的角标位由右上角预留
                                                // （阻止图标仍固定右上角）
                                                Padding(
                                                  padding: EdgeInsets.only(
                                                      right: hasCornerBadge
                                                          ? 18
                                                          : 0),
                                                  child: isLocal
                                                      ? Tooltip(
                                                          message:
                                                              l10n.chatPageEdit,
                                                          child: Material(
                                                            // 胶囊底：淡灰圆角
                                                            // （同卡片蒙版/占位那一档
                                                            // 灰），悬浮/点击有反馈
                                                            color: Colors.black
                                                                .withValues(
                                                                    alpha: 0.05),
                                                            borderRadius:
                                                                BorderRadius
                                                                    .circular(
                                                                        10),
                                                            clipBehavior:
                                                                Clip.antiAlias,
                                                            child: InkWell(
                                                              mouseCursor:
                                                                  SystemMouseCursors
                                                                      .click,
                                                              hoverColor: Colors
                                                                  .black
                                                                  .withValues(
                                                                      alpha:
                                                                          0.05),
                                                              highlightColor: Colors
                                                                  .black
                                                                  .withValues(
                                                                      alpha:
                                                                          0.08),
                                                              onTap: () {
                                                                // 先收起弹层再开
                                                                // 弹窗（与「新建
                                                                // 通道」同款错峰，
                                                                // 避免 Overlay
                                                                // 交叉卸载断言）
                                                                Navigator.of(
                                                                        ctx)
                                                                    .pop();
                                                                _menuAction(
                                                                    _showRenameEntranceDialog);
                                                              },
                                                              child: Padding(
                                                                padding:
                                                                    const EdgeInsets
                                                                        .symmetric(
                                                                        horizontal:
                                                                            6,
                                                                        vertical:
                                                                            3),
                                                                child: Row(
                                                                  mainAxisSize:
                                                                      MainAxisSize
                                                                          .min,
                                                                  children: [
                                                                    Flexible(
                                                                      child: Text(
                                                                        name.isNotEmpty
                                                                            ? name
                                                                            : entranceId,
                                                                        maxLines: 1,
                                                                        overflow: TextOverflow
                                                                            .ellipsis,
                                                                        style: const TextStyle(
                                                                            fontSize: 13,
                                                                            fontWeight: FontWeight.w500),
                                                                      ),
                                                                    ),
                                                                    const SizedBox(
                                                                        width:
                                                                            4),
                                                                    const Icon(
                                                                        Icons
                                                                            .edit,
                                                                        size:
                                                                            14),
                                                                  ],
                                                                ),
                                                              ),
                                                            ),
                                                          ),
                                                        )
                                                      : Padding(
                                                          // 纯名字卡补上与本机
                                                          // 胶囊相同的纵向
                                                          // 3px：否则本机卡
                                                          // 比别的卡高 6px
                                                          // （老板 2026-09-26
                                                          // 的等高要求）
                                                          padding:
                                                              const EdgeInsets
                                                                  .symmetric(
                                                                  vertical: 3),
                                                          child: Text(
                                                            name.isNotEmpty
                                                                ? name
                                                                : entranceId,
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                            style:
                                                                const TextStyle(
                                                                    fontSize:
                                                                        13,
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .w500),
                                                          ),
                                                        ),
                                                ),
                                                const SizedBox(height: 4),
                                                // 第二行：状态红绿灯 + 时间
                                                // （绿在线/红离线/灰已撤销）。
                                                // 时间**恒定占一行**：没有时间可显示
                                                // 时给一个空格（不是空串——空串在部分平台量出 0
                                                // 高），否则这张卡会比别的矮一截
                                                // （老板 2026-09-26 实测：离线卡没有文字时矮一截）。
                                                // 客户端段（App 版本/TUI）**靠右**，
                                                // 与时间同款 11px 淡色（老板 2026-10-14）
                                                Row(
                                                  children: [
                                                    Icon(Icons.circle, size: 8,
                                                        color: revoked
                                                            ? Colors.black
                                                                    .withValues(
                                                                        alpha: 0.30)
                                                            : (online
                                                                ? Colors.green
                                                                : Colors.red)),
                                                    const SizedBox(width: 6),
                                                    Expanded(
                                                      // 直接写时间，不带 "since" 前缀
                                                      // （老板 2026-09-26：太占地方）
                                                      child: Text(
                                                          timeText,
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style: TextStyle(
                                                              fontSize: 11,
                                                              color:
                                                                  scheme.outline)),
                                                    ),
                                                    // 客户端段靠右：没有可显示的值
                                                    // （存量行/旧客户端/读不到版本）
                                                    // 时整段不占位
                                                    if (clientLabel != null) ...[
                                                      const SizedBox(width: 6),
                                                      Text(
                                                          clientLabel,
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style: TextStyle(
                                                              fontSize: 11,
                                                              color: scheme
                                                                  .outline)),
                                                    ],
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        if (hasCornerBadge)
                                          Positioned(
                                            top: 6,
                                            right: 6,
                                            // 已撤销 = 阻止图标（本机的编辑入口
                                            // 2026-10-14 起搬到第一行名字后面的
                                            // 可点击胶囊，不再占角标位）
                                            child: Icon(
                                              Icons.block,
                                              size: 14,
                                              color: Colors.black
                                                  .withValues(alpha: 0.45),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                );
                              }(),
                      ],
                    ),
                  ),
                  if (loaded == null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(l10n.chatPageEntranceListFailed,
                          style: TextStyle(fontSize: 13, color: scheme.outline)),
                    ),
                  // 卡片与「新建通道」之间的留白（老板 2026-09-25：原先紧挨着）
                  const SizedBox(height: 12),
                  // 「新建通道」：与「切换我的秘境」弹层的「添加秘境」同款外观——常态淡灰底
                  // 提示可点、图标+文字居中（老板 2026-09-25）；点击生成通道码
                  Material(
                    color: Colors.black.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(12),
                    clipBehavior: Clip.antiAlias, // 让 ink 跟着圆角裁
                    child: InkWell(mouseCursor: SystemMouseCursors.click,
                      // 点「新建通道」：**先收起通道列表弹层**，再弹通道码
                      // （老板 2026-09-25）；_menuAction 内部 300ms 错峰，等弹层
                      // 收起动画跑完再 show（同菜单项开新 route 的口径，避免
                      // Overlay 交叉卸载断言）
                      onTap: () {
                        Navigator.of(ctx).pop();
                        // 「新建通道」= 我本人在另一台设备接入 → attach token
                        // （进我自己的身份）。邀**新成员**才是 invite，别搞反。
                        _menuAction(() => _showInviteDialog(purpose: 'attach'));
                      },
                      hoverColor: Colors.black.withValues(alpha: 0.10),
                      highlightColor: Colors.black.withValues(alpha: 0.14),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.add),
                            const SizedBox(width: 6),
                            Text(l10n.chatPageEntranceListNew),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 「高级」底部弹层（二级菜单：修改口令 / 销毁本通道）。两项都只给标题——
  /// 具体后果留给点进去的弹窗说明（弹层本身不解释）。
  ///
  /// 为什么用弹层而不是 MenuAnchor + SubmenuButton 的级联子菜单：手机宽度下
  /// 主菜单 280 + 子菜单约 190 塞不进一屏，级联面板会与主菜单重叠、还会被面板里的
  /// 分隔线横穿（2026-09-19 实测），换弹层最省事。
  Future<void> _showAdvancedSheet() async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showModalBottomSheet<String>(
      context: context,
      // 允许用满窗高（与「我的通道」等弹层同口径，老板 2026-10-02）
      isScrollControlled: true,
      builder: (ctx) {
        final red = Theme.of(ctx).colorScheme.error;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 标题**居中**、上 14 下 10（老板 2026-09-25：与「界面语言」/「更多通道」
              // 等弹层标题口径一致——原来是自己一套 left + all 12 + 无字号）
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                child: Center(
                  child: Text(l10n.advancedMenuTitle,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 16)),
                ),
              ),
              // 每行行尾 > ：与顶层菜单的二级入口标识同款（老板 2026-10-15）——
              // 三条点进去都还有下一级弹窗，行尾给出"可进入"的暗示
              ListTile(
                leading: const Icon(Icons.key_outlined),
                title: Text(l10n.chatPageMenuChangePassphrase),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => Navigator.of(ctx).pop('passphrase'),
              ),
              // 「删除所有消息」（老板 2026-10-02）：清本通道的消息+附件，通道保留。
              // 破坏性递进：排在本通道销毁（更彻底）之前
              ListTile(
                leading: const Icon(Icons.delete_sweep_outlined),
                title: Text(l10n.advancedClearMessages),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => Navigator.of(ctx).pop('clear'),
              ),
              ListTile(
                leading: Icon(Icons.warning_amber_rounded, color: red),
                title: Text(l10n.advancedDestroyEntrance),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => Navigator.of(ctx).pop('leave'),
              ),
              // 底部留白：与「切换我的秘境」弹层一致（那边是外层 Padding 的 bottom 16），
              // 这里标题只包了 12 的 Padding → 单独给末行留 16，不然紧贴屏幕底边
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
    if (picked == null || !mounted) return;
    // 与弹层关闭动画错开再开 dialog：Overlay 里两个 route 交叉卸载会触发断言
    // （同 _menuAction 的 2026-09-05 修复）
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    if (picked == 'passphrase') {
      await _showChangePassphraseDialog();
    } else if (picked == 'clear') {
      // 「删除所有消息」（老板 2026-10-02 定稿：**纯本机删除**，服务端不删）：
      // 只清本机这份历史，服务端与对方设备上的消息原样保留——本通道继续从原
      // 同步锚点收新消息。确认闸门与销毁通道同一条（通道名 + 已设时的锁屏码），
      // 弹窗备注按老板文案说明"通道保留、继续收新消息、其他通道不受影响"。
      final entranceName = await _resolveMyEntranceName();
      final hasPin = await AppLockService(widget.db ?? LocalDatabase.shared).isSetup;
      if (!mounted) return;
      final ok = await confirmClearMessages(
        context,
        db: widget.db,
        entranceName: entranceName,
        hasPin: hasPin,
      );
      if (!ok || !mounted) return;
      try {
        // 本机清：消息行 + 附件元数据行 + stored 模式的明文副本 + 媒体缓存。
        // 刻意**不动 sync_state 锚点**：服务端消息仍在，锚点＝已同步到的最新序号，
        // 新消息继续从锚点之后增量同步（清零会让下次 sync 整表重拉服务端历史，
        // 恰好违背"本机删除"的意图）。
        await _repo.clearLocalHistory();
        unawaited(AttachmentStore.clearSpace(widget.spaceId));
        if (!mounted) return;
        setState(() {
          // 内存列表立即清屏（老板 2026-10-02 实测缺陷：只清库不清内存，要切空间
          // 再切回来才消失——_refreshLocal 是增量合并，拉不到"新"消息，冲不掉
          // 还在内存里的旧列表）。分页游标一并复位：本地库已空，没有更早历史；
          // 引用条若正引用被删的消息一并撤掉（悬挂引用会把已删内容带进下一条发送）。
          _messages = [];
          _hasMoreOlder = false;
          _quoteTarget = null;
          _imageCache.clear();
          _videoCache.clear();
          _videoThumbCache.clear();
        });
        await _refreshLocal();
        if (mounted) _notice(context, l10n.clearMessagesDone);
      } catch (e) {
        if (!mounted) return;
        _notice(context, backendError(l10n, l10n.clearMessagesFailed('$e')));
      }
    } else if (picked == 'leave') {
      // 阀门所需的两个输入：通道名（确认清的是这条）与"是否设了锁屏码"（决定要不要验）。
      // 都用 await 取，过一遍 mounted 再传进弹窗。
      final entranceName = await _resolveMyEntranceName();
      final hasPin = await AppLockService(widget.db ?? LocalDatabase.shared).isSetup;
      if (!mounted) return;
      // **空间级**：只退出并清除当前空间，不动本机上的其他空间（老板 2026-09-22 定）。
      // 整台设备的清理由空间列表页的「清除本设备全部数据」负责。
      final left = await confirmLeaveSpace(
        context,
        db: widget.db,
        api: widget.api,
        spaceId: widget.spaceId,
        session: _session,
        entranceName: entranceName,
        hasPin: hasPin,
      );
      if (!left || !mounted) return;
      SpaceSessions.forget(widget.spaceId); // 凭证已随 removeSpace 删掉，会话一并丢掉
      // 退出后：还有别的空间 → 直接切到下一个（VaultPayload.remove 已把 active 让给剩下的
      // 第一个）；一个都不剩 → 回向导。
      final vault = VaultSession.current;
      final database = widget.db ?? LocalDatabase.shared;
      final next = vault == null
          ? null
          : await AppLockService(database).resolveActivePayload(vault);
      if (next == null) {
        if (!mounted) return;
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const SetupPage()),
          (route) => false,
        );
        return;
      }
      if (!mounted) return;
      await switchToSpace(context, next.spaceId, db: widget.db);
    }
  }

  /// 重置闸门要用的"本机通道名"。
  ///
  /// 不能用 `widget.entranceName`：**只有向导那条路径传它**（setup_page），重启/解锁进
  /// 聊天的路径（main.dart StartupGate）不带——那边的名字由 [_myEntranceName] 从本地
  /// profile 恢复。取不到（旧装机快照里没写 entranceName）时再问一次服务端：通道名是
  /// 入网时自动生成并同步上去的，服务端必定有。都问不出来返回 ''，由重置弹窗退化为
  /// 固定确认词——本地快照缺字段不该让人永远重置不了（老板 2026-09-21 安卓实测）。
  Future<String> _resolveMyEntranceName() async {
    final local = _myEntranceName.trim();
    if (local.isNotEmpty) return local;
    if (_session.token.isEmpty || effectiveServer.isEmpty) return '';
    try {
      final rows = await _withAuth((t) => (widget.api ?? ApiClient(effectiveServer)).listEntrances(t));
      for (final d in rows) {
        if (d['entrance_id'] == widget.entranceId) {
          return (d['entrance_name'] as String? ?? '').trim();
        }
      }
    } catch (_) {
      // 离线/报错：交给上层退化为确认词
    }
    return '';
  }

  /// 打开「关于秘境」底部弹层（版本号 / 服务器地址 / 一句话说明）。
  void _openAboutPage() {
    AboutSheet.show(context);
  }

  /// 对方是否已加入本空间（有**在用**通道）。**null = 还没问到**，此时不显示
  /// 「邀请加入」——首帧与离线（请求失败）都停在 null，不会误挂一个链接。
  /// 未加入时状态条对方芯片右侧显示「邀请加入」链接（老板 2026-09-25）。
  bool? _peerJoined;

  /// 对方在线判定（shared 唯一口径——与 TUI 同源，2026-10-08 合并）：
  /// 有实时 WS 连接（connected_at 非 null）= 在线；老服务端无该字段时退回
  /// last_seen 距今 < 60s 兜底（last_seen 会被轮询 touchLastSeen 持续刷新，
  /// 不能单独代表实时连接——"未入网却显示绿灯"修复）。
  bool _isRowOnline(Map<String, dynamic> d, int now) => isEntranceOnline(d);

  /// 一行通道数据里"当前状态的时刻"（ms；0/缺失 → null）——与「更多通道」卡片
  /// 同一口径（shared rowSince 唯一实现，见其注释）：在线取 `online_since`
  /// （兜底 `connected_at`）；离线取 `max(last_seen, offline_since)`。
  int? _sinceOfRow(Map<String, dynamic> d, {required bool online}) {
    final stamp = rowSince(d, online: online);
    return stamp > 0 ? stamp : null;
  }

  Future<void> _refreshPeerOnline() async {
    try {
      final api = widget.api ?? ApiClient(effectiveServer);
      final entrances = await _withAuth((t) => api.listEntrances(t));
      final now = DateTime.now().millisecondsSinceEpoch;
      // 在线是"人"维度的：同一 member 的其它通道是我自己开的通道，不算对方
      // （重启路径不传 memberId → 从通道表里按本通道反查；查不到才退回按通道判定）
      var mine = widget.memberId;
      if (mine == null || mine.isEmpty) {
        for (final d in entrances) {
          if (d['entrance_id'] == widget.entranceId) {
            mine = d['member_id'] as String?;
            break;
          }
        }
      }
      final peer = entrances.where((d) {
        if (d['entrance_id'] == widget.entranceId) return false;
        final pid = d['member_id'] as String?;
        if (pid == null || mine == null || mine.isEmpty) return true;
        return pid != mine;
      }).toList();
      final online = peer.isNotEmpty && peer.any((d) => _isRowOnline(d, now));
      // 对方由离线转在线（含"刚加入空间"——WS 事件可能漏，这里兜底）：补拉身份。
      // 判据改为「在线成员的身份不全」而非 _peerOnline 翻转：group 里已有同伴在线时
      // 布尔不翻转，新加入的同伴会被挡住（CLI 同款 bug，2026-10-07 对齐修复）。
      if (online &&
          peer.any((d) {
            if (!_isRowOnline(d, now)) return false;
            return _peerProfileIncomplete(d['member_id'] as String?);
          })) {
        unawaited(_refreshProfileFromServer());
      }
      // 「对方已加入」= 有**在用**通道。撤销不会删行，只把 status 标成 revoked
      // （server/src/entrances.ts）——拿"行存在"当已加入，会让密友重置设备/通道被撤
      // 之后反而不给邀请入口，恰恰丢了最该邀请的那一刻。status 缺省（老服务端）按
      // 在用算，与通道列表弹层的 revoked 判定同口径。
      final joined = peer.any((d) => !isEntranceRevoked(d));
      // 群空间要显示的「其他人在线 / 总数」（**都不含我自己**）：
      // - 在线按 **member** 去重——同一 member 有任一条**在用**通道在线就算他在线
      //   （与上面 `online` 那句"在线是人的维度"同一口径；撤销通道不点亮——
      //   shared aggregateMemberStates 唯一实现，App/TUI 同源）；
      // - 总数以 /space 的成员表为准（`_memberCount` 含我，故 -1）；万一成员表还没
      //   更新（刚被拉进群等），取通道表里出现过的 member 数，二者取 `max`——
      //   宁可与头像条里的人数一致，也别出现"头像有两个、却写着 0/0"。
      final presences = aggregateMemberStates(
        entrances,
        myMemberId: (mine == null || mine.isEmpty) ? null : mine,
        myEntranceId: widget.entranceId,
        myWsOnline: _ws?.connected.value ?? false,
      );
      // 墓碑成员（已退出）不进"其他人"口径：他们的通道行仍在 /entrances 里
      // （ revoked 软标记），聚合出的 revokedOnly 存在感不该把人算回来
      // （2026-10-19；_memberCount 已按 active 过滤，这里保持一致）。
      final seenOthers = presences.keys
          .where((k) => _memberStatus[k] != 'left')
          .toSet();
      final onlineOthers = presences.entries
          .where((e) => e.value.online)
          .map((e) => e.key)
          .toSet();
      // 头像条排序的"最近状态变化时刻"（见 _otherSinceMs）：同一 member 多条通道
      // 取 max——最近动过的那条说了算（shared MemberPresence.maxSince）。
      final sinceByMember = <String, int>{};
      for (final e in presences.entries) {
        if (e.value.maxSince > 0) sinceByMember[e.key] = e.value.maxSince;
      }
      final othersTotal = _memberCount > 0
          ? (_memberCount - 1) > seenOthers.length
              ? _memberCount - 1
              : seenOthers.length
          : seenOthers.length;
      final othersOnline =
          onlineOthers.length > othersTotal ? othersTotal : onlineOthers.length;
      // 状态条上的「上线/下线时刻」：对方取"在线的那条通道"（没有就取第一条），
      // 我方取本机通道；口径统一走 _sinceOfRow。
      final peerOnlineRow = peer.where((d) => _isRowOnline(d, now)).firstOrNull;
      final peerRow = peerOnlineRow ?? (peer.isEmpty ? null : peer.first);
      final int? peerSince = peerRow == null
          ? null
          : _sinceOfRow(peerRow, online: peerOnlineRow != null);
      int? mySince;
      for (final d in entrances) {
        if (d['entrance_id'] != widget.entranceId) continue;
        // 本机行：在线与否以本地 WS 为准（shared 唯一口径），时刻同样走 rowSince
        final stamp = rowSince(d, online: _ws?.connected.value ?? false);
        mySince = stamp > 0 ? stamp : null;
        break;
      }
      // 我的通道总数（member 维度，含本机这条）——已撤销的不计入（老板 2026-10-08：
      // 撤销后不算通道总数，与 TUI #n/m 同口径）；轮询拿不到 mine 时保持旧值。
      final myCount = (mine != null && mine.isNotEmpty)
          ? entrances
              .where((d) => d['member_id'] == mine && !isEntranceRevoked(d))
              .length
          : _myEntranceCount;
      if (mounted &&
          (online != _peerOnline ||
              joined != _peerJoined ||
              peerSince != _peerSinceMs ||
              mySince != _mySinceMs ||
              myCount != _myEntranceCount ||
              othersOnline != _othersOnline ||
              othersTotal != _othersTotal ||
              !mapEquals(sinceByMember, _otherSinceMs) ||
              !setEquals(_onlineOthers, onlineOthers))) {
        setState(() {
          _peerOnline = online;
          _peerJoined = joined;
          _peerSinceMs = peerSince;
          _mySinceMs = mySince;
          _myEntranceCount = myCount;
          _othersOnline = othersOnline;
          _othersTotal = othersTotal;
          // 存副本：局部那个 Set/Map 只是本轮的中间结果
          _onlineOthers = Set<String>.of(onlineOthers);
          _otherSinceMs
            ..clear()
            ..addAll(sinceByMember);
        });
      }
    } catch (_) {
      // 网络失败：保持上次状态
    }
  }

  /// 加载我的头像（异步；未设置/失败 → 保持默认图标）。
  /// memberId 缺失时（重启路径）从本地持久化的 entrance→member 映射反查。
  /// 把"本空间对方是谁"（member_id）落进 per-space 资料，与 peerName 并列。
  ///
  /// 为什么要在 `refreshEntranceMap()` 之后做：对方的 member_id 只在那份通道表映射里
  /// 出现过（服务端 `GET /space` 的 `entranceId → memberId`，排掉自己就是对方），
  /// 而映射只在内存 + 一张全局表里，**没有"按空间"的落点**。不落的话，切换秘境弹层的卡片
  /// 就只能显示默认头像——明明有对方名字却不知道对方是谁（老板 2026-09-23 指出）。
  ///
  /// 落两份结论：对方的 member_id（有的话）+ **对方是否已入网**（[savePeerPresence]）。
  /// 后者让空间卡片能显示「待加入」——只有这里分得清"对方还没来"与"来了但没设头像"。
  ///
  /// best-effort，但**前提是通道表新鲜**：本方法只在 `refreshEntranceMap()` 成功之后调用，
  /// 表非空才说明"排掉我之后没有别人"是确定结论；表为空（离线/还没拉过）时状态未知，
  /// 直接返回、什么都不写（否则卡片会误报「待加入」）。
  Future<void> _persistPeerMemberId() async {
    if (!_repo.hasEntranceMap) return;
    try {
      await AppLockService(widget.db ?? LocalDatabase.shared).savePeerPresence(
        spaceId: widget.spaceId,
        peerMemberId: _repo.resolvePeerMemberId(),
      );
    } catch (_) {
      // 落盘失败不影响聊天；下次刷新再试
    }
  }

  Future<void> _loadMyAvatar() async {
    var pid = _myMemberId;
    if (pid == null || pid.isEmpty) {
      pid = await _repo.resolveMyMemberId();
      if (pid == null || pid.isEmpty) return;
      _myMemberId = pid;
    }
    if (!mounted) return;
    try {
      final api = widget.api ?? ApiClient(effectiveServer);
      final bytes = await api.getAvatar(pid);
      if (bytes != null && mounted) setState(() => _myAvatarBytes = bytes);
    } catch (_) {
      // 网络失败：保持默认图标
    }
  }

  /// 加载对方头像（状态条显示用）。
  ///
  /// 为什么不复用消息流的 [_MessageAvatar]：那个直径写死 16（radius 16，是消息头像的
  /// 尺寸），状态条这里要更大，所以自己存一份 bytes 自己画。失败/未设置就保持默认人形。
  Future<void> _loadPeerAvatar() async {
    final pid = _peerMemberId;
    if (pid == null || pid.isEmpty) return;
    try {
      final api = widget.api ?? ApiClient(effectiveServer);
      final bytes = await api.getAvatar(pid);
      if (!mounted) return;
      setState(() => _peerAvatarBytes = bytes);
    } catch (_) {
      // 网络失败：保持默认图标
    }
  }

  /// 修改我的头像：选图 → 上传服务端（per-member 覆盖）→ 本地缓存刷新菜单显示。
  Future<void> _showAvatarUpload() async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await FilePicker.pickFiles(type: FileType.image);
    if (picked.isEmpty) return;
    final file = picked.first;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty || bytes.length > 2 * 1024 * 1024) {
      if (mounted) {
        _notice(context, l10n.chatPageAvatarTooLarge);
      }
      return;
    }
    try {
      final api = widget.api ?? ApiClient(effectiveServer);
      // 服务端在上传响应里回 member_id：上传方收不到自己的 profile.updated 广播，
      // 这个返回值是失效本端头像缓存最可靠的依据（重启路径 widget.memberId 为空，
      // 旧实现 invalidate(null) 静默失效失败 — 老板 2026-09-16 报告）
      final memberId = await _withAuth((t) => api.uploadAvatar(bytes, t));
      // 服务端回的是权威值；响应异常/旧服务端缺字段 → 退到本地反查
      final pid = (memberId != null && memberId.isNotEmpty)
          ? memberId
          : (_myMemberId ?? await _repo.resolveMyMemberId());
      if (!mounted) return;
      if (pid != null && pid.isNotEmpty) _myMemberId = pid;
      // 消息流里的头像走静态缓存：主动失效才会重拉（否则要重启才更新）
      _MessageAvatarState.invalidate(pid);
      setState(() => _myAvatarBytes = bytes);
      _notice(context, l10n.chatPageAvatarUploaded);
    } on ApiException catch (e) {
      if (!mounted) return;
      _notice(context, backendError(l10n, l10n.chatPageAvatarFailed(e.message)));
    } catch (e) {
      if (!mounted) return;
      _notice(context, l10n.chatPageAvatarFailed('$e'));
    }
  }

  /// 保存通道名（改名弹窗与「我的通道」弹层共用）：校验白名单 → PUT → 更新本地
  /// profile。返回 null = 成功；否则返回已本地化的错误文案（调用方自行展示——
  /// 弹窗走红字、弹层走顶部通知）。
  ///
  /// [allSpaces]（老板 2026-10-15）：勾了「应用于本机所有秘境」时，除当前空间外
  /// 还把名字扇出到本机其它空间（服务端各空间会话 + 本地各空间 profile 一起改），
  /// best-effort——单个空间失败不阻塞其余，也不打扰用户。
  Future<String?> _applyEntranceName(String rawName, AppLocalizations l10n,
      {bool allSpaces = false}) async {
    final name = rawName.trim();
    if (name.isEmpty) return l10n.chatPageRenameEntranceEmptyError;
    // 通道名字符白名单 + 长度上限（老板 2026-09-16）：只允许中英文、数字、
    // `_`、`-`，≤32；不合规提示重输（服务端另有 400 兜底）
    final violation = checkEntranceNamePolicy(name);
    if (violation != null) {
      return violation == EntranceNameViolation.tooLong
          ? l10n.chatPageRenameEntranceTooLongError(kEntranceNameMaxLength)
          : l10n.chatPageRenameEntranceInvalidError;
    }
    try {
      final api = widget.api ?? ApiClient(effectiveServer);
      await _withAuth((t) => api.updateEntranceName(name, t));
      _myEntranceName = name;
      // 同步本地 profile：重启后 ChatPage 从 profile 恢复新名字
      // （否则 loadProfile 读到向导完成时的旧名——2026-09-07 老板实测
      // app 菜单改名后退出重进回到 memberB）
      await _saveProfile();
      if (allSpaces) {
        // 扇出：其它秘境的服务端通道名 + 本地 profile 一起改（best-effort）
        unawaited(_fanoutOtherSpaces((t) => api.updateEntranceName(name, t)));
        unawaited(_rewriteOtherSpacesProfile(entranceName: name));
      }
      return null;
    } on ApiException catch (e) {
      return backendError(l10n, l10n.chatPageRenameFailed(e.message));
    } catch (e) {
      return l10n.chatPageRenameFailed('$e');
    }
  }

  /// 修改通道名称（服务端同步 + 本地刷新）——「我的通道」弹层里本机卡片右上角的
  /// 编辑角标进入（老板 2026-10-02：改名入口从弹层顶部的行挪回弹窗）。内容即
  /// 原合并前的「当前通道」弹窗（标题/通道名称输入框/说明文案），公钥展示不再要
  /// （5b74cf4 已删）。校验与提交走 [_applyEntranceName]（与弹层行内改名同一条逻辑）。
  Future<void> _showRenameEntranceDialog() async {
    final l10n = AppLocalizations.of(context)!;
    final ctrl = TextEditingController(text: _myEntranceName);
    // 名称为空/不合规警示（红字显示在输入框下方；开始填写即消）
    final nameError = ValueNotifier<String?>(null);
    // 名字/通道名编辑态切换：初始只读透明 + 右侧编辑按钮；点编辑 → 白底可编辑、按钮消失
    final editing = ValueNotifier<bool>(false);
    // 名称输入框焦点：点框内任意位置进编辑态时手动取焦（只读态点击不会自动取焦）
    final nameFocus = FocusNode();
    // 作用域勾选（老板 2026-10-15）：勾选＝这次改名同步到本机所有秘境（服务端
    // 各空间会话 + 本地各空间 profile 一起改）；不勾＝只改当前秘境。每次开弹窗
    // 默认不勾选（与邮件通知/我的身份弹窗同策略）
    final allSpaces = ValueNotifier<bool>(false);
    final saved = await showDialog<bool>(
      context: context,
      // 含输入框：禁误触关闭（点外面/系统返回都不行），必须点按钮（老板 2026-10-15）
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          // 标题居中（老板 2026-09-25：菜单下的弹窗标题一律居中）
          title: Center(child: Text(l10n.chatPageRenameEntranceTitle)),
          // 标题→备注 4 / 备注→内容 14（参考底部弹层的节奏；老板 2026-10-15）
          contentPadding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 大标题下的备注（老板 2026-10-02）：点明这里改的是什么、上限多少
              Text(
                l10n.chatPageRenameEntranceHint,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(ctx).colorScheme.outline,
                ),
              ),
              const SizedBox(height: 14),
              // 通道名称输入框：初始只读 + 透明背景，右侧「编辑」按钮；点编辑 →
              // 白底可编辑、按钮消失。点框内任意位置也进编辑态（老板 2026-09-23）
              ValueListenableBuilder<bool>(
                valueListenable: editing,
                builder: (_, isEditing, _) => TextField(
                  controller: ctrl,
                  focusNode: nameFocus,
                  readOnly: !isEditing,
                  onTap: () {
                    if (editing.value) return;
                    editing.value = true;
                    nameFocus.requestFocus();
                  },
                  decoration: InputDecoration(
                    labelText: l10n.chatPageEntranceListThisDevice,
                    border: const OutlineInputBorder(),
                    filled: isEditing, // 编辑态白底；只读态透明（沿用弹窗背景）
                    fillColor: Colors.white,
                    counterText: '',
                    suffixIcon: isEditing
                        ? null
                        : IconButton(
                            tooltip: l10n.chatPageEdit,
                            icon: const Icon(Icons.edit, size: 18),
                            visualDensity: VisualDensity.compact,
                            onPressed: () => editing.value = true,
                          ),
                  ),
                  // 输入框里直接拦住超长（老板 2026-09-28）：上限用 shared 策略里的
                  // 同一个常量（这里的拦截不替代提交时的白名单校验）
                  maxLength: kEntranceNameMaxLength,
                  // 开始填写即清除警示（与向导输入框一致）
                  onChanged: (_) {
                    if (nameError.value != null) nameError.value = null;
                  },
                ),
              ),
              ValueListenableBuilder<String?>(
                valueListenable: nameError,
                builder: (_, err, _) => err == null
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          err,
                          style: const TextStyle(
                            color: Colors.red,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
              ),
              // 作用域勾选（老板 2026-10-15）：勾选＝这次改名同步到本机所有秘境；
              // 不勾＝只改当前秘境。每次开弹窗默认不勾选。
              // 单秘境时整个不渲染（没有"其它秘境"可同步，老板 2026-10-17）
              if (_hasMultipleSpaces)
                ValueListenableBuilder<bool>(
                  valueListenable: allSpaces,
                  builder: (_, all, _) => LabeledCheckbox(
                    value: all,
                    label: l10n.settingsScopeAll,
                    onChanged: (v) => allSpaces.value = v,
                  ),
                ),
            ],
          ),
          actions: [
            CancelButton(onPressed: () => Navigator.of(ctx).pop(false)),
            FilledButton(
              onPressed: () async {
                final err = await _applyEntranceName(ctrl.text, l10n,
                    allSpaces: allSpaces.value);
                if (err != null) {
                  // 错误**就地显示**：红字挂在输入框下方（与 PIN 修改弹窗同款），
                  // 不再弹弹窗外的顶部通知条（老板 2026-10-02）
                  nameError.value = err;
                  return; // 校验/保存失败：留在弹窗里改
                }
                if (ctx.mounted) Navigator.of(ctx).pop(true);
              },
              child: Text(l10n.chatPageRenamingSubmit),
            ),
          ],
        ),
      ),
    );
    // 对话框 route 关闭动画完成后才 dispose（TextField 卸载后不再依赖
    // controller；立即 dispose 会触发红屏断言 _dependents.isEmpty）
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      ctrl.dispose();
      nameError.dispose();
      editing.dispose();
      nameFocus.dispose();
      allSpaces.dispose();
    });
    if (saved == true && mounted) setState(() {}); // 刷新弹层/菜单显示的新名字
  }

  /// 编辑**群组名字**（群空间状态条第一行；老板 2026-10-09）。
  ///
  /// **仅本机**——写进 per-space 资料（`groupName`），不跨成员同步（服务端没有空间
  /// 名字段）。允许**清空**：空串 = 回到"没有名字"态，状态条第一行重新只显示编辑
  /// 图标。非空走成员名同一套白名单校验（中英文/数字/_/-/emoji，≤
  /// [kMemberNameMaxLength]）。
  Future<void> _showGroupNameDialog() async {
    final l10n = AppLocalizations.of(context)!;
    final ctrl = TextEditingController(text: _groupName);
    final nameError = ValueNotifier<String?>(null);
    final saved = await showDialog<bool>(
      context: context,
      // 含输入框：禁误触关闭（点外面/系统返回都不行），必须点按钮（老板 2026-10-15）
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          // 标题居中（与菜单下其它弹窗一致）
          title: Center(child: Text(l10n.chatPageGroupNameTitle)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: l10n.chatPageGroupNameLabel,
                  border: const OutlineInputBorder(),
                  // 不显示 "3/32" 计数器（同改名弹窗：上限只是防超长）
                  counterText: '',
                ),
                // 输入框里直接拦住超长（同改名弹窗）
                maxLength: kMemberNameMaxLength,
                onChanged: (_) {
                  if (nameError.value != null) nameError.value = null;
                },
              ),
              ValueListenableBuilder<String?>(
                valueListenable: nameError,
                builder: (_, err, _) => err == null
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          err,
                          style: const TextStyle(
                            color: Colors.red,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
              ),
            ],
          ),
          actions: [
            CancelButton(onPressed: () => Navigator.of(ctx).pop(false)),
            FilledButton(
              onPressed: () {
                final name = ctrl.text.trim();
                // 允许清空：空 = 回到"没有名字"（状态条第一行显示编辑图标）
                if (name.isNotEmpty) {
                  // 用户名称白名单（与改名同源）：非空才校验
                  final violation = checkMemberNamePolicy(name);
                  if (violation != null) {
                    nameError.value = violation == MemberNameViolation.tooLong
                        ? l10n.chatPageRenameNameTooLongError(kMemberNameMaxLength)
                        : l10n.chatPageRenameNameInvalidError;
                    return;
                  }
                }
                Navigator.of(ctx).pop(true);
              },
              child: Text(l10n.chatPageRenamingSubmit),
            ),
          ],
        ),
      ),
    );
    // 对话框 route 关闭动画完成后才 dispose（同 _showRenameDialog：立即 dispose
    // 会触发红屏断言 _dependents.isEmpty）
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      ctrl.dispose();
      nameError.dispose();
    });
    if (saved == true && mounted) {
      _groupName = ctrl.text.trim();
      await _saveProfile(); // 落 per-space 资料（重启后从 profile 恢复）
      if (mounted) setState(() {});
    }
  }

  /// 「我的资料」弹层（老板 2026-10-17）：左头像、右侧名字（上）+ 性别（下）。
  /// 名字胶囊 → 现有改名弹窗；头像 → 共享的 [showMyAvatarFullscreen]
  /// （本人的头像：更换头像/应用所有秘境/保存图标）。
  ///
  /// 版式（老板 2026-10-17 二次调整）：横向身份卡 —— 左边渐变环头像，右边两行
  /// 左对齐（名字在上、性别在下），眼睛一眼就能把「人 + 资料」连起来，不再是一
  /// 列居中的控件塔。性别用小胶囊而非整行只读输入框（后者像没填完的表单）；
  /// 性别为空（向导未写入/老账号）整枚不显示，不留空壳。
  /// 桌面端弹层限宽 [kMyProfileSheetMaxWidth]（老板 2026-10-17）：BottomSheet
  /// 默认铺满窗口宽度，宽屏下这张身份卡会被拉成一条空旷的长带——限宽后居中
  /// 停在窗口底部，仍是底部弹层的形态。
  Future<void> _showMyProfileSheet() async {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final isFemale = _myGender == 'female';
    final isMale = _myGender == 'male';
    // 性别配色：男女各用 Logo 里的粉/蓝（与向导、改名弹窗的原图标同色）
    final genderColor = isFemale
        ? const Color(0xFFD6529C)
        : isMale
            ? const Color(0xFF3BAFFD)
            : scheme.outline;
    final genderLabel =
        isFemale ? l10n.wizardGenderFemale : isMale ? l10n.wizardGenderMale : '';
    // 头像组件句柄：外层方形热区（头像 + 编辑角标）通过它触发头像自己的点按
    // 决策（有图 → 全屏 / 没图 → 选图），避免外层另存一份图去猜（老板 2026-10-17）
    final avatarKey = GlobalKey<_MessageAvatarState>();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true, // 与「我的通道」等弹层同口径（老板 2026-10-02）
      // 桌面端限宽（老板 2026-10-17）：不限宽时整张身份卡随窗口拉长，头像和
      // 名字之间会隔出一大片空白。maxWidth 之外手机端不受影响（本就比它窄）。
      constraints: const BoxConstraints(maxWidth: kMyProfileSheetMaxWidth),
      builder: (ctx) {
        return SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 18),
                    child: Center(
                      child: Text(l10n.chatPageMenuMyProfile,
                          style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 16,
                              color: scheme.onSurface)),
                    ),
                  ),
                  Row(
                    children: [
                      // 头像（左侧大图）+ 编辑角标 = **一个方形热区**（老板 2026-10-17）：
                      // 点头像、点角标、点圆的四角都是同一个动作——有头像 = 开全屏
                      // （换头像从全屏里的「更换头像」按钮进），无头像 = 直接进选图。
                      // 去向由 _MessageAvatar.handleTap 按它自己的图缓存决定，不再由
                      // 外层按 _myAvatarBytes 猜——两个独立加载源不一致会错航/死区
                      // （2026-10-17 复查修复）。内层传 openFullscreenOnTap:false 让出
                      // 点击：否则内圈圆形手势和外层方形热区会抢同一个 tap。
                      // 外圈粉蓝渐变细环 + 一圈 surface 留白：弹层底色也是浅粉白，
                      // 没有环的话头像边界糊在背景里；细环颜色取自 Logo 的蓝/粉两端。
                      Clickable(
                        behavior: HitTestBehavior.opaque, // 方角空白也算热区
                        circle: true, // 反馈遮罩仍跟圆走，方角不染色
                        onTap: () => avatarKey.currentState?.handleTap(),
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(3),
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: LinearGradient(
                                  colors: [Color(0xFF3BAFFD), Color(0xFFD6529C)],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                              ),
                              child: Container(
                                padding: const EdgeInsets.all(3),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: scheme.surface,
                                ),
                                child: _MessageAvatar(
                                  key: avatarKey,
                                  memberId: _myMemberId,
                                  server: effectiveServer,
                                  api: widget.api,
                                  radius: 40,
                                  // 点击交给外层方形热区（统一一个动作）
                                  openFullscreenOnTap: false,
                                  onTapWithoutImage: () {
                                    Navigator.of(ctx).pop();
                                    _menuAction(_showAvatarUpload);
                                  },
                                  onReplaceAvatar: () {
                                    Navigator.of(ctx).pop();
                                    _menuAction(_showAvatarUpload);
                                  },
                                  onApplyAllSpaces: _hasMultipleSpaces
                                      ? (bytes) => _applyAvatarAllSpaces(bytes)
                                      : null,
                                  onSaveImage: (bytes) =>
                                      _saveAvatarImage(_myMemberName, bytes),
                                ),
                              ),
                            ),
                            // 编辑角标（老板 2026-10-17 二次调整）：原先是粉红圆徽 +
                            // 白色铅笔，比头像还抢眼；改成 surface 底 + 细描边 + 灰蓝
                            // 铅笔，压在环内右下角。不挂独立手势——整个方形热区共用
                            // 头像的动作，点角标就等于点头像。
                            Positioned(
                              right: 4,
                              bottom: 4,
                              child: IgnorePointer(
                                child: Container(
                                  padding: const EdgeInsets.all(5),
                                  decoration: BoxDecoration(
                                    color: scheme.surface,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                        color: scheme.outlineVariant),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black
                                            .withValues(alpha: 0.06),
                                        blurRadius: 4,
                                        offset: const Offset(0, 1),
                                      ),
                                    ],
                                  ),
                                  child: Icon(Icons.edit,
                                      size: 14,
                                      color: scheme.onSurfaceVariant),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 18),
                      // 右侧两行：名字（上）+ 性别（下），左对齐
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 名字胶囊：文字 + 编辑图标组成可点击胶囊（与「我的同伴」
                            // 弹层群名行同款交互），点击 → 收起弹层、打开改名弹窗。
                            // 实底 + Material/InkWell：透明底看不出「可以点」；实底
                            // 还把点击区撑到胶囊大小（只点文字太窄，桌面端不好点）。
                            // 底色随性别调（老板 2026-10-17）：女→淡粉 / 男→淡蓝，
                            // 与下方性别展示的粉/蓝呼应；性别未设 → 中性淡灰（与群名
                            // 胶囊及「添加秘境」等大按钮统一）。长名字由 Expanded 给
                            // 上限，超出省略。
                            Material(
                              color: _myGender.isEmpty
                                  ? Colors.black.withValues(alpha: 0.05)
                                  : genderColor.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(999),
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                key: const ValueKey('myProfileNameRow'),
                                mouseCursor: SystemMouseCursors.click,
                                onTap: () {
                                  Navigator.of(ctx).pop();
                                  _menuAction(_showRenameDialog);
                                },
                                child: Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(16, 9, 12, 9),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Flexible(
                                        child: Text(
                                          _myMemberName.isEmpty
                                              ? l10n.chatPageNameUnset
                                              : _myMemberName,
                                          style: TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 20,
                                            height: 1.2,
                                            color: _myMemberName.isEmpty
                                                ? scheme.outline
                                                : null,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Icon(Icons.edit_outlined,
                                          size: 18,
                                          color: scheme.onSurfaceVariant),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            // 性别：只读——**只有图标**（老板 2026-10-18：不显示
                            // 男/女文字，图标本身已够辨识），无底色（老板 2026-10-17：
                            // 胶囊有背景像可点的按钮，实际只是展示）。性别为空
                            // 不显示——留「未设置」空壳反而像缺数据待填。
                            // 读屏仍补上「性别 男/女」：光秃图标对读屏是哑的。
                            if (genderLabel.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Semantics(
                                label:
                                    '${l10n.chatPageGenderLabel} $genderLabel',
                                child: Icon(
                                  isFemale ? Icons.female : Icons.male,
                                  size: 16,
                                  color: genderColor,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 修改我的名字（服务端同步 + 本地刷新菜单显示）。
  /// （原「当前通道」改名弹窗 2026-10-02 并入「我的通道」弹层，公钥展示一并删除。）
  Future<void> _showRenameDialog() async {
    final l10n = AppLocalizations.of(context)!;
    final ctrl = TextEditingController(text: _myMemberName);
    // 名称为空/全空格警示（红字显示在输入框下方；开始填写即消）
    final nameError = ValueNotifier<String?>(null);
    // 名字/通道名编辑态切换：初始只读透明 + 右侧编辑按钮；点编辑 → 白底可编辑、按钮消失
    final editing = ValueNotifier<bool>(false);
    // 名称输入框焦点：点框内任意位置进编辑态时手动取焦（只读态点击不会自动取焦）
    final nameFocus = FocusNode();
    // 作用域勾选（老板 2026-10-15）：勾选＝这次改名同步到本机所有秘境（服务端
    // 各空间会话 + 本地各空间 profile 一起改）；不勾＝只改当前秘境。每次开弹窗
    // 默认不勾选（与邮件通知弹窗同策略——扇出必须是每次显式 opt-in）
    final allSpaces = ValueNotifier<bool>(false);
    final saved = await showDialog<bool>(
      context: context,
      // 含输入框：禁误触关闭（点外面/系统返回都不行），必须点按钮（老板 2026-10-15）
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          // 标题居中（老板 2026-09-25：菜单下的弹窗标题一律居中）
          title: Center(child: Text(l10n.chatPageRenameNameTitle)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 名字输入框：初始只读 + 透明背景，右侧「编辑」按钮；点编辑 →
              // 白底可编辑、按钮消失（老板要求 2026-09-09）。
              // 点框内任意位置也进编辑态（老板 2026-09-23）：用 TextField 自带的
              // onTap 派发，不额外套 GestureDetector（会和输入框内部手势抢 arena）
              ValueListenableBuilder<bool>(
                valueListenable: editing,
                builder: (_, isEditing, _) => TextField(
                  controller: ctrl,
                  focusNode: nameFocus,
                  readOnly: !isEditing,
                  onTap: () {
                    if (editing.value) return;
                    editing.value = true;
                    nameFocus.requestFocus();
                  },
                  decoration: InputDecoration(
                    labelText: l10n.chatPageRenameNameLabel,
                    border: const OutlineInputBorder(),
                    filled: isEditing, // 编辑态白底；只读态透明（沿用弹窗背景）
                    fillColor: Colors.white,
                    // 不显示 "3/32" 计数器（老板 2026-09-28）：上限只是防超长，
                    // 弹窗里不必多一行；下面 maxLength 才是硬拦
                    counterText: '',
                    suffixIcon: isEditing
                        ? null
                        : IconButton(
                            tooltip: l10n.chatPageEdit,
                            icon: const Icon(Icons.edit, size: 18),
                            visualDensity: VisualDensity.compact,
                            onPressed: () => editing.value = true,
                          ),
                  ),
                  // 输入框里直接拦住超长（老板 2026-09-28）：以前能一直敲、点保存才被
                  // 策略拒（白敲一通）。上限用 shared 策略里的同一个常量
                  // （这里的拦截不替代提交时的白名单校验）。
                  maxLength: kMemberNameMaxLength,
                  // 开始填写即清除空名警示（与向导输入框一致）
                  onChanged: (_) {
                    if (nameError.value != null) nameError.value = null;
                  },
                ),
              ),
              ValueListenableBuilder<String?>(
                valueListenable: nameError,
                builder: (_, err, _) => err == null
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          err,
                          style: const TextStyle(
                            color: Colors.red,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
              ),
              // 作用域勾选（老板 2026-10-15）：勾选＝这次改名同步到本机所有秘境；
              // 不勾＝只改当前秘境。每次开弹窗默认不勾选。
              // 单秘境时整个不渲染（没有"其它秘境"可同步，老板 2026-10-17）
              if (_hasMultipleSpaces)
                ValueListenableBuilder<bool>(
                  valueListenable: allSpaces,
                  builder: (_, all, _) => LabeledCheckbox(
                    value: all,
                    label: l10n.settingsScopeAll,
                    onChanged: (v) => allSpaces.value = v,
                  ),
                ),
            ],
          ),
          actions: [
            CancelButton(onPressed: () => Navigator.of(ctx).pop(false)),
            FilledButton(
              onPressed: () async {
                final name = ctrl.text.trim();
                if (name.isEmpty) {
                  // 空/全空格：红字警示并停留（不再静默跳过）
                  nameError.value = l10n.chatPageRenameMyselfEmptyError;
                  return;
                }
                // 用户名称白名单（老板 2026-09-16）：中英文/数字/`_`/`-`/emoji，≤32
                final violation = checkMemberNamePolicy(name);
                if (violation != null) {
                  nameError.value = violation == MemberNameViolation.tooLong
                      ? l10n.chatPageRenameNameTooLongError(kMemberNameMaxLength)
                      : l10n.chatPageRenameNameInvalidError;
                  return;
                }
                // 不允许改成与对方相同的名字（老板 2026-09-10）
                if (widget.peerName != null && name == widget.peerName) {
                  nameError.value = l10n.chatPageRenameSameAsPeerError;
                  return;
                }
                try {
                  final api = widget.api ?? ApiClient(effectiveServer);
                  await _withAuth((t) => api.updateMemberName(name, t));
                  _myMemberName = name;
                  // 同步本地 profile：重启后 ChatPage 从 profile 恢复新名字
                  // （否则 loadProfile 读到向导完成时的旧名——2026-09-07 老板实测
                  // app 菜单改名后退出重进回到 memberB）
                  await _saveProfile();
                  if (allSpaces.value) {
                    // 扇出：其它秘境的服务端成员名 + 本地 profile 一起改
                    // （best-effort，单个空间失败不阻塞其余）
                    unawaited(_fanoutOtherSpaces((t) => api.updateMemberName(name, t)));
                    unawaited(_rewriteOtherSpacesProfile(memberName: name));
                  }
                  if (ctx.mounted) Navigator.of(ctx).pop(true);
                } on ApiException catch (e) {
                  if (ctx.mounted) {
                    _notice(ctx, backendError(l10n, l10n.chatPageRenameFailed(e.message)));
                  }
                } catch (e) {
                  if (ctx.mounted) {
                    _notice(ctx, l10n.chatPageRenameFailed('$e'));
                  }
                }
              },
              child: Text(l10n.chatPageRenamingSubmit),
            ),
          ],
        ),
      ),
    );
    // 对话框 route 关闭动画完成后才 dispose（TextField 卸载后不再依赖
    // controller；立即 dispose 会触发红屏断言 _dependents.isEmpty）
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      ctrl.dispose();
      nameError.dispose();
      editing.dispose();
      nameFocus.dispose();
      allSpaces.dispose();
    });
    if (saved == true && mounted) setState(() {}); // 刷新菜单显示的新名字
  }

  /// 同步当前名字到本地 profile（改名/改通道名后调用——重启从 profile 恢复）。
  /// 按 spaceId 写：多空间下各空间一份，别互相覆写（2026-09-22）。
  Future<void> _saveProfile() async {
    await AppLockService(widget.db ?? LocalDatabase.shared).saveProfile(
      spaceId: widget.spaceId,
      memberName: _myMemberName,
      peerName: _peerName,
      entranceName: _myEntranceName,
      myGender: _myGender,
      peerGender: _peerGender,
      mySlot: _mySlot,
      peerSlot: _peerSlot,
      // 空间类型（切空间卡片的群组配色要用）
      mode: _spaceMode,
      // 群组名字（仅本机；群空间状态条第一行用）
      groupName: _groupName,
    );
  }

  /// 退出秘境（等价 TUI /exit）：确认后回到锁屏（LockPage），下次解锁重新认证。
  Future<void> _showExitAppDialog() async {
    final l10n = AppLocalizations.of(context)!;
    final shouldExit = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          // 标题居中（老板 2026-09-25：菜单下的弹窗标题一律居中）
          title: Center(child: Text(l10n.chatPageExitTitle)),
          content: Text(l10n.chatPageExitMessage),
          actions: [
            CancelButton(onPressed: () => Navigator.of(ctx).pop(false)),
            FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(l10n.chatPageMenuExit)),
          ],
        ),
      ),
    );
    if (shouldExit == true) {
      // 彻底关闭应用（等价 TUI /exit；不再回 LockPage——未设 PIN 时锁屏不应激活）
      exit(0);
    }
  }

  /// 阅后即焚时长选择弹层（右上角菜单全局 / 长按菜单单条消息共用）：
  /// 返回 (秒数, 是否应用到所有秘境)；null=取消。[current] 为当前值。
  /// 2026-10-16 起改为任意时长（对数滑动轴 1 分钟 ~ 60 天，右端「关闭」顶点，
  /// 粒度随时长升档），见 [BurnDurationSheet]。
  ///
  /// [scopeAllLabel] 非空（全局设置入口）= 弹层里显示「应用于本机所有秘境」
  /// 勾选框；逐条消息的燃焚没有空间维度，传 null。
  Future<({int seconds, bool scopeAll})?> _pickBurnSeconds({
    required int current,
    String? scopeAllLabel,
  }) async {
    return showBurnDurationSheet(
      context: context,
      current: current,
      scopeAllLabel: scopeAllLabel,
    );
  }

  /// 把阅后即焚设置写到本机**所有空间**（勾了「应用于本机所有秘境」时）：
  /// 燃焚是纯本地设置（无服务端参与），逐空间写各自的 per-space 键。当前空间
  /// 先落（Vault 取不到也不丢它），其余 best-effort——单个空间失败不阻塞其余。
  Future<void> _saveBurnAllSpaces(int seconds) async {
    final db = widget.db ?? LocalDatabase.shared;
    await BurnAfterSettings(db, spaceId: widget.spaceId).save(seconds);
    final spaces = VaultSession.current?.spaces ?? const <AppLockPayload>[];
    for (final space in spaces) {
      if (space.spaceId == widget.spaceId) continue;
      try {
        await BurnAfterSettings(db, spaceId: space.spaceId).save(seconds);
      } catch (_) {
        // 单个空间失败不阻塞其余
      }
    }
  }

  /// 顶栏 ⏱：选择阅后即焚时长（保存到本设备设置，发送新消息时生效）。
  Future<void> _showBurnPicker() async {
    final settings = BurnAfterSettings(widget.db ?? LocalDatabase.shared, spaceId: widget.spaceId);
    final current = await settings.load();
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final picked = await _pickBurnSeconds(
      current: current,
      // 全局设置才有"所有秘境"之说；单秘境时不传 = 不渲染勾选框（老板 2026-10-17）
      scopeAllLabel: _hasMultipleSpaces ? l10n.settingsScopeAll : null,
    );
    if (picked == null || !mounted) return;
    if (picked.scopeAll) {
      await _saveBurnAllSpaces(picked.seconds);
    } else {
      await settings.save(picked.seconds);
    }
    if (!mounted) return;
    setState(() => _burnSeconds = picked.seconds);
    _notice(
      context,
      picked.seconds == 0
          ? l10n.chatPageBurnOff
          : l10n.chatPageBurnWillDelete(_burnOptionLabel(picked.seconds, l10n)),
    );
  }

  /// 长按菜单「阅后即焚」：选择时长后应用到被点击的这条消息（本机生效，
  /// 纯本地；老板要求 2026-09-10）。可选「关闭」取消已有阅后即焚、选时长
  /// 新设或调整；到期由 repo.tombstoneExpired 统一打墓碑。
  Future<void> _setMessageBurn(HistoryMessage m) async {
    final l10n = AppLocalizations.of(context)!;
    // 不传 scopeAllLabel：单条消息的燃焚没有"所有秘境"维度
    final picked = await _pickBurnSeconds(current: m.burnAfterSeconds);
    if (picked == null || !mounted) return;
    final seconds = picked.seconds;
    final ok = await _repo.setMessageBurn(m.env.messageId, seconds);
    if (!mounted) return;
    if (!ok) {
      _notice(context, l10n.chatPageBurnFailed);
      return;
    }
    // 就地更新列表里该消息的 burn 状态（倒计时即刻生效，不用整表刷新）
    final expiresAt = seconds > 0
        ? DateTime.now().millisecondsSinceEpoch + seconds * 1000
        : null;
    setState(() {
      _messages = [
        for (final x in _messages)
          if (x.env.messageId == m.env.messageId)
            (env: x.env, plaintext: x.plaintext, sender: x.sender,
                attachment: x.attachment, expiresAt: expiresAt,
                createdAt: x.createdAt, burnAfterSeconds: seconds,
                quote: x.quote, deleted: x.deleted,
                deletedKind: x.deletedKind,
                // 长按手动设置（与 repo.setMessageBurn 落盘一致）；取消时无标签
                burnManual: seconds > 0, status: x.status, meta: x.meta)
          else
            x,
      ];
    });
    _notice(
      context,
      seconds == 0
          ? l10n.chatPageBurnOff
          : l10n.chatPageBurnWillDelete(_burnOptionLabel(seconds, l10n)),
    );
  }

  /// iOS：认证后把 APNs device token 注册到 Server（PROTOCOL.md §7.3）。
  /// 推送只发"有新消息"提示；注册失败不影响聊天（WS/轮询兜底）。
  Future<void> _registerPushToken() async {
    if (!Platform.isIOS) return;
    try {
      const channel = MethodChannel('einz/apns');
      final apnsToken = await channel.invokeMethod<String>('getToken');
      if (apnsToken != null && apnsToken.isNotEmpty) {
        await _withAuth((t) => _repo.api.registerPushToken('ios', apnsToken, t));
      }
    } catch (_) {
      // 忽略：APNs 未就绪（模拟器/未配 entitlement）时静默降级
    }
  }

  /// 补登安装级标识（POST /entrances/install-uid，幂等）。
  ///
  /// 用途：多空间下服务端要能知道"这台物理设备上挂了哪几个空间"（运维/审计），而
  /// install_uid 是随 create/join 上报的——**存量通道**（多空间上线前入网的那批）不再走
  /// 入网流程，只能在这里补一次。离线/老服务端（无此端点）时静默降级：它只是服务端侧
  /// 认知，不参与任何功能。
  ///
  /// 只写**本空间**那一行：别的空间由客户端在那边进一次时各自补登。
  Future<void> _registerInstallUid() async {
    if (_session.token.isEmpty) return;
    try {
      final uid = await AppLockService(widget.db ?? LocalDatabase.shared).installUid();
      await _withAuth((t) => (widget.api ?? ApiClient(effectiveServer)).registerInstallUid(uid, t));
    } catch (_) {
      // 忽略
    }
  }

  /// 上报本通道客户端信息（POST /entrances/client，幂等）：client='app' + 本机
  /// 版本号（`yymm.ddhh.mm`，读不到就不带）。每次进聊天页调一次——升级后下次
  /// 启动自动跟上，「我的设备通道」卡片据此显示各设备跑的版本。纯展示字段，
  /// 离线/老服务端静默降级（同 _registerInstallUid）。
  ///
  /// 读到的版本顺带存进 [_myAppVersion]（本机卡片的版本段用）——**只在这里读
  /// 一次**，弹层里直接用字段，不现读平台调用（见字段注释）。
  Future<void> _registerClientInfo() async {
    if (_session.token.isEmpty) return;
    try {
      final version = await appVersionString();
      _myAppVersion = version;
      await _withAuth((t) => (widget.api ?? ApiClient(effectiveServer))
          .reportClientInfo('app', t, appVersion: version));
    } catch (_) {
      // 忽略
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    uiStyleNotifier.removeListener(_onUiStyleChanged);
    attachmentStorageNotifier.removeListener(_onAttachmentStorageChanged);
    _ticker?.cancel();
    _peerTicker?.cancel();
    _notifyTicker?.cancel(); // 邮件通知"待确认"期间的那一路轮询
    _recordTimer?.cancel();
    _idleTimer?.cancel(); // 前台无操作锁屏
    _input.removeListener(_onInputInteraction);
    _highlightTimer?.cancel(); // 跳转高亮定时清除（防 dispose 后 setState）
    _ampSub?.cancel();
    _ws?.connected.removeListener(_onWsStatusChanged);
    _ws?.stop();
    _voiceCall?.state.removeListener(_onVoiceCallStateChanged);
    _voiceCall?.dispose();
    _unreadTimer?.cancel();
    _scrollController.removeListener(_maybeLoadOlder);
    _scrollController.removeListener(_onScrollForRead);
    _inputFocusNode.removeListener(_onInputFocusChanged);
    _scrollController.dispose();
    _input.dispose();
    _inputFocusNode.dispose();
    _audioPlaybackVersion.dispose();
    super.dispose();
  }

  /// 手动锁屏（顶栏锁图标）：立即推覆盖锁屏 → 解锁成功 pop 回本页（保留消息状态）。
  /// canDismiss=false：返回手势/返回键都被挡，必须输对锁屏码才能回聊天
  /// （老板 2026-09-16 要求"强化安全性"）。
  void _lockNow() {
    _pushLockOverlay();
  }

  /// App 生命周期：切后台记时，回前台超过阈值 → 覆盖锁屏（保留聊天页状态）。
  ///
  /// **计时认「离开 resumed」**（inactive/hidden/paused 出向都记，2026-10-17 评审）：
  /// 只认 paused 会漏掉 iOS app 切换器/通知下拉等「只到 inactive、不到 paused」的
  /// 覆盖路径——聊天界面躺在切换器快照里几小时，回来却不用输 PIN（安全绕过）。
  /// 而 iOS 回前台序列 `paused → inactive → resumed` 里**回程的 inactive 不可再
  /// 记**（老板 2026-10-17 实测 bug：它会把后台开始时刻覆写成"刚回来"→ 永不锁），
  /// 用 `_wasResumed` 区分：出向（之前还在前台）记、回程（之前已离场）不记。
  ///
  /// 两条硬规则（老板 2026-09-20 实测报的 bug）：
  /// 1. **没设锁屏码就不要锁**：`_hasPin=false` 时锁屏页只会显示"尚未设置锁屏码"
  ///    提示页，既没意义又让人以为 App 出了问题——直接不锁，并照常补报已读。
  /// 2. **锁上就不能一点退回**：原先走的是默认 `canDismiss: true`，覆盖锁屏左上角
  ///    有返回箭头、点一下就绕过锁屏回到对话（安全漏洞）。改 `canDismiss: false`
  ///    与手动锁屏同口径：必须输对 PIN 才回聊天。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasResumed = _appResumed;
    _appResumed = state == AppLifecycleState.resumed; // 回执：只有前台才允许标已读
    if (wasResumed && state != AppLifecycleState.resumed) {
      // 出向前台：记录后台开始时刻（含 app 切换器/通知下拉/息屏等一切覆盖路径）
      _lockTimer.recordBackgrounded(DateTime.now());
      // idle 锁计时器同步停掉：后台由后台锁接管，避免到点在后台触发
      _idleTimer?.cancel();
      _idleTimer = null;
      // 进后台（含息屏）：**主动**断开 WS，让对端几秒内就看到离线。
      // 不这么做的话要等服务端的 30s 心跳超时、再等对端 30s 轮询，最长约 90 秒里
      // 对方还以为你在线（老板 2026-09-26）。
      //
      // **通话中绝不停**：贴耳通话必然息屏，停了就直接把通话掐断——通话期间靠
      // iOS 的 audio 后台模式 + 常亮维持，本来也不会进到这里断链。
      if (_voiceCall?.state.value.inCall != true) {
        unawaited(_ws?.stop());
      }
    } else if (state == AppLifecycleState.resumed) {
      // 回到前台：把后台时停掉的 WS 接回来（通话中的那次没停，这里幂等重连）
      _startRealtime();
      unawaited(_refreshOtherUnread());
      // 邮件通知：确认链接是在 App 外面（浏览器）点的，回前台正是最该重查的时刻
      unawaited(_refreshNotifyEmail());
      final relock = _lockTimer.shouldRelock(now: DateTime.now());
      _lockTimer.clear();
      // 不需要锁的两条路径：没离开够久（用户一直在看）、或本机压根没设锁屏码。
      // 两种都照常补报已读——别把"未超时不锁"顺手吞掉（原逻辑就在这个分支里报已读）
      if (!relock || !_hasPin || !mounted) {
        _scheduleReadReport();
        // 前台无操作锁屏：回到前台重新计时（给一个完整的 idle 窗口）
        _armIdleLock();
        return;
      }
      _pushLockOverlay();
    }
  }

  // ==================== 前台无操作锁屏（老板 2026-10-17）====================
  // 一直前台亮屏、但超过 [kLockSeconds] 秒没任何交互（点/滑/滚/打字）也进锁屏。
  // 与后台锁共用同一阈值（kLockSeconds，将来统一做成用户可调菜单项）。
  //
  // 用「一次性 Timer + 每次交互重排」而非周期 Timer：
  //  · 空闲时 Timer 睡着，零唤醒——比每秒醒一次查墙钟更省资源（老板关注点）；
  //  · 用 Dart 逻辑时钟（Timer 由 FakeAsync 驱动），widget 测试可直接
  //    tester.pump(Duration(seconds: 30)) 推进到触发点，无需 runAsync 实睡。
  // 交互信号：build 根的 Listener（点/滑/拖，onPointerDown）+ 根 ScrollNotification
  //（桌面滚轮/触控板滚动，不产生 pointer down）+ 输入框控制器监听（打字）。
  // 「在栈顶」信号：ModalRoute.isCurrent（真实路由状态），**不用** FocusNode
  // hasFocus——后者只在焦点链经过本子树时为 true，手机上无输入焦点时恒 false，
  // 会漏锁（2026-10-17 评审揪出）。到点若被弹层/锁屏盖着：不硬锁，重排一个
  // 新窗口——关掉弹层后最多 30s 内必锁，安全方向不变，也免去弹层期间误锁。
  // 锁屏页 pop 回聊天：push Future 完成（_pushLockOverlay）重排新窗口。

  /// 安排/重排 idle 锁屏计时器到"现在+[kLockSeconds]"。交互、回前台、解锁回
  /// 聊天、PIN 状态确定后都调它。不满足锁条件时直接清掉计时器（不排）。
  void _armIdleLock() {
    _idleTimer?.cancel();
    _idleTimer = null;
    if (!_hasPin) return; // 没设 PIN 不锁（与后台锁同一条硬规则）
    if (!_appResumed) return; // 后台中：交给后台锁路径，回前台再排
    if (_voiceCall?.state.value.inCall == true) return; // 通话中不锁
    if (_lockOverlayShown) return; // 锁屏已盖着：等解锁 pop 再排
    _idleTimer = Timer(Duration(seconds: _lockSeconds), _fireIdleLock);
  }

  /// 交互信号刷新：点/滑/拖都走这里（build 根 Listener）。滚动走
  /// [_onScrollInteraction]，打字走 [_onInputInteraction]，都落到 _armIdleLock。
  void _onPointerInteraction() {
    _armIdleLock();
  }

  /// 滚动（桌面滚轮/触控板、移动端惯性滚动）也算交互——只看消息列表持续滚动
  /// 的用户不该被锁。
  void _onScrollInteraction() {
    _armIdleLock();
  }

  /// 输入框文本变化 → 也算交互（打字）。
  void _onInputInteraction() {
    _armIdleLock();
  }

  /// 推严格锁屏覆盖页（手动锁/后台锁/idle 锁共用入口）。防重复 push 竞态；
  /// pop 回聊天（解锁成功）后重排 idle 计时，给一个完整的新窗口。
  void _pushLockOverlay() {
    if (_lockOverlayShown) return;
    _lockOverlayShown = true;
    _idleTimer?.cancel(); // 锁屏盖着期间不计时
    _idleTimer = null;
    Navigator.of(context)
        .push(MaterialPageRoute(
            builder: (_) => const LockPage(asOverlay: true, canDismiss: false)))
        .whenComplete(() {
      _lockOverlayShown = false;
      _armIdleLock(); // 解锁成功回到聊天：重新计时
    });
  }

  /// 到点触发：前置条件在 _armIdleLock 已挡过；这里兜底复查"期间状态是否变了"
  ///（如来电、被弹层盖住、切后台）。被盖着时重排新窗口而非硬锁——弹层关闭后
  /// 自然触发下一次判定，安全方向不变。
  void _fireIdleLock() {
    if (!mounted) return;
    if (!_appResumed || !_hasPin) return;
    if (_voiceCall?.state.value.inCall == true) return;
    if (ModalRoute.of(context)?.isCurrent != true) {
      // 被弹层/对话框盖着：重排新窗口，等它关掉后自然重判
      _armIdleLock();
      return;
    }
    _pushLockOverlay();
  }

  /// 首次载入：先用本地缓存秒开（离线/慢网也能立刻看到历史）→ 再同步全量 →
  /// 重新渲染最近一页（UI 分页懒加载）。
  Future<void> _loadInitial() async {
    // 1) 本地缓存秒开（不等网络）
    try {
      final cached = await _repo.historyRecent(limit: _pageSize);
      if (mounted && cached.isNotEmpty) {
        setState(() => _messages = cached);
        _scrollToLatest(animate: false);
      }
    } catch (_) {
      // 解密失败（如缺归档密钥）忽略：继续走网络同步
    }
    _initialLoaded = true; // 允许 _refreshLocal 工作（此后 _lastLoadedSequence 有意义）

    // 2) 同步全量 → 清理到期 → 用最新本地历史覆盖
    try {
      await _repo.sync();
      // 到期焚毁：媒体缓存定点删（尽力而为、不等待——测试/主流程不被文件 I/O 阻塞）
      for (final id in await _repo.tombstoneExpired()) {
        unawaited(MediaCache.deleteFor(widget.spaceId, id));
        unawaited(AttachmentStore.deleteFor(widget.spaceId, id)); // stored 模式的留存明文同样要删
      }
      await _repo.refreshEntranceMap();
      await _persistPeerMemberId();
      final recent = await _repo.historyRecent(limit: _pageSize);
      if (!mounted) return;
      setState(() => _messages = recent);
      // stored 模式：首屏附件的明文后台落盘（不阻塞首屏）
      unawaited(_autoStoreAttachments(recent));
      // 首次载入即定位到最新消息（老板实测 2026-09-09：原来停在最早消息处，
      // 要等 ticker 自动刷新才滚到底）——直接跳转不播动画，进入即见最新
      _scrollToLatest(animate: false);
      // 首屏回填上报"已送达"。
      unawaited(_reportDeliveredIfAdvanced());
      // 已读：**看到最新即已读**（老板 2026-10-08 拍板，放宽 2026-09-12 的
      // "补拉的历史不等于人看过/首屏不报已读"）——进入或切换到本空间后列表已
      // 跳到最新，用户就在看着它。不补这一次的话，切进来读完、没有实时消息、
      // 也没切后台再回前台时，读取水位永不推进 → 换出去/重开 App 角标还在。
      // 前台/本页最上层/列表贴底三道光卡仍由 _scheduleReadReport 把关。
      _scheduleReadReport();
      // 载入对方回执 → 自己消息可显示双勾（sync 内已拉过，此处兜底一次）
      unawaited(_loadPeerReceipts());
      // 启动孤儿清理：本地库已无对应消息的缓存 + 历史遗留 temp 文件（不阻塞首屏）。
      // 缓存已按空间分目录 → 只扫本空间，保留名单也只取本空间
      unawaited(_repo.allMessageIds().then((ids) => MediaCache.prune(widget.spaceId, ids)));
    } catch (_) {
      // 网络抖动忽略：本地缓存已上屏，等 ticker 重试
    }
  }

  /// 纯本地增量刷新（不发网络）：把本地新增/变更的消息并入列表——发送后「乐观回显」
  /// 与收到消息先上屏都用它，避免等 sync 网络往返（老板 2026-09-12）。
  /// 合并语义：按 messageId 就地替换（刷新 pending→sent/failed 状态），新 id 追加；
  /// 墓碑单调（本地已删的不会被旧读覆盖复活）；仅在有新消息时滚到底。
  Future<void> _refreshLocal({bool realtime = false}) async {
    if (!_initialLoaded) return;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      // 阅后即焚：到期消息打本地墓碑（纯本地）+ 定点删媒体解密缓存（不等待）
      for (final id in await _repo.tombstoneExpired(now: now)) {
        unawaited(MediaCache.deleteFor(widget.spaceId, id));
        unawaited(AttachmentStore.deleteFor(widget.spaceId, id));
      }
      final fresh = await _repo.historySince(afterSequence: _lastLoadedSequence);
      // stored 模式：新到附件的明文**收到即落盘**（消息流里点开就能看）
      unawaited(_autoStoreAttachments(fresh));
      // 补偿：列表里仍标 pending/failed 的消息按 id 重读。它们的 server_sequence
      // 是本端 postMessage 后才回填的，可能"迟到"到高水位之下——只靠 historySince
      // 会永久漏掉，界面就一直显示"发送中"（老板 2026-09-12 实测）。
      final inflightIds = [
        for (final m in _messages)
          if (!m.deleted && (m.status == 'pending' || m.status == 'failed'))
            m.env.messageId,
      ];
      final inflight = await _repo.historyByMessageIds(inflightIds);
      if (!mounted) return;
      // inflight 后写入 → 同 id 时以它为准（读得更晚，状态更准）
      final freshById = {
        for (final f in fresh) f.env.messageId: f,
        for (final f in inflight) f.env.messageId: f,
      };
      final existingIds = {for (final m in _messages) m.env.messageId};
      final added = freshById.values
          .where((f) => !existingIds.contains(f.env.messageId))
          .toList();
      setState(() {
        _messages = [
          for (final m in _messages)
            if (m.expiresAt != null && m.expiresAt! <= now && !m.deleted)
              _asDeleted(m)
            else if (!freshById.containsKey(m.env.messageId))
              m
            else
              _mergeRefreshed(m, freshById[m.env.messageId]!),
          ...added,
        ];
      });
      if (added.isNotEmpty) _scrollToLatest();
      // 回执：本端确实收到了对方的这些消息 → 上报"已送达"（补拉/首屏也算）。
      // "已读"只在 [realtime]（WS 实时到达）时才报——补拉的历史不等于人看过
      // （老板 2026-09-12）。
      unawaited(_reportDeliveredIfAdvanced());
      unawaited(_loadUnsentCount());
      if (realtime && added.isNotEmpty) _scheduleReadReport();
    } catch (_) {
      // 本地读取失败忽略，下次刷新重试
    }
  }

  /// 本端已加载的"对方消息"里最大的 serverSequence（未同步/无 seq 的忽略）。
  int get _maxLoadedPeerSeq {
    var maxSeq = 0;
    for (final m in _messages) {
      if (m.sender != 'peer') continue;
      final s = m.env.serverSequence;
      if (s != null && s > maxSeq) maxSeq = s;
    }
    return maxSeq;
  }

  /// 上报"已送达"（单调 + 防抖；失败忽略，下次会再报——重复上报服务端幂等）。
  Future<void> _reportDeliveredIfAdvanced() async {
    final seq = _maxLoadedPeerSeq;
    if (seq <= _lastReportedDeliveredSeq) return;
    // 成功才推进防抖标记：否则一次失败就再也不会重报（服务端永远缺这一档）
    if (await _reportReceiptQuietly(deliveredUptoSeq: seq)) {
      _lastReportedDeliveredSeq = seq;
    }
  }

  /// 上报"已读"：**仅当** App 在前台、本页是最上层（未被锁屏/弹层盖住）、且列表
  /// 贴底（用户确实看到了最新消息）时才报——避免把没看过的消息标已读。
  /// post-frame 执行：setState 刚提交时布局未完成，extentAfter 不可信。
  void _scheduleReadReport() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_appResumed) return;
      if (ModalRoute.of(context)?.isCurrent != true) return;
      if (!_scrollController.hasClients) return;
      if (_scrollController.position.extentAfter > 48) return; // 上滑看历史 → 不标已读
      final seq = _maxLoadedPeerSeq;
      if (seq <= _lastReportedReadSeq) return;
      // 同上：成功才推进防抖标记
      unawaited(_reportReceiptQuietly(readUptoSeq: seq).then((ok) {
        if (ok) _lastReportedReadSeq = seq;
      }));
    });
  }

  /// 上报回执；返回是否成功（失败时调用方保留重试机会）。
  Future<bool> _reportReceiptQuietly({int? deliveredUptoSeq, int? readUptoSeq}) async {
    try {
      await _repo.reportReceipts(
        deliveredUptoSeq: deliveredUptoSeq,
        readUptoSeq: readUptoSeq,
      );
      return true;
    } catch (_) {
      // 网络抖动忽略；下次刷新会再报（单调，重复上报无害）
      return false;
    }
  }

  /// 用本地最新一行覆盖旧记录，但墓碑单调（任一为已删即已删），避免一个早于
  /// tombstoneMessage 发起的读晚到后把已删内容「复活」。
  HistoryMessage _mergeRefreshed(HistoryMessage old, HistoryMessage fresh) {
    final deleted = old.deleted || fresh.deleted;
    if (deleted == fresh.deleted) return fresh;
    return (
      env: fresh.env,
      plaintext: fresh.plaintext,
      sender: fresh.sender,
      attachment: fresh.attachment,
      expiresAt: fresh.expiresAt,
      createdAt: fresh.createdAt,
      burnAfterSeconds: fresh.burnAfterSeconds,
      quote: fresh.quote,
      deleted: deleted,
      // 墓碑单调：fresh 未删而 old 已删时，来路随 old（否则随 fresh）
      deletedKind: fresh.deleted ? fresh.deletedKind : old.deletedKind,
      burnManual: fresh.burnManual,
      status: fresh.status,
      meta: fresh.meta,
    );
  }

  /// 已加载列表中最新的 serverSequence（未同步=最新时返回 0）。
  int get _lastLoadedSequence {
    for (final m in _messages.reversed) {
      final s = m.env.serverSequence;
      if (s != null) return s;
    }
    return 0;
  }

  /// 滚动位置变化：列表一旦贴底（用户或自动跳转把最新消息带到眼前）即视为
  /// "看到最新"，上报已读。只在"离开底部 → 回到贴底"的跨越时刻触发一次，避免
  /// 拖动过程中每帧都排一次回调。首屏/切换进入的那次跳底由 `_loadInitial` 显式
  /// 补报（内容不足一屏时 `jumpTo` 不一定触发监听）。是否真的够格上报（前台 /
  /// 本页最上层 / 仍贴底）交给 `_scheduleReadReport` 判定。
  void _onScrollForRead() {
    if (!_scrollController.hasClients) return;
    final atBottom = _scrollController.position.extentAfter <= 48;
    if (atBottom == _lastScrollAtBottom) return; // 状态没变，不重复触发
    _lastScrollAtBottom = atBottom;
    if (atBottom) _scheduleReadReport(); // 上滑离开底部时不报，回到底部才报
  }

  /// 滚动到接近顶部时加载更早的历史（分页）。
  void _maybeLoadOlder() {
    if (!_hasMoreOlder || _loadingOlder) return;
    if (_scrollController.position.extentBefore < 200) {
      _loadOlder();
    }
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder || !_hasMoreOlder) return;
    _loadingOlder = true;
    try {
      final first = _messages.isEmpty ? null : _messages.first.env.serverSequence;
      if (first == null) {
        // 没有已同步消息（或全是未同步）→ 没有更早历史
        if (mounted) setState(() => _hasMoreOlder = false);
        return;
      }
      final older = await _repo.historyBefore(beforeSequence: first, limit: _pageSize);
      if (!mounted) return;
      setState(() {
        _messages = [...older, ..._messages];
        if (older.length < _pageSize) _hasMoreOlder = false;
      });
    } catch (_) {
      // 加载失败：下次滚动再试
    } finally {
      _loadingOlder = false;
    }
  }

  /// 滚动到底部：让最新消息显示在最下方（老板要求"总是"）。
  /// [animate] 为 false 时直接跳转（首次载入用——进入聊天页应立即看到最新，
  /// 不播从顶部一路飞过的动画）；新消息到达用默认平滑滚动。
  /// post-frame 里执行（ListView 重建后 maxScrollExtent 才有效）。
  void _scrollToLatest({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      if (animate) {
        _scrollController
            .animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
            )
            .then((_) => _jumpToBottom()); // 动画落点可能偏短（懒加载估算）：校正贴底
      } else {
        _jumpToBottom();
      }
    });
  }

  /// 直接跳到列表底部。懒构建列表首帧的 maxScrollExtent 是**估算值**——末尾是
  /// 引用消息（气泡更高）时真实 extent 更大、估算偏低，一次 jumpTo 会停在半路
  /// （老板实测 2026-09-09：发了几条引用后重启不能自动跳到底）。跳转会触发
  /// 目标附近条目补建、extent 变准，逐帧校正直到贴底（depth 上限防极端死循环）。
  void _jumpToBottom([int depth = 0]) {
    if (!mounted || !_scrollController.hasClients || depth > 5) return;
    final target = _scrollController.position.maxScrollExtent;
    _scrollController.jumpTo(target);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      if (_scrollController.position.maxScrollExtent > target + 1) {
        _jumpToBottom(depth + 1);
      }
    });
  }

  /// 点击引用卡跳转到原消息位置（老板要求 2026-09-10）。
  ///
  /// 原消息可能在已加载列表外（UI 分页懒加载只渲染最近一页）——先按 messageId
  /// 查 serverSequence，往前分页加载直到覆盖目标，再定位。定位用「估算 jumpTo
  /// 触发目标附近构建 → 目标项 GlobalKey ensureVisible 精确校正」两步（懒构建
  /// 下远处 item 无元素，直接 ensureVisible 会找不到）。
  Future<void> _jumpToMessage(String messageId) async {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    // 引用快照缺 messageId（异常数据）：也按"原消息不存在"给反馈——点引用卡
    // 必须有回响，不能静默无操作（老板 2026-10-14）。
    if (messageId.isEmpty) {
      _notice(context, l10n.chatPageQuoteGoneNotice);
      return;
    }
    var index = _messages.indexWhere((m) => m.env.messageId == messageId);
    if (index < 0) {
      // 目标未加载：往前分页补载直到覆盖目标（或历史已到顶）
      final targetSeq = await _repo.sequenceOfMessage(messageId);
      // 原消息不存在（非本空间/本机已清屏）：通知用户，不再静默返回
      // （老板 2026-10-14）。墓碑消息保持显示的最初动因就是"跳转要有东西
      // 可落"；真落不了时，至少把结果说清楚。
      if (targetSeq == null) {
        if (!mounted) return;
        _notice(context, l10n.chatPageQuoteGoneNotice);
        return;
      }
      while (index < 0 && mounted) {
        final first = _messages.isEmpty ? null : _messages.first.env.serverSequence;
        if (first == null || first <= targetSeq) break;
        final older = await _repo.historyBefore(beforeSequence: first, limit: _pageSize);
        if (older.isEmpty) break;
        if (!mounted) return;
        setState(() {
          _messages = [...older, ..._messages];
          _hasMoreOlder = older.length >= _pageSize;
        });
        index = _messages.indexWhere((m) => m.env.messageId == messageId);
      }
      // 分页到顶仍未覆盖目标（极端：seq 在、行不在）——同样给反馈
      if (index < 0) {
        if (!mounted) return;
        _notice(context, l10n.chatPageQuoteGoneNotice);
        return;
      }
    }
    if (!mounted) return;
    setState(() => _jumpTargetId = messageId);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      // 先立即置高亮背景：目标已构建（视口/预构建区）即刻生效；目标很远时由
      // 后续 jumpTo 触发的构建按 _highlightMessageId 应用。不能放进嵌套
      // post-frame——目标已在视口时 jumpTo 是 no-op 不调度新帧，嵌套回调
      // 永不执行（2026-09-10 测试暴露的真机同类 bug）。
      // 节奏（老板要求 2026-09-10）：渐变 1.5s 完成后立即触发清除（停留 0s），
      // 随后 AnimatedContainer 再渐变 1.5s 回原色（总时长 3s）。
      _highlightTimer?.cancel();
      setState(() => _highlightMessageId = messageId);
      _highlightTimer = Timer(const Duration(milliseconds: 1500), () {
        if (mounted) setState(() => _highlightMessageId = null);
      });
      // 定位：按平均高度估算跳转（触发目标附近条目构建）
      final estimated = (index * 120.0)
          .clamp(0.0, _scrollController.position.maxScrollExtent);
      _scrollController.jumpTo(estimated);
      // 目标项已构建 → GlobalKey 精确校正（居中显示；目标已在视口时 jumpTo
      // no-op、无新帧，此回调不执行，但目标本就可见无需校正）
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final ctx = _jumpTargetKey.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(ctx,
              duration: const Duration(milliseconds: 300), alignment: 0.5);
        }
      });
    });
  }

  /// 增量刷新：**先本地秒上屏**（_refreshLocal）→ 再网络 sync → 再本地刷新一次。
  /// 这样收到的消息/自己的回执能立即出现，网络慢也不阻塞已到内容（老板 2026-09-12）。
  Future<void> _refresh({bool realtime = false}) async {
    if (_wiped) return; // 已撤销自毁：不再发起任何网络请求（页面正在被替换）
    await _refreshLocal(realtime: realtime);
    try {
      await _repo.sync();
      await _repo.refreshEntranceMap();
      await _persistPeerMemberId();
      // 同步时顺带拉了对方回执（repo.sync 内）→ 载入渲染缓存
      await _loadPeerReceipts();
      await _refreshLocal(realtime: realtime);
      // 自愈：sync 竞态漏掉的附件元数据（2026-10-09）——补拉后触发刷新
      unawaited(_healAttachments());
      _onSyncSucceeded();
    } catch (_) {
      // 网络抖动忽略，下次轮询重试（并按连续失败次数退避）
      _onSyncFailed();
    }
  }

  /// 同步成功：复位退避（周期回到基准），并清掉"服务器不认本通道"的常驻提示
  /// （后台库被复原后应自动恢复正常，无需用户干预）。
  void _onSyncSucceeded() {
    final wasUnrecognized = _entranceUnrecognized;
    final hadFailures = _consecutiveSyncFailures > 0;
    _entranceUnrecognized = false;
    _consecutiveSyncFailures = 0;
    _ensureTickerInterval();
    // 提示条由 `_consecutiveSyncFailures` / `_entranceUnrecognized` 驱动：任一复位都必须
    // 重建，否则条会残留在屏上。此前只有失败路径 setState，"自动恢复"其实靠
    // `_refreshLocal` 顺带重建才凑巧生效——那一路径一旦不重建（异常被吞等）就永久卡住。
    if ((wasUnrecognized || hadFailures) && mounted) setState(() {});
  }

  /// 同步失败：累加退避计数并重设 ticker 周期。
  void _onSyncFailed() {
    if (_consecutiveSyncFailures < 10) _consecutiveSyncFailures++;
    _ensureTickerInterval();
    if (mounted) setState(() {}); // 让离线提示及时出现
  }

  /// 基准轮询周期：WS 在线 30s（推送兜底），离线 3s（尽快恢复）。
  Duration get _baseTickerInterval =>
      (_ws?.connected.value ?? false)
          ? const Duration(seconds: 30)
          : const Duration(seconds: 3);

  /// 实际轮询周期 = 基准 × 2^(连续失败次数)，上限 60s。
  /// 目的：离线期间把"每 3s 一轮、每轮最多 30s"的请求风暴收敛为"每分钟一次"。
  ///
  /// **WS 在线 + 同步失败例外**（老板 2026-10-12：绿灯与"离线"条同框 60s+）：
  /// WS 还连着 = 网络与服务端已被证明可达，失败几乎总是会话续期一类的应用层
  /// 问题，下一轮往往就成功——不该套用"服务端宕机"的指数退避。固定 5s 快速
  /// 重试：窗口期从 60s+ 缩到 ≤5s，又比 3s 略松，给续期往返留余量。
  Duration get _tickerInterval {
    if (_consecutiveSyncFailures > 0 && _ws?.connected.value == true) {
      return const Duration(seconds: 5);
    }
    if (_consecutiveSyncFailures == 0) return _baseTickerInterval;
    final growth = 1 << _consecutiveSyncFailures.clamp(0, 5);
    final seconds = _baseTickerInterval.inSeconds * growth;
    return Duration(seconds: seconds.clamp(3, 60));
  }

  /// 按当前退避算出应有的周期，变了才重设 ticker。
  void _ensureTickerInterval() {
    if (!mounted) return;
    final want = _tickerInterval;
    if (_currentTickerInterval == want) return;
    _restartTicker(want);
  }

  /// 轮询触发：**上一轮没跑完就跳过本次**（离线时单轮可能耗 30s，若不跳过会
  /// 并发堆积大量请求，耗电/耗流量/刷日志——老板 2026-09-13 提出）。
  ///
  /// 卡死兜底：单轮刷新若因网络层极端情况永不返回（重入标记再也不会被清），会让
  /// 轮询**永久停摆**——表现就是"离线提示不自动恢复、重启 App 才好"（老板
  /// 2026-10-09）。故记录开始时刻，超过阈值仍未结束就放行新一轮：宁可偶发一次
  /// 并发，也不要把轮询彻底掐死。
  void _onTick() {
    if (_tickerRefreshInFlight) {
      final started = _tickerRefreshStartedAt;
      if (started != null &&
          DateTime.now().difference(started) < const Duration(minutes: 2)) {
        return;
      }
    }
    _tickerRefreshInFlight = true;
    _tickerRefreshStartedAt = DateTime.now();
    _refresh().whenComplete(() {
      _tickerRefreshInFlight = false;
      _tickerRefreshStartedAt = null;
      _ensureTickerInterval();
    });
  }

  /// 刷新"还没确认"的消息数（离线提示用；COUNT 查询，开销可忽略）。
  Future<void> _loadUnsentCount() async {
    try {
      final n = await _repo.pendingCount;
      if (mounted && n != _unsentCount) setState(() => _unsentCount = n);
    } catch (_) {
      // 忽略：下次刷新再取
    }
  }

  /// 载入对方回执到渲染缓存（内容未变则不 setState，避免每次轮询都重建列表）。
  Future<void> _loadPeerReceipts() async {
    try {
      final rows = await _repo.peerReceipts();
      if (!mounted) return;
      final changed = rows.length != _peerReceipts.length ||
          Iterable.generate(rows.length).any((i) =>
              rows[i].memberId != _peerReceipts[i].memberId ||
              rows[i].deliveredUptoSeq != _peerReceipts[i].deliveredUptoSeq ||
              rows[i].readUptoSeq != _peerReceipts[i].readUptoSeq);
      if (changed) setState(() => _peerReceipts = rows);
    } catch (_) {
      // 读取失败忽略：下次刷新再载
    }
  }

  /// 取走当前引用目标并生成引用快照（同时收起输入栏引用条）。
  /// 文字/语音/图片/视频/音频/文件**所有发送路径共用**（老板要求 2026-09-13）：
  /// 只要引用条挂着，不论下一条新消息是什么类型，都一起提交并在气泡里呈现引用。
  Map<String, dynamic>? _takeQuoteSnapshot() {
    final quote = _quoteTarget;
    if (quote == null) return null;
    setState(() => _quoteTarget = null);
    return {
      'messageId': quote.env.messageId,
      'preview': _quotePreview(quote.plaintext),
      // 原消息类型：引用块据此把图片渲染成缩略图（老板要求 2026-09-13）
      'type': quote.env.type,
      // 语音/音频时长：引用块据此画波形 + 秒数（原消息未加载也能显示）
      if (quote.env.type == 'voice' || quote.env.type == 'audio')
        'seconds': _audioDurationSeconds(quote),
      // 文件大小：引用块据此显示尺寸（老板 2026-09-27——与时长同理，原消息未加载
      // 也能显示）。老快照没这个字段 → 尺寸那行不显示，产品未上线不必兼容。
      if (quote.env.type == 'file')
        'size': (quote.attachment?['size'] as int?) ?? 0,
    };
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final quote = _takeQuoteSnapshot();
    _input.clear();
    try {
      await _repo.send(
        text,
        quote: quote,
        // 本地落库即回显 pending 气泡（乐观 UI），不等上传/sync 往返
        onPersisted: (_) => _refreshLocal(),
      );
      // 上传已尝试完成：刷新状态（pending→sent/failed）
      await _refreshLocal();
    } on ApiException catch (e) {
      // 后台：服务端明确拒绝（4xx）——气泡已标 failed，这里把服务端给的理由说出来
      if (!mounted) return;
      _notice(
          context,
          backendError(AppLocalizations.of(context)!,
              AppLocalizations.of(context)!.chatPageSendFailed(e.message)));
    } catch (e) {
      if (!mounted) return;
      _notice(context, AppLocalizations.of(context)!.chatPageSendFailed('$e'));
    }
  }

  // ---------- 表情面板：输入栏内联展开，与键盘互斥 ----------

  /// 展开表情面板：先收键盘（二者互斥，否则面板被顶在键盘上方）。
  void _openEmojiPanel() {
    // 录音中/预览态（有未发送录音）不打断——面板只服务文字输入
    if (_inputMode == _InputMode.recording || _inputMode == _InputMode.preview) return;
    if (_inputMode == _InputMode.hint) setState(() => _inputMode = _InputMode.text);
    _inputFocusNode.unfocus();
    setState(() => _emojiPanelOpen = true);
  }

  /// 收起面板回到键盘（面板上的键盘键；点输入框走 _onInputFocusChanged 等价路径）。
  void _closeEmojiPanel() {
    if (!_emojiPanelOpen) return;
    setState(() => _emojiPanelOpen = false);
    _inputFocusNode.requestFocus();
  }

  /// 输入框重新获焦（键盘弹出）→ 自动收起面板。
  void _onInputFocusChanged() {
    if (_inputFocusNode.hasFocus && _emojiPanelOpen) {
      setState(() => _emojiPanelOpen = false);
    }
  }

  /// 在光标处插入文字（表情面板选中的 emoji）：面板展开时键盘收起、看不到光标，
  /// 仍按当前 selection 位置插入，插完光标后移一位，可连续点选。
  void _insertText(String insert) {
    final old = _input.text;
    final selection = _input.selection;
    // 从未聚焦过时 selection 无效（offset=-1）：插到末尾
    final start = selection.isValid ? selection.start.clamp(0, old.length) : old.length;
    final end = selection.isValid ? selection.end.clamp(0, old.length) : old.length;
    _setInputValue(old.replaceRange(start, end, insert), start + insert.length);
  }

  /// 退格：删光标前一个字符（emoji 多为 UTF-16 代理对，要整对删）；有选区时删选区。
  void _deleteBackward() {
    final old = _input.text;
    if (old.isEmpty) return;
    final selection = _input.selection;
    final end = selection.isValid ? selection.end.clamp(0, old.length) : old.length;
    if (end == 0) return;
    final start = (selection.isValid && !selection.isCollapsed)
        ? selection.start.clamp(0, old.length)
        : _charStartBefore(old, end);
    _setInputValue(old.replaceRange(start, end, ''), start);
  }

  void _setInputValue(String text, int caretOffset) {
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: caretOffset),
    );
  }

  /// 下标 end 前一个字符的起始位置：代理对（emoji）占 2 个 code unit。
  int _charStartBefore(String text, int end) {
    if (end >= 2) {
      final high = text.codeUnitAt(end - 2);
      final low = text.codeUnitAt(end - 1);
      if (high >= 0xD800 && high <= 0xDBFF && low >= 0xDC00 && low <= 0xDFFF) return end - 2;
    }
    return end - 1;
  }

  /// 发送附件（语音/图片/视频/文件）：本地落库即回显，再刷新状态。
  Future<void> _sendAttachmentOptimistic({
    required Uint8List fileBytes,
    required String fileName,
    required String type,
    String? caption,
    Map<String, dynamic>? meta, // 附加数据（如音频时长），进密文载荷
  }) async {
    // 引用快照在此统一取走：语音/图片/视频/音频/文件全都带上（老板要求 2026-09-13），
    // 发完引用条即收起（此前只有文字发送会带，其他类型把引用条留在了输入框上方）
    final quote = _takeQuoteSnapshot();
    await _repo.sendAttachment(
      fileBytes: fileBytes,
      fileName: fileName,
      type: type,
      caption: caption,
      quote: quote,
      meta: meta,
      onPersisted: (_) => _refreshLocal(),
    );
    await _refreshLocal();
  }

  // ---------- 长按消息操作：引用 / 删除（2 人世界不做转发） ----------

  /// 长按消息弹出操作菜单：引用 / 删除。
  /// 长按菜单是否有内容可给（决定气泡长按与「...」是否响应）：
  /// - 未墓碑：常规菜单（引用/拷贝/保存/撤回/焚毁/删除）总有项；
  /// - **墓碑一律不给**（老板 2026-10-12：曾试过"仅单勾+本机删除/焚毁"的细
  ///   筛，但群空间里"一部分成员已收到"时撤回必然失败，单勾粗筛在群语义下
  ///   已不可靠——复杂度失控，干脆墓碑不提供任何菜单入口）。
  bool _messageHasActions(HistoryMessage m) => !m.deleted;

  /// 「撤回」可见条件（**仅未墓碑消息**——墓碑已不给菜单，见
  /// [_messageHasActions]）：自己消息 + 以下其一——
  /// - 已有 serverSequence：服务端已收下、且**纯粹单勾**——还没有任何人收到
  ///   （k=0；老板 2026-10-12：群空间里只要有人收到，撤回就会失败——内容已被
  ///   拿走；duo 同理 = 对方已拉取。本地粗筛，权威判定在服务端 409）；
  /// - **还没有 serverSequence**（2026-10-19 老板：pending/failed——离线没到
  ///   服务端——也该能撤）：没人可能拉到，撤回 = 取消发送；服务端路径与
  ///   404/409 权威判定照走，见 [MessageRepository.recallMessage]。
  bool _messageRecallable(HistoryMessage m) {
    if (m.sender != 'me' || m.status == 'failed' && m.env.serverSequence != null) {
      // failed 且已在服务端：4xx 明确拒绝（如通道被撤销），重试也无用，不提供
      return false;
    }
    if (m.env.serverSequence == null) {
      // 未到服务端（pending 在途 / failed 未收下）：撤回 = 取消发送
      return m.status == 'pending' || m.status == 'failed';
    }
    return MessageRepository.deliveredCountOf(
            m.env.serverSequence, _peerReceipts) ==
        0;
  }

  Future<void> _showMessageActions(HistoryMessage m) async {
    final l10n = AppLocalizations.of(context)!;
    final action = await showModalBottomSheet<String>(
      context: context,
      // 允许用满窗高（与「我的通道」等弹层同口径，老板 2026-10-02）
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 顶部：发言人头像 + 该消息正文（按性别气泡风格，单行截断不溢出；
            // 老板要求 2026-09-10）；底色与被引消息的引用块同款浅灰，代替原来
            // 的分隔横线（老板要求 2026-09-13）。
            // 墓碑消息不展示内容（已删/已焚毁）：改一条灰字占位（老板 2026-10-10
            // 起墓碑也可开菜单——只剩撤回一项）
            m.deleted ? _tombstoneMenuPlaceholder() : _buildMessagePreviewRow(m),
            // 操作项改为圆角方形卡片（图标 + 文字），不再是列表式 ListTile
            // （老板要求 2026-09-13）
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: _buildActionCardGrid([
                // 墓碑消息：只留「撤回」（内容已隐藏，引用/拷贝/保存/焚毁/删除
                // 均无意义；删除本来也是打本地墓碑，已做了）
                if (m.deleted) ...[
                  _buildActionCard(
                    icon: Icons.undo_outlined,
                    label: l10n.chatPageActionRecall,
                    onTap: () => Navigator.of(ctx).pop('recall'),
                  ),
                ] else ...[
                  _buildActionCard(
                    icon: Icons.format_quote,
                    label: l10n.chatPageActionQuote,
                    onTap: () => Navigator.of(ctx).pop('quote'),
                  ),
                  // 文字消息才有「拷贝」（媒体消息无文本可拷）
                  if (m.env.type == 'text')
                    _buildActionCard(
                      // 拷贝字形竖向占 20/24，同 26 号下比 save_alt/format_quote
                      // 高一档（2026-10-08 老板反馈：拷贝卡片偏高）——缩到 24
                      // 与邻居光学对齐
                      icon: Icons.copy_outlined,
                      iconSize: 24,
                      label: l10n.chatPageCopy,
                      onTap: () => Navigator.of(ctx).pop('copy'),
                    ),
                  // 媒体消息才有「保存」（老板 2026-10-02）：图片/视频/音频/文件
                  // 存到本机（系统保存对话框选位置）；放「引用」后面
                  if (m.attachment != null)
                    _buildActionCard(
                      icon: Icons.save_alt,
                      label: l10n.chatPageActionSave,
                      onTap: () => Navigator.of(ctx).pop('save'),
                    ),
                  // 单条消息阅后即焚：可新设/调整档位、选「无限」取消（老板要求 2026-09-10）
                  _buildActionCard(
                    icon: Icons.timer_outlined,
                    label: l10n.chatPageActionBurn,
                    onTap: () => Navigator.of(ctx).pop('burn'),
                  ),
                  // 撤回（2026-10-10）：仅「已发出且对方尚未拉取」的自己消息——
                  // 服务端按 delivered 高水位原子判定，客户端只做**粗筛**减少
                  // 无效入口（最终判定的权威在服务端 409）。放「删除」之后：
                  // 撤回实质上比删除更重（删自己的还让别人收不到；2026-10-11）。
                  // 两者都不标红（2026-10-11 老板：有确认弹窗把关，不必特殊显示）
                  _buildActionCard(
                    icon: Icons.delete_outline,
                    label: l10n.chatPageActionDelete,
                    onTap: () => Navigator.of(ctx).pop('delete'),
                  ),
                  if (_messageRecallable(m))
                    _buildActionCard(
                      icon: Icons.undo_outlined,
                      label: l10n.chatPageActionRecall,
                      onTap: () => Navigator.of(ctx).pop('recall'),
                    ),
                ]
              ]),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'delete') {
      await _deleteMessage(m);
    } else if (action == 'recall') {
      await _recallMessage(m);
    } else if (action == 'quote') {
      setState(() => _quoteTarget = m);
      _inputFocusNode.requestFocus();
    } else if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: m.plaintext.trim()));
      if (mounted) _notice(context, l10n.setupCreateCopied);
    } else if (action == 'save') {
      await _saveAttachment(m);
    } else if (action == 'burn') {
      await _setMessageBurn(m);
    }
  }

  /// 底部菜单操作项布局：圆角方形卡片，一行最多 4 个。总数不超过 4 个时等距
  /// 均匀铺开；超过 4 个时每行 4 个、向左对齐（老板要求 2026-09-13）。卡片宽度
  /// 以「一行 4 个」为基准计算并设上限，保证尺寸不随数量或屏幕宽度剧烈变化。
  /// 长按消息菜单与输入栏「+」附件菜单共用。
  Widget _buildActionCardGrid(List<Widget> cards) {
    const maxPerRow = 4;
    const spacing = 12.0;
    const maxCardWidth = 96.0;
    // 网格容器的自然宽度=一行四卡。弹层比这宽时（如 macOS 满窗宽的底部
    // 弹层，2026-10-11）卡片被 96 上限卡住、行尾一大片空白——整体限宽居中，
    // 尾行也居中，与手机上填满一行的观感一致。
    const gridMaxWidth = maxCardWidth * maxPerRow + spacing * (maxPerRow - 1);
    // ⚠️ Center 必须带 heightFactor:1——Align 系默认**撑满约束**，弹层是
    // isScrollControlled:true（maxHeight=全屏），不带会把整个弹层顶到顶天
    // 立地（413535d9 引入的回归，老板 2026-10-11 实测）。heightFactor:1 =
    // 高度包住内容、只做横向居中。
    Widget constrain(Widget child) => Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: gridMaxWidth),
            child: child,
          ),
        );
    return LayoutBuilder(
      builder: (context, constraints) {
        final fourColumnWidth =
            (constraints.maxWidth - spacing * (maxPerRow - 1)) / maxPerRow;
        final cardWidth =
            fourColumnWidth < maxCardWidth ? fourColumnWidth : maxCardWidth;
        final items = [
          for (final card in cards) SizedBox(width: cardWidth, child: card),
        ];
        if (cards.length <= maxPerRow) {
          // 不超过 4 个：等距分布、卡片等高分栏
          return constrain(IntrinsicHeight(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: items,
            ),
          ));
        }
        // 超过 4 个：每行 4 个一组、向左对齐摆放（末行也从第一列排起，
        // 老板 2026-10-11；整块网格仍限宽居中）
        final rows = <Widget>[];
        for (var i = 0; i < items.length; i += maxPerRow) {
          final chunk = items.sublist(
            i,
            i + maxPerRow > items.length ? items.length : i + maxPerRow,
          );
          rows.add(IntrinsicHeight(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var j = 0; j < chunk.length; j++) ...[
                  if (j > 0) const SizedBox(width: spacing),
                  chunk[j],
                ],
              ],
            ),
          ));
        }
        return constrain(Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) const SizedBox(height: spacing),
              rows[i],
            ],
          ],
        ));
      },
    );
  }

  /// 底部菜单的操作卡片：圆角方形，内含图标与文字；destructive 用红色标示
  /// 删除等不可逆操作。长按消息菜单与输入栏「+」附件菜单共用。
  /// [iconSize] 供字形偏高的图标（如 copy_outlined 竖向占 20/24）单独缩小，
  /// 与邻居图标光学对齐（2026-10-08）；缺省 26 与原尺寸一致。
  Widget _buildActionCard({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool destructive = false,
    double iconSize = 26,
  }) {
    final foreground = destructive ? Colors.red.shade400 : null;
    return Material(
      color: Colors.black.withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(mouseCursor: SystemMouseCursors.click,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: iconSize, color: foreground),
              const SizedBox(height: 8),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: foreground),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 长按菜单顶部的消息预览行：发言人头像 + 按性别气泡风格的正文。
  /// 正文单行截断不溢出（老板要求 2026-09-10）；头像左右位置与消息流一致
  /// （我的在右、对方在左）；附件消息无正文时显示消息类型作占位。语音/音频文件
  /// 消息直接复用消息流的音频条（播放键 + 波形 + 时长，可点按播放/停止，
  /// 老板要求 2026-09-13）。
  /// Row 撑满整行并按消息流对齐（对方靠左、我的靠右）——此前 mainAxisSize.min
  /// 短消息整行收缩被弹窗居中，长消息撑满贴边，视觉效果不稳定（老板要求
  /// 2026-09-10 修复）。
  /// 长按菜单顶部占位行（墓碑消息专用，2026-10-10）：消息已删/已焚毁，
  /// 不展示内容，只留一条淡灰说明——菜单里只剩「撤回」一项
  Widget _tombstoneMenuPlaceholder() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        AppLocalizations.of(context)!.chatPageQuotedTombMessage,
        style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildMessagePreviewRow(HistoryMessage m) {
    final mine = m.sender == 'me';
    final avatarMemberId =
        m.env.senderMemberId ?? _repo.memberIdOfEntrance(m.env.senderEntranceId);
    final preview = m.plaintext.trim();
    // 音频类（语音/音频文件）与消息流一致：播放键 + 波形图 + 时长（+ 音频文件的
    // 文件名一行），可点按播放（老板要求 2026-09-13）；文件消息**复用消息流那张
    // 文件名片**（图标 + 文件名 + 尺寸，老板 2026-09-27），整块可点打开。
    // 其余类型沿用单行文本（空正文显示类型占位）。
    final Widget bubbleContent;
    switch (m.env.type) {
      case 'voice':
      case 'audio':
        bubbleContent =
            _buildAudioBar(m, waveformWidth: 88, foreground: _mediaForegroundOnBubble);
        break;
      case 'image':
        bubbleContent = _buildImageThumb(m, size: 48);
        break;
      case 'video':
        bubbleContent = _buildVideoThumb(m, size: 48);
        break;
      case 'system':
        // 通话记录：明文为空，内容在 meta 里——复用消息流那条的渲染
        bubbleContent = _buildSystemHint(m);
        break;
      case 'file':
        // 与音频条同一套：直接用消息流那张**文件名片**（图标 + 文件名 + 尺寸），
        // 整块可点 = 用系统应用打开（老板 2026-09-27）。不再自己拼一个"图标 + 文件名"
        // 的只读行——那样既跟气泡长得不一样，点了也没反应。
        bubbleContent = _buildFileCard(m, foreground: _mediaForegroundOnBubble);
        break;
      default:
        bubbleContent = Text(
          preview.isEmpty ? m.env.type : preview,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          // 预览条背景色已清空（老板 2026-09-15 试用效果：去掉浅灰底，只留气泡本身）。
          // 弹窗始终跟随浅色主题，不随 gradient 气泡风格变白。
          color: Colors.transparent,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            key: const ValueKey('messagePreviewRow'), // 测试断言对齐用（项目惯例）
            mainAxisSize: MainAxisSize.max,
            mainAxisAlignment:
                mine ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: [
              if (!mine) ...[
                _MessageAvatar(
                    memberId: avatarMemberId,
                    server: effectiveServer,
                    api: widget.api,
                    onSaveImage: (bytes) =>
                        _saveAvatarImage(_senderNameOf(avatarMemberId), bytes)),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    // 与消息流一致：按发言人性别配色（男天蓝 / 女品牌粉）
                    color: _bubbleColor(mine: mine),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: DefaultTextStyle.merge(
                    style: TextStyle(
                      color: _uiStyle == 'gradient' ? Colors.white : null,
                      fontSize: 14,
                    ),
                    child: bubbleContent,
                  ),
                ),
              ),
              if (mine) ...[
                const SizedBox(width: 8),
                _MessageAvatar(
                    memberId: avatarMemberId, server: effectiveServer, api: widget.api),
              ],
            ],
          ),
        ),
        // 预览条底部的淡灰分隔线（老板 2026-09-15：底色清空后用线与菜单项分层）
        const Divider(height: 1, thickness: 0.5, color: Color(0x14000000)),
      ],
    );
  }

  /// 记录副本：标记为已删除/已焚毁（墓碑，内容隐藏、时间+焚毁记录保留）。
  /// [kind] 传墓碑来路（'delete'=本机删除、'recall'=撤回、缺省=焚毁到期）。
  HistoryMessage _asDeleted(HistoryMessage m, {String? kind}) => (
        env: m.env,
        plaintext: m.plaintext,
        sender: m.sender,
        attachment: m.attachment,
        expiresAt: m.expiresAt,
        createdAt: m.createdAt,
        burnAfterSeconds: m.burnAfterSeconds,
        quote: m.quote,
        deleted: true,
        deletedKind: kind,
        burnManual: m.burnManual,
        status: m.status,
        meta: m.meta,
      );

  /// 删除消息：确认弹窗 → 本机打墓碑标记（内容隐藏、时间+焚毁记录保留；
  /// 对方通道不受影响；重启后记录仍在、内容仍隐藏）。
  Future<void> _deleteMessage(HistoryMessage m) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      // 破坏性确认：禁误触关闭（点外面/系统返回都不行），必须点按钮（老板 2026-10-15）
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Center(child: Text(l10n.chatPageDeleteConfirmTitle)),
          content: Text(l10n.chatPageDeleteConfirmMessage),
          actions: [
            CancelButton(onPressed: () => Navigator.of(ctx).pop(false), label: l10n.chatPageDeleteCancel),
            // 确认按钮红底白字（2026-10-11 老板：与撤回确认弹窗一致；弹窗按钮
            // 用实体样式，不再是纯文字）
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.red.shade400,
                foregroundColor: Colors.white,
              ),
              child: Text(l10n.chatPageDeleteConfirmOk),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    await _repo.tombstoneMessage(m.env.messageId);
    await MediaCache.deleteFor(widget.spaceId, m.env.messageId); // 定点删媒体解密缓存
    unawaited(AttachmentStore.deleteFor(widget.spaceId, m.env.messageId)); // 留存明文同样删
    if (!mounted) return;
    setState(() {
      _messages = [
        for (final x in _messages)
          if (x.env.messageId == m.env.messageId) _asDeleted(x, kind: 'delete') else x,
      ];
    });
  }

  /// 撤回一条「已发出、对方尚未拉取」的自己消息（2026-10-10）：
  /// 服务端原子校验 delivered 水位后真删（对方永远拉不到），本机走本地墓碑。
  /// 409（对方已拉取）→ 提示不可撤；其余错误静默提示失败（不墓碑）。
  Future<void> _recallMessage(HistoryMessage m) async {
    final l10n = AppLocalizations.of(context)!;
    // 确认弹窗（2026-10-11）：撤回不可恢复且对方永远收不到，比删除更重，
    // 不做二次确认容易误触
    final ok = await showDialog<bool>(
      context: context,
      // 破坏性确认：禁误触关闭（点外面/系统返回都不行），必须点按钮（老板 2026-10-15）
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Center(child: Text(l10n.chatPageRecallConfirmTitle)),
          content: Text(l10n.chatPageRecallConfirmBody),
          actions: [
            CancelButton(onPressed: () => Navigator.of(ctx).pop(false)),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.red.shade400,
                foregroundColor: Colors.white,
              ),
              child: Text(l10n.chatPageRecallConfirmOk),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      await _repo.recallMessage(m.env.messageId);
    } on ApiException catch (e) {
      if (!mounted) return;
      _notice(context,
          e.httpStatus == 409 ? l10n.chatPageRecallBlocked : l10n.chatPageRecallFailed);
      return;
    } catch (_) {
      if (!mounted) return;
      _notice(context, l10n.chatPageRecallFailed);
      return;
    }
    if (!mounted) return;
    await MediaCache.deleteFor(widget.spaceId, m.env.messageId);
    unawaited(AttachmentStore.deleteFor(widget.spaceId, m.env.messageId));
    if (!mounted) return;
    setState(() {
      _messages = [
        for (final x in _messages)
          if (x.env.messageId == m.env.messageId) _asDeleted(x, kind: 'recall') else x,
      ];
    });
  }

  /// 引用预览截断（60 字内）。
  ///
  /// 附件消息明文自带 📎 前缀（发送端的兜底文案），引用条里已有缩略图，别针图标
  /// 重复且多余——去掉（老板要求 2026-09-13）。
  String _quotePreview(String text) {
    var t = text.trim();
    if (t.startsWith('📎')) t = t.replaceFirst('📎', '').trim();
    return t.length > 60 ? '${t.substring(0, 60)}…' : t;
  }

  /// 已加载消息里按 messageId 找原消息（引用块显示缩略图用）；未加载到返回 null
  /// ——此时引用块退回文字预览，点它跳转会把原消息补载进来（补载后自动变缩略图）。
  HistoryMessage? _messageById(String messageId) {
    if (messageId.isEmpty) return null;
    final index = _messages.indexWhere((x) => x.env.messageId == messageId);
    return index < 0 ? null : _messages[index];
  }

  /// 语音/音频引用的**兜底**外观：波形图 + 秒数（不带播放键）。
  ///
  /// 只在**原消息还没加载进内存**时用（引用块手里只有引用快照：messageId + seconds），
  /// 点它会跳到原消息、补载后就换成 [_buildAudioBar] 那条完整音频条。波形与消息流
  /// 同源（seed=messageId，形状一致）、时长未知时不显示秒数（老板要求 2026-09-13：
  /// 录音消息到处一个样）。
  Widget _buildVoiceQuoteRow({
    required String messageId,
    required int seconds,
    required bool isVoice,
    required Color color,
    double waveformWidth = 96,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _VoiceWaveform(
          playing: false,
          durationSeconds: seconds,
          seed: messageId,
          activeColor: color,
          inactiveColor: color.withValues(alpha: 0.4),
          width: waveformWidth,
        ),
        if (seconds > 0) ...[
          const SizedBox(width: 6),
          Text(
            isVoice ? _formatVoiceDuration(seconds) : _formatHmsDuration(seconds),
            style: TextStyle(fontSize: 12, color: color),
          ),
        ],
      ],
    );
  }

  /// 引用块内容：原消息是图片/视频就显示它的缩略图（视频取首帧 + 播放三角，
  /// 老板要求 2026-09-15）；语音/音频**复用消息流那条音频条**、文件**复用消息流那张
  /// 文件名片**（图标 + 文件名 + 尺寸）——老板 2026-09-27：引用块要和原始气泡一个样。
  /// 原消息**尚未加载**时才退回只读的简版（引用快照里只有 messageId / preview /
  /// seconds / size）。其余沿用文字预览。
  Widget _buildQuoteBlockContent(Map<String, dynamic> quote) {
    final type = quote['type'] as String?;
    if (type == 'image') {
      final quoted = _messageById(quote['messageId'] as String? ?? '');
      if (quoted != null) return _buildImageThumb(quoted, size: kQuoteThumbSize);
    }
    if (type == 'video') {
      final quoted = _messageById(quote['messageId'] as String? ?? '');
      if (quoted != null) return _buildVideoThumb(quoted, size: kQuoteThumbSize);
    }
    if (type == 'file') {
      // 原消息已加载 → **复用消息流那张文件名片**（图标 + 文件名 + 尺寸），与菜单
      // 预览条同一个 widget（老板 2026-09-27）。
      // tappable:false —— 引用块的单击是"跳到原消息"，不能被"整块打开"抢掉；
      // 文件**图标**本身仍可点 = 打开（与音频条的播放键对称）。
      final quoted = _messageById(quote['messageId'] as String? ?? '');
      if (quoted != null) {
        return _buildFileCard(
          quoted,
          tappable: false,
          foreground: _uiStyle == 'gradient'
              ? Colors.white70
              : Theme.of(context).colorScheme.primary,
        );
      }
      // 原消息不在已加载范围：只有引用快照（preview 就是文件名，可能还有 size）
      var fileName = _quotePreview(quote['preview'] as String? ?? '');
      if (fileName.startsWith('📎')) fileName = fileName.replaceFirst('📎', '').trim();
      final size = (quote['size'] is num) ? (quote['size'] as num).round() : 0;
      final detailColor =
          _uiStyle == 'gradient' ? Colors.white70 : Colors.grey.shade700;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.insert_drive_file, size: 16, color: detailColor),
          const SizedBox(width: 6),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: detailColor),
                ),
                // 尺寸随引用快照一起走（老快照没有 size 字段 → 不显示这一行）
                if (size > 0)
                  Text(_formatSize(size),
                      style: TextStyle(fontSize: 11, color: detailColor)),
              ],
            ),
          ),
        ],
      );
    }
    if (type == 'voice' || type == 'audio') {
      // 原消息已加载 → **复用消息流那条音频条**（播放键 + 波形 + 时长，音频文件还有
      // 文件名一行），与菜单预览条同一个 widget（老板 2026-09-27）。
      // tappable:false —— 引用块的单击是"跳到原消息"，不能被播放抢掉；播放键
      // 本身仍可点（它只是内层 IconButton）。
      final quoted = _messageById(quote['messageId'] as String? ?? '');
      if (quoted != null) {
        return _buildAudioBar(
          quoted,
          waveformWidth: 88,
          foreground: _uiStyle == 'gradient'
              ? Colors.white70
              : Theme.of(context).colorScheme.primary,
          tappable: false,
        );
      }
      // 原消息不在已加载范围：只有引用快照（messageId + seconds），退回只读的
      // 波形 + 秒数（点它仍然跳过去，跳到后会自动补载成上面那条完整音频条）
      final seconds =
          (quote['seconds'] is num) ? (quote['seconds'] as num).round() : 0;
      return _buildVoiceQuoteRow(
        messageId: quote['messageId'] as String? ?? '',
        seconds: seconds,
        isVoice: type == 'voice',
        color: _uiStyle == 'gradient'
            ? Colors.white70
            : Theme.of(context).colorScheme.primary,
      );
    }
    return Text(
      _quotePreview(quote['preview'] as String? ?? ''),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
          fontSize: 12,
          color: _uiStyle == 'gradient' ? Colors.white70 : Colors.grey.shade700),
    );
  }

  /// 输入栏引用条：被引用消息预览 + 取消按钮。
  ///
  /// 配色**两种界面主题一致**（老板 2026-09-14）：此前 gradient 下用「白 12% 底 +
  /// white70 字/图标」，而 gradient 的输入栏本身就是 85% 白悬浮条——白底上的淡白
  /// 字几乎看不见。改为与素雅纯色同款：黑 6% 半透明底 + 灰字/灰图标（顺带与气泡里
  /// 的引用框保持同一族颜色）；蓝色左边缘也已在 2026-09-13 去掉。
  Widget _buildQuoteBanner(HistoryMessage quote) {
    final isAudio = quote.env.type == 'voice' || quote.env.type == 'audio';
    final isFile = quote.env.type == 'file';
    final isImage = quote.env.type == 'image';
    final isVideo = quote.env.type == 'video';
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        // 与气泡引用框同色（_buildQuoteBlockContent 所在的引用块）
        color: Colors.black.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        // spaceBetween：音频条/文件名片**贴合内容靠左**、取消按钮**贴右边框**，
        // 空余留在两者中间（老板 2026-09-27 指出：macOS 宽窗口下 X 离右边框一大段，
        // 还随文件名长短浮动）。
        // 不能用 `Flexible + Spacer` 来顶：两个都是 flex 子项，剩余空间被**平分**，
        // X 前面永远留着约一半空余；而内容越长、剩余越少 → 空隙跟着文件名浮动。
        // 文字引用那条是 Expanded（tight），本来就撑满整行，不受影响。
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // 引用图片/视频时显示原附件缩略图（否则双引号图标）——与发送后的
          // 引用块一致（视频显示首帧 + 播放三角，老板要求 2026-09-15）。
          // 语音/音频、文件**不加**引号图标：下面那条音频条/文件名片自带图标，
          // 再挂一个引号既重复又把行撑宽（老板 2026-09-27）
          // 图片/视频**只放缩略图**（文件名已按老板要求删掉），尺寸与气泡引用块
          // 一致（[kQuoteThumbSize]）；后面没有别的预览内容，不再留 6px 间距
          if (isImage)
            _buildImageThumb(quote, size: kQuoteThumbSize)
          else if (isVideo)
            _buildVideoThumb(quote, size: kQuoteThumbSize)
          else if (!isAudio && !isFile) ...[
            const Icon(Icons.format_quote, size: 14, color: Colors.grey),
            const SizedBox(width: 6),
          ],
          // 语音/音频/文件：**复用消息流那条音频条 / 那张文件名片**（老板 2026-09-27：
          // 与菜单预览条一个样）。整块可点——音频是播放，文件是用系统应用打开。
          // Flexible 是必须的：Row 的非 flex 子项宽度**无界**，不套一层的话长歌名/
          // 长文件名会撑破整条引用条（框架行为，见 _buildFileCard 里的注释）。
          // 颜色用主题蓝——引用条是 6% 黑的浅底，跟着气泡走白的话在这里看不见。
          if (isAudio) ...[
            Flexible(
              child: _buildAudioBar(
                quote,
                waveformWidth: 88,
                foreground: Theme.of(context).colorScheme.primary,
              ),
            ),
          ] else if (isFile) ...[
            Flexible(
              child: _buildFileCard(
                quote,
                foreground: Theme.of(context).colorScheme.primary,
              ),
            ),
          ] else if (!isImage && !isVideo)
            // 图片/视频**只显示缩略图，不再显示文件名**：发送端写进明文的本来就是
            // 硬编码的 `image.jpg` / `video.mp4`（见 _sendMedia），不是真名——显示
            // 一个假名字还不如不显示（老板 2026-09-27）。
            Expanded(
              child: Text(
                // 双引号图标已足够表达引用，不再加「引用：」前缀（老板要求 2026-09-09）
                _quotePreview(quote.plaintext),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
            ),
          InkWell(mouseCursor: SystemMouseCursors.click,
            onTap: () => setState(() => _quoteTarget = null),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.close, size: 16, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 语音：点击麦克风切提示态 → 长按提示态录音条录音 → 松手预览（试听/取消）→ 发送 ----------

  /// 语音入口按钮点击：文字态=切提示态；提示/预览态=回文字态；录音中无操作。
  void _onVoiceEntryTap() {
    if (_inputMode == _InputMode.text) {
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() => _inputMode = _InputMode.hint);
    } else if (_inputMode == _InputMode.hint) {
      setState(() => _inputMode = _InputMode.text);
    } else if (_inputMode == _InputMode.preview) {
      // 键盘键=放弃录音回文字输入（与发送键一致）；X 键才回录音等待态
      unawaited(_cancelVoice(backToTextInput: true));
    }
    // recording：手势在录音条上，入口按钮不可达，无操作
  }

  /// 语音入口按钮图标：文字态=麦克风；提示/预览态=键盘；录音中=红色麦克风。
  IconData _voiceEntryIcon() {
    switch (_inputMode) {
      case _InputMode.text:
        return Icons.mic_none;
      case _InputMode.hint:
      case _InputMode.preview:
        return Icons.keyboard_alt_outlined;
      case _InputMode.recording:
        return Icons.mic;
    }
  }

  Future<void> _startVoice() async {
    // 预览态（刚录完、波形已冻结）不再开录：此时长按波形图/录音条什么也不做，
    // 避免误触从头重录、冲掉刚录好的那条。只有前面的播放键和后面的 X 可点；
    // 点 X（_cancelVoice）回到等待录音的提示态，就又能长按开录了
    // （老板要求 2026-09-13）。
    if (_inputMode == _InputMode.recording || _inputMode == _InputMode.preview) {
      return;
    }
    // 录音时收起键盘（输入框被录音条覆盖，键盘占屏无意义）
    FocusManager.instance.primaryFocus?.unfocus();
    _voiceStarting = true;
    try {
      // 重新录音（预览态再长按）：先清掉上一次未发送的临时文件
      final old = _recordingPath;
      if (old != null) {
        final of = File(old);
        if (await of.exists()) await of.delete().catchError((_) => of);
        _recordingPath = null;
      }
      // 试听/消息播放与录音互斥
      _previewPlaying = false;
      if (_playingMessageId != null) _playingMessageId = null;
      if (_audioStartedMessageId != null) _audioStartedMessageId = null;
      await _player?.stop();
      final recorder = (_recorder ??= AudioRecorder());
      // 安卓端 start() 不会自动申请 RECORD_AUDIO 运行时权限（manifest 静态声明
      // 不够，Android 6.0+ 需动态授权），必须先 hasPermission() 显式申请，
      // 否则无权限设备上 AudioRecord 初始化失败：要么 start 抛错（无波形），
      // 要么读到全零数据（波形极小、文件 0 字节发不出）。
      if (!await recorder.hasPermission()) {
        _voiceStarting = false;
        if (!mounted) return;
        _notice(context, AppLocalizations.of(context)!.chatPageVoicePermissionDenied);
        return;
      }
      final path = '${Directory.systemTemp.path}/einz_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await recorder.start(const RecordConfig(), path: path);
      // 上面 hasPermission() 等待授权弹窗期间用户可能已松手（_voiceStarting 已被
      // _stopVoice 清掉）：此时录制已开但无人会再去停它，直接停掉并丢弃本次启动
      if (!_voiceStarting) {
        await recorder.stop();
        return;
      }
      _voiceStarting = false;
      // 振幅流：实时驱动录音条波形（record 插件内部无订阅者时不做事）
      _voiceSamples.clear();
      _recordSeconds = 0;
      _ampSub?.cancel();
      _ampSub = _recorder!
          .onAmplitudeChanged(const Duration(milliseconds: 70))
          .listen((amplitude) {
        if (!mounted || _inputMode != _InputMode.recording) return;
        final raw = ((amplitude.current + 50) / 50).clamp(0.06, 1.0);
        setState(() {
          final last = _voiceSamples.isNotEmpty ? _voiceSamples.last : raw;
          _voiceSamples.add((last * 0.4 + raw * 0.6).clamp(0.06, 1.0));
        });
      });
      setState(() {
        _inputMode = _InputMode.recording;
        _recordingPath = path;
      });
      // 60s 上限：到点自动停（进预览态），防误触长时间录音
      _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || _inputMode != _InputMode.recording) return;
        setState(() => _recordSeconds++);
        if (_recordSeconds >= 60) _stopVoice();
      });
    } catch (e) {
      if (!mounted) return;
      _notice(context, AppLocalizations.of(context)!.chatPageVoiceStartFailed('$e'));
    }
  }

  /// 松手 / 60s 到点：停录音 → 文件有效进预览态（不自动发送），空录音直接取消回输入框。
  Future<void> _stopVoice() async {
    if (_inputMode != _InputMode.recording) {
      // 录音尚未真正开始（首次授权弹窗期间已松手）：只标记「本次启动作废」，
      // _startVoice 在 recorder.start() 完成后看到标记会自行停掉并丢弃。
      _voiceStarting = false;
      return;
    }
    final path = _recordingPath;
    _recordTimer?.cancel();
    _recordTimer = null;
    await _ampSub?.cancel();
    _ampSub = null;
    try {
      await _recorder?.stop();
      var ok = false;
      if (path != null) {
        final f = File(path);
        ok = await f.exists() && await f.length() > 0;
      }
      if (!mounted) return;
      // 空录音（权限被系统拒后仍可能走到这里）不再静默回文字态，给明确反馈
      if (!ok) _notice(context, AppLocalizations.of(context)!.chatPageVoiceEmpty);
      setState(() {
        _inputMode = ok ? _InputMode.preview : _InputMode.text;
        if (!ok) _recordingPath = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _inputMode = _InputMode.text;
        _recordingPath = null;
      });
      _notice(context, AppLocalizations.of(context)!.chatPageVoiceFailed('$e'));
    }
  }

  /// 预览态发送（右侧发送键）：加密上传（type=voice）→ 恢复文字输入框。
  Future<void> _sendVoice() async {
    if (_inputMode != _InputMode.preview) return;
    final path = _recordingPath;
    if (path == null) return;
    // 语音说明只留标签（老板 2026-09-11）；时长改走载荷 meta 同步给对端
    // （老板 2026-09-13），明文不再塞时长。须在 await 前取好（避免 async gap 用 context）
    final caption = AppLocalizations.of(context)!.chatPageVoiceLabel;
    try {
      final f = File(path);
      if (!await f.exists() || await f.length() == 0) {
        if (!mounted) return;
        setState(() {
          _inputMode = _InputMode.text;
          _recordingPath = null;
          _voiceSamples.clear();
        });
        return;
      }
      await _sendAttachmentOptimistic(
        fileBytes: await f.readAsBytes(),
        fileName: 'voice.m4a',
        type: 'voice',
        caption: caption,
        meta: {kMetaAudioDurationSeconds: _recordSeconds},
      );
      await f.delete().catchError((_) => f);
      if (!mounted) return;
      setState(() {
        _inputMode = _InputMode.text;
        _recordingPath = null;
        _voiceSamples.clear();
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      _notice(context, backendError(l10n, l10n.chatPageVoiceFailed(e.message)));
    } catch (e) {
      if (!mounted) return;
      _notice(context, AppLocalizations.of(context)!.chatPageVoiceFailed('$e'));
    }
  }

  /// 预览态取消：删临时文件。默认回到**等待录音的提示态**（再长按即可重录，
  /// 老板要求 2026-09-13）；[backToTextInput]=true 时回文字输入框（点键盘键/发送）。
  Future<void> _cancelVoice({bool backToTextInput = false}) async {
    if (_inputMode != _InputMode.preview) return;
    final path = _recordingPath;
    _previewPlaying = false;
    await _player?.stop();
    if (!mounted) return;
    setState(() {
      _inputMode = backToTextInput ? _InputMode.text : _InputMode.hint;
      _recordingPath = null;
      _recordSeconds = 0; // 提示态是干净的起点，不该留着上一次的秒数
      _voiceSamples.clear();
    });
    if (path != null) {
      final f = File(path);
      if (await f.exists()) await f.delete().catchError((_) => f);
    }
  }

  /// 预览态试听：点播放/暂停切换（与消息播放互斥）。
  Future<void> _playVoicePreview() async {
    final path = _recordingPath;
    if (path == null || !await File(path).exists()) return;
    final player = _player ??= AudioPlayer();
    if (_previewPlaying) {
      await player.stop();
      if (mounted) setState(() => _previewPlaying = false);
      return;
    }
    if (_playingMessageId != null && mounted) setState(() => _playingMessageId = null);
    try {
      setState(() => _previewPlaying = true);
      await player.stop();
      await player.play(DeviceFileSource(path));
      // 播完自动复位播放图标
      unawaited(player.onPlayerComplete.first.then((_) {
        if (mounted) setState(() => _previewPlaying = false);
      }));
    } catch (e) {
      if (!mounted) return;
      setState(() => _previewPlaying = false);
      _notice(context, AppLocalizations.of(context)!.chatPageAudioPlayFailed('$e'));
    }
  }

  /// 最近 [n] 个波形采样（录音中滚动窗口，预览态冻结尾部）。
  List<double> _voiceLastSamples(int n) =>
      _voiceSamples.length <= n ? _voiceSamples : _voiceSamples.sublist(_voiceSamples.length - n);

  /// 录音条（覆盖在文字输入框上）：提示态=「长按开始录音」文字（无波形）；
  /// 录音中=实时波形+计时；预览态=冻结波形+试听/取消。
  /// 由外部 Stack 给定与输入框完全一致的行高（移除固定高度，随约束填充）。
  Widget _buildVoiceBar() {
    final recording = _inputMode == _InputMode.recording;
    final preview = _inputMode == _InputMode.preview;
    // 录音上限 60s：左侧直接数秒（00 → 60），不必写成分秒（老板要求 2026-09-13）
    final elapsed = _recordSeconds.toString().padLeft(2, '0');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: recording ? Colors.green.shade50 : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: recording ? Colors.green.shade200 : Colors.grey.shade300),
      ),
      child: recording
          ? Row(
              children: [
                Text(elapsed,
                    style: const TextStyle(
                        color: Colors.green, fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(width: 10),
                Expanded(
                    child: _WaveformBars(
                        samples: _voiceLastSamples(40), color: Colors.green)),
              ],
            )
          : preview
              ? Row(
                  children: [
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      iconSize: 22,
                      icon: Icon(_previewPlaying ? Icons.stop_circle : Icons.play_circle,
                          color: Theme.of(context).colorScheme.primary),
                      onPressed: _playVoicePreview,
                    ),
                    Expanded(
                      child: LayoutBuilder(builder: (context, constraints) {
                        // 试听：波形按进度从左往右高亮（与气泡里的语音波形一致，
                        // 老板要求 2026-09-13）——用本次真实振幅采样，宽度撑满可用区
                        return _VoiceWaveform(
                          playing: _previewPlaying,
                          durationSeconds: _recordSeconds,
                          samples: _voiceSamples,
                          width: constraints.maxWidth,
                          activeColor: Theme.of(context).colorScheme.primary,
                          inactiveColor: Colors.grey.shade400,
                        );
                      }),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      iconSize: 22,
                      icon: const Icon(Icons.close, color: Colors.grey),
                      onPressed: _cancelVoice,
                    ),
                  ],
                )
              : Row(
                  // 提示态：文字说明版录音条（无波形），长按开始录音
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.mic, size: 16, color: Colors.grey.shade600),
                    const SizedBox(width: 6),
                    Text(
                      AppLocalizations.of(context)!.chatPageLongPressToRecord,
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                    ),
                  ],
                ),
    );
  }

  // ---------- 音频播放（语音/音频文件共用）：下载解密 → 临时文件 → audioplayers ----------

  /// 从文件名取扩展名（audio 消息临时文件用，voice 固定 m4a）。
  String _extOf(String name) {
    final dot = name.lastIndexOf('.');
    return (dot >= 0 && dot < name.length - 1) ? name.substring(dot + 1) : 'bin';
  }

  Future<void> _playAudioMessage(
      HistoryMessage m) async {
    final att = m.attachment;
    if (att == null) {
      if (!mounted) return;
      _notice(context, AppLocalizations.of(context)!.chatPageAudioMetaMissing);
      return;
    }
    // 正在播放同一条 → 停止
    if (_playingMessageId == m.env.messageId) {
      await _player?.stop();
      _updateAudioPlayback(() {
        _playingMessageId = null;
        _audioStartedMessageId = null;
      });
      return;
    }
    try {
      final player = _player ??= AudioPlayer();
      _previewPlaying = false; // 与预览态试听互斥
      _updateAudioPlayback(() {
        _playingMessageId = m.env.messageId;
        _audioStartedMessageId = null; // 旧波形进度先复位
      });
      final ext = m.env.type == 'voice' ? 'm4a' : _extOf(m.plaintext);
      // 与图片/视频一致走 [_attachmentBytes]：发送端优先用**本地密文**解密——
      // 上传还在传（没拿到 server_sequence）时文件本来就在本机，点了就该能播
      // （老板 2026-09-15）；此前这里直连 fetchAttachment 走网络 → 落"音频播放失败"
      Future<Uint8List> load() => _attachmentBytes(m);
      // 解密落盘：确定性路径按 messageId 复用——重复播放不再重复下载解密
      // stored 模式放长期目录（跨会话保留），否则临时缓存（系统可清）
      final tmp = (_storeAttachments
              ? await AttachmentStore.ensure(widget.spaceId, m.env.messageId, ext, load)
              : null) ??
          await MediaCache.ensure(widget.spaceId, m.env.messageId, ext, load);
      await player.stop();
      await player.play(DeviceFileSource(tmp.path));
      // 真正出声才开始走波形进度（此前是下载解密等待期）
      _updateAudioPlayback(() => _audioStartedMessageId = m.env.messageId);
      // 音频文件：顺手记下播放器给的真实时长（老消息/探测失败的兜底显示）
      if (m.env.type != 'voice') {
        final total = await player.getDuration();
        final seconds = total?.inSeconds ?? 0;
        if (seconds > 0) {
          _updateAudioPlayback(() => _audioFileDurations[m.env.messageId] = seconds);
        }
      }
      player.onPlayerComplete.first.then((_) {
        _updateAudioPlayback(() {
          _playingMessageId = null;
          _audioStartedMessageId = null;
        });
      }).catchError((_) {});
    } catch (e) {
      if (!mounted) return;
      _updateAudioPlayback(() {
        _playingMessageId = null;
        _audioStartedMessageId = null;
      });
      _notice(context, AppLocalizations.of(context)!.chatPageAudioPlayFailed('$e'));
    }
  }

  /// 音频播放状态变更：setState 刷新本页（消息流气泡）+ 版本号 +1 通知跨路由
  /// 监听者（长按菜单预览行）。已 dispose 则只留字段值，不触发重建。
  void _updateAudioPlayback(void Function() update) {
    update();
    if (!mounted) return;
    setState(() {});
    _audioPlaybackVersion.value++;
  }

  // ---------- 图像/视频/音频/文件：选择 → 加密上传 → 发送 ----------

  Future<void> _showAttachmentSheet() async {
    final l10n = AppLocalizations.of(context)!;
    final kind = await showModalBottomSheet<_AttachmentKind>(
      context: context,
      // 允许用满窗高（与「我的通道」等弹层同口径，老板 2026-10-02）
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: _buildActionCardGrid([
            // 拍照/拍摄仅移动端有（桌面无相机采集，见 [_hasCameraCapture]）
            if (_hasCameraCapture) ...[
              _buildActionCard(
                icon: Icons.photo_camera,
                label: l10n.chatPageAttachPhoto,
                onTap: () => Navigator.of(ctx).pop(_AttachmentKind.photo),
              ),
            ],
            _buildActionCard(
              icon: Icons.photo_library,
              label: l10n.chatPageAttachGalleryImage,
              onTap: () => Navigator.of(ctx).pop(_AttachmentKind.galleryImage),
            ),
            if (_hasCameraCapture) ...[
              _buildActionCard(
                icon: Icons.videocam,
                label: l10n.chatPageAttachVideoCamera,
                onTap: () => Navigator.of(ctx).pop(_AttachmentKind.videoCamera),
              ),
            ],
            _buildActionCard(
              icon: Icons.movie,
              label: l10n.chatPageAttachVideoGallery,
              onTap: () => Navigator.of(ctx).pop(_AttachmentKind.videoGallery),
            ),
            _buildActionCard(
              icon: Icons.music_note,
              label: l10n.chatPageAttachAudioFile,
              onTap: () => Navigator.of(ctx).pop(_AttachmentKind.audioFile),
            ),
            _buildActionCard(
              icon: Icons.insert_drive_file,
              label: l10n.chatPageAttachAnyFile,
              onTap: () => Navigator.of(ctx).pop(_AttachmentKind.anyFile),
            ),
            // 表情符放最后（老板 2026-09-15）：附件优先，表情不是附件
            _buildActionCard(
              icon: Icons.emoji_emotions_outlined,
              label: l10n.chatPageAttachEmoji,
              onTap: () => Navigator.of(ctx).pop(_AttachmentKind.emoji),
            ),
            // 「粘贴」排表情符之后——整个网格的末尾（老板 2026-10-12 指定）。
            // **总显示、不做剪贴板预检**：iOS 上 App 读剪贴板会弹系统"已粘贴"
            // 横幅，每开一次面板弹一次没人受得了；空了就空了，点了由
            // _pasteFromClipboard 提示「剪贴板是空的」兜底（老板拍简：接受这个
            // 代价，换实现简单 + iOS 不被横幅骚扰）。放末尾也不挤常用入口。
            // Web 不摆：浏览器读剪贴板图片要权限弹窗，且 Web 版本就未发布
            if (_clipboardPasteSupported)
              _buildActionCard(
                icon: Icons.content_paste,
                label: l10n.chatPageAttachPaste,
                onTap: () => Navigator.of(ctx).pop(_AttachmentKind.paste),
              ),
          ]),
        ),
      ),
    );
    if (kind == null) return;
    if (kind == _AttachmentKind.emoji) {
      _openEmojiPanel(); // 不发附件：只展开输入栏表情面板
      return;
    }
    await _sendMedia(kind);
  }

  /// 选择器给出的文件名：**相册/文件库里是真名**（`IMG_1234.HEIC`、`假期.mp4`），
  /// 拍照/录像则是选择器自己的临时名（没有"原名"可言，各家插件给的形如
  /// `image_picker_2F3A…jpg`）。取不到（路径为空）才用 [fallback] 占位名。
  ///
  /// 它写进**消息明文**（`📎 <fileName>`，见 `MessageRepository.sendAttachment`），
  /// 于是引用快照、附件落盘的扩展名（`_attachmentExtOf` 按明文后缀取）都跟它走——
  /// 这就是为什么此前硬编码 `image.jpg`/`video.mp4` 会让引用条显示假名（老板
  /// 2026-09-27 发现）。产品未上线，老的假名消息不必迁移。
  String _pickedFileName(XFile file, {required String fallback}) =>
      file.name.isNotEmpty ? file.name : fallback;

  Future<void> _sendMedia(_AttachmentKind kind) async {
    try {
      final XFile? image;
      String? fileName;
      String? type;
      switch (kind) {
        case _AttachmentKind.emoji:
          return; // 已在 _showAttachmentSheet 中分流（展开表情面板），不走上传
        case _AttachmentKind.paste:
          // 粘贴：读剪贴板 → 图/文件走确认弹窗 → 发送；文本插入输入框。
          // 自己的 try/catch 在 _pasteFromClipboard 里（错误提示同口径）
          await _pasteFromClipboard();
          return;
        case _AttachmentKind.photo:
          image = await _picker.pickImage(source: ImageSource.camera, maxWidth: 1600);
          if (image == null) return;
          if (!_withinAttachmentLimit(await image.length())) return;
          fileName = _pickedFileName(image, fallback: 'image.jpg');
          type = 'image';
          await _sendAttachmentOptimistic(fileBytes: await image.readAsBytes(), fileName: fileName, type: type);
        case _AttachmentKind.galleryImage:
          image = await _picker.pickImage(source: ImageSource.gallery, maxWidth: 1600);
          if (image == null) return;
          if (!_withinAttachmentLimit(await image.length())) return;
          fileName = _pickedFileName(image, fallback: 'image.jpg');
          type = 'image';
          await _sendAttachmentOptimistic(fileBytes: await image.readAsBytes(), fileName: fileName, type: type);
        case _AttachmentKind.videoCamera:
          image = await _picker.pickVideo(source: ImageSource.camera, maxDuration: const Duration(minutes: 1));
          if (image == null) return;
          if (!_withinAttachmentLimit(await image.length())) return;
          fileName = _pickedFileName(image, fallback: 'video.mp4');
          type = 'video';
          await _sendAttachmentOptimistic(fileBytes: await image.readAsBytes(), fileName: fileName, type: type);
        case _AttachmentKind.videoGallery:
          image = await _picker.pickVideo(source: ImageSource.gallery, maxDuration: const Duration(minutes: 1));
          if (image == null) return;
          if (!_withinAttachmentLimit(await image.length())) return;
          fileName = _pickedFileName(image, fallback: 'video.mp4');
          type = 'video';
          await _sendAttachmentOptimistic(fileBytes: await image.readAsBytes(), fileName: fileName, type: type);
        case _AttachmentKind.audioFile:
          // file_picker 12.x：静态方法直接调用，返回 List<PlatformFile>；
          // 文件内容用异步 readAsBytes()（withData 已废弃）
          final audioFiles = await FilePicker.pickFiles(type: FileType.audio);
          if (audioFiles.isEmpty) return;
          final audio = audioFiles.first;
          if (!_withinAttachmentLimit(await audio.length())) return;
          final audioName = audio.name;
          final audioBytes = await audio.readAsBytes();
          // 发送前读一遍时长（audioplayers 设源取总时长，不播放），放进载荷
          // meta 随消息同步，对端开箱即显示（老板要求 2026-09-13）；读不到就不带
          final audioSeconds = await _probeAudioDuration(audioBytes);
          await _sendAttachmentOptimistic(
            fileBytes: audioBytes,
            fileName: audioName,
            type: 'audio',
            caption: audioName,
            meta: audioSeconds > 0 ? {kMetaAudioDurationSeconds: audioSeconds} : null,
          );
        case _AttachmentKind.anyFile:
          final anyFiles = await FilePicker.pickFiles(type: FileType.any);
          if (anyFiles.isEmpty) return;
          final any = anyFiles.first;
          if (!_withinAttachmentLimit(await any.length())) return;
          final anyName = any.name;
          final anyBytes = await any.readAsBytes();
          await _sendAttachmentOptimistic(
            fileBytes: anyBytes,
            fileName: anyName,
            type: 'file',
            caption: anyName,
          );
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      _notice(
          context,
          _isAttachmentTooLarge(e)
              ? _attachmentSendError(l10n, e)
              : backendError(l10n, l10n.chatPageSendFailed(e.message)));
    } catch (e) {
      if (!mounted) return;
      _notice(context, _attachmentSendError(AppLocalizations.of(context)!, e));
    }
  }

  /// 附件大小上限的显示串（如 `64 MB`）：只在"太大"提示里报出服务端上限用。
  String _maxAttachmentLabel(int bytes) =>
      '${(bytes / (1024 * 1024)).round()} MB';

  /// 附件大小**本地预检**：仅当服务端已告知上限（`/health` 的 max_attachment_bytes）
  /// 时生效。超限立刻返回 false 并弹**人话**——避免把超大文件读满内存再走加密/上传
  /// （老板 2026-10-08：拖 1GB 视频要等很久才报错）。上限未知时不拦（宁可慢，不误拦）。
  bool _withinAttachmentLimit(int size) {
    final limit = serverMaxAttachmentBytes;
    if (limit == null || size <= limit) return true;
    _notice(
        context,
        AppLocalizations.of(context)!
            .chatPageAttachmentTooLarge(_maxAttachmentLabel(limit)));
    return false;
  }

  /// 服务端是否因**附件过大**而拒（413 / PAYLOAD_TOO_LARGE）。拖放与选择器两条
  /// 附件入口共用：据此把"技术串"换成"文件太大"的人话。
  bool _isAttachmentTooLarge(Object error) =>
      error is ApiException &&
      (error.code == 'PAYLOAD_TOO_LARGE' || error.httpStatus == 413);

  /// 附件发送失败文案：**超限**单独给人话（老板 2026-10-08：此前只看到
  /// `ApiException(PAYLOAD_TOO_LARGE): request body exceeds … bytes` 这种技术串）；
  /// 其余照旧走 `chatPageSendFailed`。上限未知（旧服务端）时退化为不带数字的版本。
  String _attachmentSendError(AppLocalizations l10n, Object error) {
    if (_isAttachmentTooLarge(error)) {
      final limit = serverMaxAttachmentBytes;
      return limit == null
          ? l10n.chatPageAttachmentTooLargeUnknown
          : l10n.chatPageAttachmentTooLarge(_maxAttachmentLabel(limit));
    }
    return l10n.chatPageSendFailed('$error');
  }

  /// 桌面端拖入文件直接发送（desktop_drop）：按扩展名归类到现有附件类型，逐个
  /// 复用 [_sendAttachmentOptimistic]（与相册/文件对话框同一收口）。多文件**顺序**
  /// 发送，避免并发上传；拖进来的目录等非普通文件直接跳过。
  Future<void> _sendDroppedFiles(List<XFile> files) async {
    if (files.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    for (final f in files) {
      // 拖进来的可能是目录（readAsBytes 会抛）——只处理普通文件
      if (!kIsWeb && f.path.isNotEmpty) {
        final st = FileStat.statSync(f.path);
        if (st.type != FileSystemEntityType.file) continue;
      }
      try {
        // 超限立刻失败（人话），不把超大文件读满内存再上传（老板 2026-10-08）
        if (!_withinAttachmentLimit(await f.length())) continue;
        final bytes = await f.readAsBytes();
        final type = _dropAttachmentType(f.name);
        if (type == 'audio') {
          // 与「音频文件」入口同款：发前探一次时长，对端开箱即显示（老板 2026-09-13）
          final seconds = await _probeAudioDuration(bytes);
          await _sendAttachmentOptimistic(
            fileBytes: bytes,
            fileName: f.name,
            type: 'audio',
            caption: f.name,
            meta: seconds > 0 ? {kMetaAudioDurationSeconds: seconds} : null,
          );
        } else if (type == 'file') {
          await _sendAttachmentOptimistic(
              fileBytes: bytes, fileName: f.name, type: 'file', caption: f.name);
        } else {
          await _sendAttachmentOptimistic(
              fileBytes: bytes, fileName: f.name, type: type);
        }
      } catch (e) {
        if (!mounted) return;
        _notice(context, _attachmentSendError(l10n, e));
      }
    }
  }

  // ---------- 剪贴板粘贴：附件面板入口 + 桌面 Cmd/Ctrl+V（老板 2026-10-12） ----------

  /// 剪贴板图片的合成文件名。粘贴没有"原名"可言（截图/浏览器拷图都不带名），
  /// 用时间戳保证连发多条不重名；扩展名跟字节格式走——`pasteboard` 在
  /// macOS（NSPasteboard）、Windows（DIB 转换）、iOS（UIPasteboard）三端
  /// 返回的都是 PNG。这名字会写进消息明文（`📎 <fileName>`，引用快照/对端保存都看它）。
  String _pastedImageName() {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '粘贴图片_${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}${two(t.second)}.png';
  }

  /// 粘贴的落点：读剪贴板 → 分流（与微信口径一致——**同时有图和文时发图**）：
  /// ① **文件路径优先**（访达/资源管理器里拷的文件，仅桌面，见
  ///    [_pasteboardFilesSupported]）→ 按扩展名归类后走 [_sendPastedFiles]；
  /// ② 没有真实本地文件 → 图片**字节**（截图 / 图片 App 拷贝 / 浏览器拷图）
  ///    → **确认弹窗**（缩略图）→ 走 [_sendAttachmentOptimistic] 发送；
  /// ③ 都没有 → 纯文本，插入输入框光标处（见 [_insertPastedText]）；
  /// ④ 全空 → 提示「剪贴板是空的」（附件面板点了没反馈会很懵）。
  ///
  /// **为什么文件优先于图片字节**（老板 2026-10-12 实测 + 机制）：macOS 在
  /// Finder 里拷文件时，剪贴板里的"图片数据"是**文件类型图标**（系统合成的
  /// 缩略图，pdf/mp4 等同理），不是文件内容——先读 image 分支会把图标当成
  /// 图发出去（弹窗显示图标、发出去也是一张图标）。文件路径才是真内容，
  /// 所以先判 files；校验过本地真实存在（浏览器拷图有时会带一个 http 派
  /// 生的假路径，自然落空）才走文件分支。
  ///
  /// 为什么发送前要确认（老板 2026-10-12）：剪贴板内容不可见——可能是几分钟前
  /// 拷的旧图/旧文件，而 E2EE 消息对方可能已收到、撤不回。图片/文件弹窗给一次
  /// **带预览**的确认；纯文本只是插进输入框（随时可改），不弹。
  ///
  /// 为什么文本要自己插：桌面快捷键一旦被页面级 CallbackShortcuts 匹配就会消费掉，
  /// WidgetsApp 默认的文字粘贴不会跑，所以这一支得自己来（等价于原生粘贴：
  /// 替换选中区、光标落到插入文本尾）。
  Future<void> _pasteFromClipboard() async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final localFiles = _pasteboardFilesSupported
          ? (await Pasteboard.files()).where(_isLocalReadableFile).toList()
          : const <String>[];
      if (!mounted) return;
      if (localFiles.isNotEmpty) {
        await _sendPastedFiles(localFiles.map(XFile.new).toList());
        return;
      }
      final bytes = await Pasteboard.image;
      if (!mounted) return;
      if (bytes != null) {
        // 超限预检放确认前：都看预览了才被告知超大，不如先拦（老板 2026-10-08 同思路）
        if (!_withinAttachmentLimit(bytes.length)) return;
        final ok = await _confirmPasteSend(_PastePayload.image(bytes));
        if (!ok || !mounted) return;
        await _sendAttachmentOptimistic(
            fileBytes: bytes, fileName: _pastedImageName(), type: 'image');
        return;
      }
      final text = await Pasteboard.text ?? '';
      if (!mounted) return;
      if (text.isEmpty) {
        _notice(context, l10n.chatPagePasteEmpty);
        return;
      }
      _insertPastedText(text);
    } catch (e) {
      if (!mounted) return;
      _notice(context, _attachmentSendError(l10n, e));
    }
  }

  /// 剪贴板里的**文件**（Finder/资源管理器里拷的）按扩展名归类后走确认弹窗：
  /// - 单张图片 → 读真实字节、弹窗给**缩略图**、按图片消息发（用真名，不是
  ///   合成名——它本来就是有名字的文件；老板 2026-10-12：拷 png 粘贴就该
  ///   跟图片 App 里拷贝一样看到图、发出去也是图）；
  /// - 其余（多图/视频/音频/混合/其他文件）→ 按 [kind] 问的名单弹窗
  ///   （标题和图标按类型走），发送仍走 [_sendDroppedFiles]——它逐文件按
  ///   扩展名分型，视频发视频、音频发音频（带时长探测）、图片发图片。
  Future<void> _sendPastedFiles(List<XFile> xfiles) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final kinds = xfiles.map((f) => _dropAttachmentType(f.name)).toSet();
      if (kinds.length == 1 && kinds.first == 'image' && xfiles.length == 1) {
        final bytes = await xfiles.first.readAsBytes();
        if (!mounted) return;
        if (!_withinAttachmentLimit(bytes.length)) return;
        final ok = await _confirmPasteSend(_PastePayload.image(bytes));
        if (!ok || !mounted) return;
        await _sendAttachmentOptimistic(
            fileBytes: bytes, fileName: xfiles.first.name, type: 'image');
        return;
      }
      // 同类媒体按那个类型问（视频/音频），混合或非媒体按"文件"问
      final kind = kinds.length == 1 ? kinds.first : 'file';
      final ok = await _confirmPasteSend(_PastePayload.files(xfiles, kind));
      if (!ok || !mounted) return;
      // 逐个的大小预检在 _sendDroppedFiles 里（要先读盘才知道，同拖放口径）
      await _sendDroppedFiles(xfiles);
    } catch (e) {
      if (!mounted) return;
      _notice(context, _attachmentSendError(l10n, e));
    }
  }

  /// 粘贴发送前的确认弹窗（老板 2026-10-12）：图片给预览、文件给名单，
  /// 按钮 取消/发送。点遮罩或系统返回 = 取消（不能默认发送）。
  /// 返回 true = 用户确认发送。
  Future<bool> _confirmPasteSend(_PastePayload payload) async {
    final l10n = AppLocalizations.of(context)!;
    final bytes = payload.bytes;
    final files = payload.files;
    final confirmed = await showDialog<bool>(
      context: context,
      // 破坏性确认（粘贴发送不可轻点）：禁误触关闭（点外面/系统返回都不行），
      // 必须点按钮（老板 2026-10-15）
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          // 标题按类型问：图片问"这张图片"，视频/音频/文件各自问（复数走
          // Intl.plural，1 个走单数形态）—— Finder 里拷的 mp4 不该问"文件"
          title: Text(switch (payload.kind) {
            'image' => l10n.chatPagePasteSendImageTitle,
            'video' => l10n.chatPagePasteSendVideoTitle(files!.length),
            'audio' => l10n.chatPagePasteSendAudioTitle(files!.length),
            _ => l10n.chatPagePasteSendFilesTitle(files!.length),
          }),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280, maxHeight: 320),
            child: bytes != null
                ? Image.memory(bytes, fit: BoxFit.contain)
                // 名单用 SingleChildScrollView + Column(min)：对话框要算内容
                // 固有宽度，ListView(shrinkWrap) 会抛 intrinsic dimensions 异常
                : SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final f in files!)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            // 图标也按类型：视频/音频不该挂个通用文件图标
                            leading: Icon(switch (payload.kind) {
                              'video' => Icons.movie,
                              'audio' => Icons.music_note,
                              _ => Icons.insert_drive_file,
                            }),
                            title: Text(f.name,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                      ],
                    ),
                  ),
          ),
          actions: [
            CancelButton(onPressed: () => Navigator.of(ctx).pop(false)),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l10n.send),
            ),
          ],
        ),
      ),
    );
    return confirmed ?? false;
  }

  /// 文本粘贴回退：把剪贴板文本插到输入框光标处（选中区替换）。
  /// 焦点不在输入框时（焦点在消息列表/别处）先把焦点拉回来——否则插了字
  /// 用户看不见光标，也不知道字去哪儿了。
  void _insertPastedText(String text) {
    if (text.isEmpty) return;
    final controller = _input;
    final sel = controller.selection;
    // 从未聚焦过的输入框 selection 是 -1（无效值）：按"追加到末尾"处理
    final hasSelection = sel.start >= 0 && sel.end >= 0;
    final start =
        hasSelection ? math.min(sel.start, sel.end) : controller.text.length;
    final end =
        hasSelection ? math.max(sel.start, sel.end) : controller.text.length;
    final newText = controller.text.replaceRange(start, end, text);
    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + text.length),
    );
    _inputFocusNode.requestFocus();
  }

  // ---------- 视频：下载解密 → 临时文件 → video_player 播放 ----------

  /// 附件元数据缺失的媒体消息兜底 UI（2026-10-09）：明确的「附件不可用 ·
  /// 点按重试」，替代此前的 `🎬/📎 文件名` 乱码行（两个 emoji：iOS 渲染成
  /// 豆腐块、Android 看着像"视频+别针"，都不是真媒体观感）。
  /// 点按 = 清媒体缓存 + 复位该条的自愈计数 + 立即触发一次附件元数据自愈
  /// （服务端有数据的话，一轮 sync 周期内自动修复；服务端确认没有的（孤儿，
  /// 404）不显示本行——见 [_healConfirmedMissing]）。
  Widget _attachmentUnusable(HistoryMessage m) {
    final l10n = AppLocalizations.of(context)!;
    final confirmedMissing = _healConfirmedMissing.contains(m.env.messageId);
    // 系统提示不用用户内容色：淡灰小字同气泡时间戳一族（老板 2026-10-10，
    // 淡灰方案——红色留给「发送失败 · 点击重发」，两种状态不混淆）
    final subtle =
        _uiStyle == 'gradient' ? Colors.white70 : Colors.grey;
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.broken_image_outlined, size: 14, color: subtle),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            // 服务端确认无附件（孤儿消息）：重试注定 404，不再邀请点按
            // （老板 2026-10-10）；网络抖动等不确定原因才保留重试入口
            confirmedMissing
                ? l10n.chatPageAttachmentUnusable
                : '${l10n.chatPageAttachmentUnusable} · ${l10n.chatPageAttachmentRetry}',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: subtle),
          ),
        ),
      ],
    );
    if (confirmedMissing) return row;
    return Clickable(
      onTap: () {
        _retryAttachment(m);
        // 网络抖动累计放弃（计数置满）的，手动重试必须复位计数——否则
        // _healAttachments 的筛选直接跳过这条，点按毫无反应（bug 修复）
        _healAttempts.remove(m.env.messageId);
        unawaited(_healAttachments());
      },
      child: row,
    );
  }

  /// 视频消息：内联预览（首帧 + 播放按钮），点击全屏播放；发送端本地密文
  /// 即时显示、接收端服务端拉取（老板 2026-09-11：改回直接显示）。
  Widget _buildVideo(
      HistoryMessage m) {
    final att = m.attachment;
    // 附件元数据缺失（sync 竞态漏拉/超大被拒的孤儿）：不再是 `🎬 📎 文件名`
    // 那行乱码（两个 emoji 渲染差异 + 假"视频"观感）——明确「不可用 + 点按重试」
    // （2026-10-09）。重试 = 清缓存 + 触发附件元数据自愈
    if (att == null) return _attachmentUnusable(m);
    return FutureBuilder<Uint8List>(
      future: _videoBytes(m),
      builder: (context, snap) {
        if (snap.hasData) {
          return _VideoPreview(
              bytes: snap.data!,
              spaceId: widget.spaceId,
              messageId: m.env.messageId,
              onDownload: () => unawaited(_saveAttachment(m)));
        }
        if (snap.hasError) {
          return Clickable(
            onTap: () => _retryAttachment(m),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.download_outlined, size: 16),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    AppLocalizations.of(context)!.chatPageAttachmentTapToDownload,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          );
        }
        return const SizedBox(
            width: 60, height: 60, child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
      },
    );
  }

  /// 视频明文（同 [_imageBytes]）：按 messageId 缓存 future，内联预览与首帧
  /// 缩略图共用同一次解密。
  Future<Uint8List> _videoBytes(HistoryMessage m) =>
      _videoCache.putIfAbsent(m.env.messageId, () => _attachmentBytes(m));

  /// 视频首帧缩略图（JPEG，长边 128）：复用内联预览的解密缓存文件（同一条消息
  /// 只解密、只落盘一次）→ 原生取帧；按 messageId 缓存（老板要求 2026-09-15：
  /// 长按菜单/引用条/引用块里视频也显示缩略图，而不是别针 + 文件名）。
  Future<Uint8List> _videoThumbBytes(HistoryMessage m) =>
      _videoThumbCache.putIfAbsent(m.env.messageId, () async {
        final file =
            await MediaCache.ensure(widget.spaceId, m.env.messageId, 'mp4', () => _videoBytes(m));
        final thumb = await VideoThumbnail.thumbnailData(
          video: file.path,
          imageFormat: ImageFormat.JPEG,
          maxWidth: 128,
          quality: 75,
        );
        if (thumb == null) throw StateError('视频缩略图取帧失败');
        return thumb;
      });

  /// 保存媒体附件到设备（长按菜单/气泡「保存」+ 全屏「保存」，老板 2026-10-02）：
  /// - **移动端的图片/视频**：存**系统相册**（`gal`；老板 2026-10-08，不再落到 App
  ///   自己的文件系统里）；
  /// - 其余（音频/文件，以及桌面端的一切）：弹系统保存对话框（`FilePicker.saveFile`）选位置。
  /// 文件名用消息正文里的原名；失败弹顶部通知（下载/解密失败同口径）。
  Future<void> _saveAttachment(HistoryMessage m) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final bytes = await _attachmentBytes(m);
      // 原名兜底：语音固定 .m4a；其余从正文取后缀
      final ext = _attachmentExtOf(m);
      final base = m.env.type == 'voice'
          ? 'voice-${m.env.messageId.substring(0, 8)}'
          : m.plaintext.trim().isEmpty
              ? m.env.messageId.substring(0, 8)
              : m.plaintext.trim();
      final fileName = base.contains('.') || ext.isEmpty ? base : '$base.$ext';

      if (canSaveToGallery && (m.env.type == 'image' || m.env.type == 'video')) {
        // 相册：图片直接写字节；视频 gal 需要文件路径——复用播放用的解密缓存
        // （确定性路径按 messageId，本来已落盘的话不再重复写）
        if (m.env.type == 'image') {
          await saveImageToGallery(bytes, name: base);
        } else {
          final file = await MediaCache.ensure(
              widget.spaceId, m.env.messageId, 'mp4', () async => bytes);
          await saveVideoToGallery(file.path);
        }
        if (!mounted) return;
        _notice(context, l10n.chatPageAttachmentSaved);
        return;
      }

      // file_picker 12.x：saveFile 同 pickFiles 一样是静态方法（返回目标 Uri，取消为 null）
      final target = await FilePicker.saveFile(
        fileName: fileName,
        bytes: bytes,
      );
      if (!mounted) return;
      // 用户取消（null）不算失败，静默返回
      if (target == null) return;
      _notice(context, l10n.chatPageAttachmentSaved);
    } catch (e) {
      if (!mounted) return;
      _notice(context, l10n.chatPageFileSaveFailed('$e'));
    }
  }

  /// 保存一段**图片字节**到设备（头像大图的「保存」按钮用）：移动端入相册，
  /// 桌面端弹系统保存对话框。[fileName] 带扩展名（桌面端保存对话框用；相册侧只取
  /// 去掉扩展名的基名）。
  Future<void> _saveImageBytesToDevice(Uint8List bytes, String fileName) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      if (canSaveToGallery) {
        await saveImageToGallery(bytes, name: fileName);
      } else {
        final target =
            await FilePicker.saveFile(fileName: fileName, bytes: bytes);
        if (target == null) return; // 用户取消
      }
      if (!mounted) return;
      _notice(context, l10n.chatPageAttachmentSaved);
    } catch (e) {
      if (!mounted) return;
      _notice(context, l10n.chatPageFileSaveFailed('$e'));
    }
  }

  /// 头像大图「保存」：[name] 为显示名（一般是对端/成员名，可能为空）→ 落一个
  /// `*.jpg` 文件名（桌面端保存对话框会显示它）。
  Future<void> _saveAvatarImage(String? name, Uint8List bytes) {
    final base = (name ?? '').trim();
    final safe = base.isEmpty ? 'avatar' : base.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return _saveImageBytesToDevice(
        bytes, safe.contains('.') ? safe : '$safe.jpg');
  }

  /// 附件明文：发送端优先本地密文解密（上传完成前/失败后也能即时显示），
  /// 无本地密文（接收端）走服务端拉取。
  Future<Uint8List> _attachmentBytes(HistoryMessage m) async {
    final att = m.attachment;
    if (att == null) throw StateError('附件元数据缺失');
    // stored 模式：本机留存的明文优先（零网络、零解密），拿到即返回
    final stored = await _storedFile(m);
    if (stored != null) return stored.readAsBytes();
    final bytes = await _repo.attachmentBytes(att);
    if (_storeAttachments) {
      // 顺手落长期目录（下次打开消息流直接命中）
      unawaited(AttachmentStore.ensure(
          widget.spaceId, m.env.messageId, _attachmentExtOf(m), () async => bytes));
    }
    return bytes;
  }

  /// 是否"留存"模式（附件明文长期留在本机）。
  bool get _storeAttachments => _attachmentStorage == 'stored';

  /// 附件在长期目录里的扩展名（语音固定 m4a，其余按正文后缀）。
  String _attachmentExtOf(HistoryMessage m) =>
      m.env.type == 'voice' ? 'm4a' : _extOf(m.plaintext);

  /// 本机留存的明文副本（stored 模式且文件仍在）→ 直接读；否则 null。
  Future<File?> _storedFile(HistoryMessage m) async {
    if (!_storeAttachments) return null;
    final f = await AttachmentStore.pathFor(widget.spaceId, m.env.messageId, _attachmentExtOf(m));
    if (f == null || !await f.exists()) return null;
    return f;
  }

  /// 重新下载某条附件（清掉缓存 future → 下次渲染重新拉取）。
  void _retryAttachment(HistoryMessage m) {
    _imageCache.remove(m.env.messageId);
    _videoCache.remove(m.env.messageId);
    _videoThumbCache.remove(m.env.messageId);
    setState(() {});
  }

  /// stored 模式：新到附件的明文**收到即落盘**（消息流里点开就能看，不用等下载）。
  /// 已有的跳过；失败静默——不打扰，用户点消息还能重新下载。
  Future<void> _autoStoreAttachments(List<HistoryMessage> msgs) async {
    if (!_storeAttachments) return;
    for (final m in msgs) {
      try {
        await _attachmentBytes(m);
      } catch (_) {
        // 单个失败不影响其它（网络抖动/元数据未就绪）
      }
    }
  }

  /// 图片明文（发送端本地密文解密 / 接收端服务端拉取）：按 messageId 缓存 future，
  /// 气泡、长按菜单预览行、引用块缩略图共用同一次加载。
  Future<Uint8List> _imageBytes(
      HistoryMessage m) =>
      _imageCache.putIfAbsent(m.env.messageId, () => _attachmentBytes(m));

  /// 图片消息：本地密文（发送端即时显示/上传失败兜底）或服务端拉取 →
  /// 缩略展示；点击全屏查看。
  Widget _buildImage(
      HistoryMessage m) {
    final att = m.attachment;
    if (att == null) return _attachmentUnusable(m);
    return FutureBuilder<Uint8List>(
      future: _imageBytes(m),
      builder: (context, snap) {
        if (snap.hasData) {
          return Clickable(
            onTap: () => _showFullImage(m, snap.data!),
            borderRadius: BorderRadius.circular(8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(snap.data!, width: 180, height: 180, fit: BoxFit.cover),
            ),
          );
        }
        if (snap.hasError) {
          return Clickable(
            onTap: () => _retryAttachment(m),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.download_outlined, size: 16),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    AppLocalizations.of(context)!.chatPageAttachmentTapToDownload,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          );
        }
        return const SizedBox(width: 60, height: 60, child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
      },
    );
  }

  /// 全屏查看图片（品牌粉蓝渐变大图 + 双指缩放 + 点任何位置关闭，与头像全屏一致）。
  /// useSafeArea:false + 直角 shape：背景铺满整屏，不留圆角和上下安全区空隙。
  /// 背景 = kBrandGradient（老板 2026-09-15：全屏查看用首屏同款渐变，更有品牌感）。
  /// 底部「保存」按钮（老板 2026-10-08）：移动端存相册 / 桌面弹保存对话框。
  /// 轻触关闭（老板 2026-10-12）：点击屏幕任何地方都返回聊天页，不必非找右上角 ✕；
  /// 与 _showAvatarFullscreen 同一套 Clickable 包裹——缩放/拖动仍归 InteractiveViewer，
  /// 只有"轻触"（ pointer 未移动即抬起）才关，双指放大后误触不会关掉大图。
  Future<void> _showFullImage(HistoryMessage m, Uint8List bytes) async {
    await withImmersiveFullscreen(() => showDialog<void>(
          context: context,
          barrierDismissible: true,
          useSafeArea: false,
          builder: (ctx) => Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: EdgeInsets.zero,
            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
            // SizedBox.expand：渐变底严格铺满整屏（含状态栏与刘海区域）
            child: SizedBox.expand(
              child: DecoratedBox(
                decoration: const BoxDecoration(gradient: kBrandGradient),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Clickable(
                        onTap: () => Navigator.of(ctx).pop(),
                        child: InteractiveViewer(
                          child: Center(
                              child: Image.memory(bytes, fit: BoxFit.contain)),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 8,
                      right: 8,
                      // SafeArea：万一系统栏没隐藏（某平台不支持），关闭键也不会被压在下面
                      child: SafeArea(child: _FullscreenCloseButton()),
                    ),
                    // 底部「保存」（老板 2026-10-08）：移动端存相册、桌面弹保存对话框。
                    // 先关大图再保存——顶部提示是聊天页覆盖层，压在 Dialog 下面看不见。
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 32,
                      child: Center(
                        child: FilledButton.icon(
                          onPressed: () {
                            Navigator.of(ctx).pop();
                            unawaited(_saveAttachment(m));
                          },
                          icon: const Icon(Icons.save_alt),
                          label:
                              Text(AppLocalizations.of(ctx)!.chatPageActionSave),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ));
  }

  /// 小尺寸图片缩略图（长按菜单预览行 / 引用块 / 输入栏引用条用）：正方形 cover
  /// 裁剪；加载中转圈，失败（无附件/解密失败）显示破图标占位。
  /// 老板要求 2026-09-13：引用与长按菜单里看缩略图，而不是文件名。
  Widget _buildImageThumb(
      HistoryMessage m, {double size = 40}) {
    return FutureBuilder<Uint8List>(
      future: _imageBytes(m),
      builder: (context, snap) {
        if (snap.hasData) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.memory(snap.data!,
                width: size, height: size, fit: BoxFit.cover),
          );
        }
        return Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(6),
          ),
          child: snap.hasError
              ? Icon(Icons.broken_image_outlined,
                  size: size * 0.5, color: Colors.grey)
              : SizedBox(
                  width: size * 0.45,
                  height: size * 0.45,
                  child: const CircularProgressIndicator(strokeWidth: 2)),
        );
      },
    );
  }

  /// 小尺寸视频缩略图（长按菜单预览行 / 引用块 / 输入栏引用条用）：首帧 + 播放
  /// 三角，正方形 cover 裁剪；加载中转圈，失败（无附件/解密失败/平台无取帧能力）
  /// 显示摄像机占位（老板要求 2026-09-15）。
  Widget _buildVideoThumb(HistoryMessage m, {double size = 40}) {
    return FutureBuilder<Uint8List>(
      future: _videoThumbBytes(m),
      builder: (context, snap) {
        if (snap.hasData) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Image.memory(snap.data!,
                    width: size, height: size, fit: BoxFit.cover),
                Icon(Icons.play_circle_fill,
                    size: size * 0.5, color: Colors.white70),
              ],
            ),
          );
        }
        return Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(6),
          ),
          child: snap.hasError
              ? Icon(Icons.videocam_outlined, size: size * 0.5, color: Colors.grey)
              : SizedBox(
                  width: size * 0.45,
                  height: size * 0.45,
                  child: const CircularProgressIndicator(strokeWidth: 2)),
        );
      },
    );
  }

  /// 消息气泡底色：按发言人性别——男天蓝 / 女品牌粉（浅色 tint 便于阅读）；
  /// 性别未登记（旧配置）回退原默认色（本人 indigo.shade100 / 对方 grey.shade200）。
  /// gradient 风格改用深色气泡（男深蓝 #2271F7 / 女深粉 #B83D80，白字醒目——
  /// 浅 tint 在渐变背景上区分度不足，老板要求 2026-09-09）。
  /// 两人同性别时第二个人（slot=1）取青色（2026-09-17 老板要求）——
  /// 槽位未知（老服务端/未拉取）或性别不同/未登记时不启用。
  /// 群聊一期（2026-10-03 按 member_id 哈希取色板；2026-10-06 老板废除随机取模，
  /// 改回按性别）：[senderMemberId] 非空**且**空间是 group 时，从 /space 下发的
  /// [_memberGenders] 查发送者性别配色；未知性别退回青色。duo 空间原配色规则
  /// 原样保留（含同性别第二人取青色，老板 2026-09-17 定）。
  Color _bubbleColor({required bool mine, String? senderMemberId}) {
    if (!mine && senderMemberId != null && _isGroup) {
      final gender = _memberGenders[senderMemberId] ?? '';
      if (_uiStyle == 'gradient') {
        if (gender == 'female') return const Color(0xFFB83D80); // 深粉（品牌粉加深）
        if (gender == 'male') return const Color(0xFF2271F7); // 品牌深蓝
        return const Color(0xFF00838F); // 未知性别 → 深青（老板 2026-10-06）
      }
      if (gender == 'female') return const Color(0xFFD6529C).withValues(alpha: 0.18);
      if (gender == 'male') return const Color(0xFF3BAFFD).withValues(alpha: 0.18);
      return const Color(0xFF26C6DA).withValues(alpha: 0.22); // 未知性别 → 青 tint
    }
    final gender = mine ? _myGender : _peerGender;
    final slot = mine ? _mySlot : _peerSlot;
    final otherSlot = mine ? _peerSlot : _mySlot;
    final bothGendersKnown =
        (_myGender == 'male' || _myGender == 'female') &&
        (_peerGender == 'male' || _peerGender == 'female');
    final sameGenderSecond = bothGendersKnown &&
        _myGender == _peerGender &&
        slot != null &&
        otherSlot != null &&
        slot != otherSlot &&
        slot == 1;
    if (_uiStyle == 'gradient') {
      if (sameGenderSecond) return const Color(0xFF00838F); // 深青（同性别第二人）
      if (gender == 'female') return const Color(0xFFB83D80); // 深粉（品牌粉加深）
      if (gender == 'male') return const Color(0xFF2271F7); // 品牌深蓝
      return mine ? const Color(0xFF2271F7) : const Color(0xFF64748B); // 性别未登记
    }
    if (sameGenderSecond) return const Color(0xFF26C6DA).withValues(alpha: 0.22); // 青色 tint
    if (gender == 'female') return const Color(0xFFD6529C).withValues(alpha: 0.18);
    if (gender == 'male') return const Color(0xFF3BAFFD).withValues(alpha: 0.18);
    return mine ? Colors.indigo.shade100 : Colors.grey.shade200;
  }

  /// **气泡上**的媒体前景色（音频播放键/波形、文件图标）：gradient 深色气泡用白，
  /// 素雅浅色 tint 用主题蓝。
  ///
  /// 消息流气泡与**长按菜单预览条**共用——菜单里那条也是按性别配的同款气泡底色，
  /// 只是波形窄一点，配色必须跟气泡一致（2026-09-27 踩过：预览条漏了这层 → 图标黑、
  /// 气泡里白）。**改配色改这里，两处一起变。**
  /// 引用条/引用块底色不同（6% 黑的浅底），各自传自己的颜色，不走这个 getter。
  Color get _mediaForegroundOnBubble => _uiStyle == 'gradient'
      ? Colors.white
      : Theme.of(context).colorScheme.primary;

  /// 消息内容按类型渲染（text 文本 / voice、audio 播放条 / image、video、file 各自卡片）。
  Widget _buildMessageContent(
      HistoryMessage m) {
    switch (m.env.type) {
      case 'voice':
      case 'audio':
        return _buildAudioBar(m, foreground: _mediaForegroundOnBubble);
      case 'image':
        return _buildImage(m);
      case 'video':
        return _buildVideo(m);
      case 'file':
        // 与音频条同一套前景色（气泡里 gradient 白 / 素雅主题蓝）：此前文件图标
        // 靠 ambient IconTheme，素雅模式下是默认黑，跟旁边音频播放键的蓝不是一个色
        return _buildFileCard(m, foreground: _mediaForegroundOnBubble);
      case 'system':
        return _buildSystemHint(m);
      default:
        // 文本消息：自动扫描明文里的 URL 渲染成可点链接（方案1，老板 2026-09-28）。
        // gradient 深色气泡下链接用白色（正文同色系），素雅气泡用品牌蓝（组件默认）。
        return LinkifiedText(m.plaintext,
            linkColor: _uiStyle == 'gradient' ? Colors.white : const Color(0xFF2271F7));
    }
  }

  /// 系统提示条（当前只有通话记录）：灰字 + 小图标的一行，不显示明文
  /// （明文是空的——文案由本端按自己的语言渲染）。
  Widget _buildSystemHint(HistoryMessage m) {
    final l10n = AppLocalizations.of(context)!;
    final meta = m.meta;
    final state = meta?[kMetaCallState] as String?;
    final seconds = meta?[kMetaCallDurationSeconds];
    final text = switch (state) {
      kCallStateCompleted => l10n.voiceCallRecordDuration(_formatCallDuration(seconds)),
      kCallStateMissed => l10n.voiceCallEndedNoAnswer,
      kCallStateDeclined => l10n.voiceCallEndedDeclined,
      kCallStateBusy => l10n.voiceCallEndedBusy,
      kCallStateCanceled => l10n.voiceCallEndedCanceled,
      kCallStateFailed => l10n.voiceCallEndedFailed,
      _ => m.plaintext,
    };
    final icon = switch (state) {
      kCallStateMissed || kCallStateDeclined || kCallStateBusy => Icons.call_missed_outlined,
      kCallStateFailed || kCallStateCanceled => Icons.call_end_outlined,
      _ => Icons.call_outlined,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: Colors.black54),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            style: const TextStyle(fontSize: 13, color: Colors.black54),
          ),
        ),
      ],
    );
  }

  /// 通话时长 `mm:ss`（超过 1 小时时分钟位继续累加，如 `83:20`）。
  String _formatCallDuration(Object? seconds) {
    final total = seconds is int ? seconds : (seconds is num ? seconds.round() : 0);
    final mm = (total ~/ 60).toString().padLeft(2, '0');
    final ss = (total % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  /// 音频条：播放键 + 固定波形图 + 时长（录音只写秒数 `25s`，上限 60s；音频文件
  /// 用 h/m/s，零的部分省略）。音频文件**多一行文件名**，与波形左对齐（老板
  /// 2026-09-27）。点击下载解密后播放（老板要求 2026-09-13）；**整块**可点（含
  /// 时长、文件名），不必非点中播放键（老板 2026-09-27）。
  ///
  /// 消息流气泡、长按菜单预览行、输入栏引用条、气泡里的引用块**共用这一个 widget**
  /// （老板 2026-09-27：这几处要一个样）。
  /// - [foreground] 由**调用方**给：四处底色不同（深色气泡 / 6% 黑引用条 / 引用块），
  ///   靠 ambient 主题必然有一处看不见（已踩过：菜单里图标变黑）。
  /// - [tappable] 为 false 时不挂整块点击：**气泡引用块的单击是"跳到原消息"**，不能
  ///   被"点哪都播放"抢掉；播放键本身仍可点（内层 IconButton 照旧）。
  ///
  /// 外层监听播放状态版本：菜单在独立路由、页面 setState 重建不到它。
  Widget _buildAudioBar(
      HistoryMessage m,
      {double waveformWidth = 120,
      required Color foreground,
      bool tappable = true}) {
    return ValueListenableBuilder<int>(
      valueListenable: _audioPlaybackVersion,
      builder: (context, _, child) => _buildAudioBarBody(m,
          waveformWidth: waveformWidth,
          foreground: foreground,
          tappable: tappable),
    );
  }

  Widget _buildAudioBarBody(
      HistoryMessage m,
      {required double waveformWidth,
      required Color foreground,
      required bool tappable}) {
    // 附件元数据缺失（sync 竞态漏拉）：波形条是"假"的（按 messageId 画的装饰），
    // 会误导成可播放——改显示统一的「不可用·重试」行（2026-10-09）
    if (m.attachment == null) return _attachmentUnusable(m);
    final playing = _playingMessageId == m.env.messageId;
    final seconds = _audioDurationSeconds(m);
    final isVoice = m.env.type == 'voice';
    final Widget playButton = IconButton(
      // 图标颜色**显式给**（跟波形同源 [foreground]，不再依赖外部 IconTheme）：
      // 消息气泡有 IconTheme.merge 把图标染白，而长按菜单预览条**没有**那一层
      // → 同一条音频条在两处两个颜色（老板 2026-09-27 实测：气泡白、弹窗黑）。
      icon: Icon(playing ? Icons.stop_circle : Icons.play_circle, color: foreground),
      onPressed: () => _playAudioMessage(m),
      visualDensity: VisualDensity.compact,
    );
    // 波形图 + 时长：**录音与音频文件共用同一段**（老板 2026-09-27）。波形只是
    // "形状由 messageId 决定"的装饰（不是真实波形），两种消息都能用。
    final Widget waveformRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 固定波形图：形状由 messageId 决定（同一条消息每次渲染一致），
        // 播放时已播部分染高亮色 + 竖线从左往右走，走完复原。
        _VoiceWaveform(
          playing: _audioStartedMessageId == m.env.messageId,
          durationSeconds: seconds,
          seed: m.env.messageId,
          width: waveformWidth,
          activeColor: foreground,
          inactiveColor: foreground.withValues(alpha: 0.4),
        ),
        // 时长未知时不显示任何文字（播放键 + 波形已足够表达"这是音频"，
        // 老板要求 2026-09-13）。录音只写秒数（上限 60s），音频文件用 h/m/s
        // （几个小时的音频写 "7200s" 没法看）。
        if (seconds > 0) ...[
          const SizedBox(width: 6),
          Text(
            isVoice ? _formatVoiceDuration(seconds) : _formatHmsDuration(seconds),
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ],
    );
    final Widget body;
    if (isVoice) {
      body = Row(
        mainAxisSize: MainAxisSize.min,
        children: [playButton, waveformRow],
      );
    } else {
      // 音频文件：播放键独占左列，右边一列两行（老板 2026-09-27）——上行波形+时长、
      // 下行文件名。**文件名与波形左对齐**靠这个"左列/右列"结构天然保证，不用
      // 量播放键宽度再去凑缩进（之前那版第二行贴着气泡左边缘，跟播放键不齐）。
      // 乐符图标已按老板要求删掉：文件名本身就是"这是一首歌"的最好说明。
      body = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          playButton,
          // Flexible 包住右列：它是这个 Row 里唯一的 flex 子项 → 拿到**有界**宽度
          // （父给的上限减去播放键），里面那行文件名才会按 ellipsis 截断。
          // 少了这一层，右列变成非 flex 子项、宽度**无界**，长歌名直接撑破气泡
          // （老板 2026-09-27 实测四处都破）。
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                waveformRow,
                // 单行 + 截断：Flexible 放在 Row 里才管**宽度**（放 Column 里变成管高度）
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        m.plaintext.trim().isEmpty ? m.env.type : m.plaintext.trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      );
    }
    // 气泡引用块（[tappable] = false）：不挂整块点击，把单击让给外层的"跳到原消息"。
    if (!tappable) return body;
    // 整块可点 = 播放/停止：**不必非点中那个播放键**，时长、文件名都在范围里
    // （老板 2026-09-27，与图片"点消息本体就是看大图"对齐）。播放键保留（它仍能点）。
    // behavior=opaque：否则容器自身不参与命中测试，只有子控件占的那几块能点——
    // 播放键与波形之间的空隙、两行之间的空隙都会漏掉（文件卡片同理）。
    return Clickable(
      onTap: () => _playAudioMessage(m),
      behavior: HitTestBehavior.opaque,
      child: body,
    );
  }

  /// 录音时长：只用秒（25s；录音上限 60s，老板要求 2026-09-13）。
  String _formatVoiceDuration(int totalSeconds) => '${totalSeconds}s';

  /// 音频文件时长：h/m/s，为零的部分不显示（如 3s、1m 15s、2h 5s）。
  String _formatHmsDuration(int totalSeconds) {
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    final parts = <String>[
      if (hours > 0) '${hours}h',
      if (minutes > 0) '${minutes}m',
      if (seconds > 0) '${seconds}s',
    ];
    return parts.isEmpty ? '0s' : parts.join(' ');
  }

  /// 音频（语音/音频文件）时长秒数：以载荷 meta（老板 2026-09-13）为准；发送端
  /// 探测失败时退而用播放器给的真实值（内存缓存，播放一次后才有）。
  /// 产品未上线，不兼容老数据——取不到就是 0，气泡不显示时长。
  int _audioDurationSeconds(HistoryMessage m) {
    final fromMeta = m.meta?[kMetaAudioDurationSeconds];
    if (fromMeta is int) return fromMeta;
    if (fromMeta is num) return fromMeta.round();
    return _audioFileDurations[m.env.messageId] ?? 0;
  }

  /// 读本地音频文件的总时长（audioplayers 设源后取时长，不播放）；失败返回 0。
  Future<int> _probeAudioDuration(Uint8List bytes) async {
    final player = AudioPlayer();
    try {
      await player.setSource(BytesSource(bytes));
      return (await player.getDuration())?.inSeconds ?? 0;
    } catch (_) {
      return 0;
    } finally {
      await player.dispose().catchError((_) => player);
    }
  }


  /// 文件消息名片：文件图标 + 文件信息（上=文件名、下=尺寸）。
  ///
  /// 消息流气泡、长按菜单预览条、输入栏引用条、气泡里的引用块**共用这一个 widget**
  /// （老板 2026-09-27：与音频条同样处理）。
  /// - [tappable] 为 true（气泡/菜单预览条/引用条）：**整块**可点 = 下载/打开
  ///   （本机有留存副本则直接用系统应用打开；老板 2026-09-15）。
  /// - [tappable] 为 false（**气泡引用块**）：整块单击让给外层的"跳到原消息"，
  ///   只有**文件图标**本身可点 = 打开（老板 2026-09-27）。
  /// 图标颜色**显式给**：复用它的几处 ambient IconTheme 不一样（踩过"菜单里变黑"）。
  Widget _buildFileCard(
      HistoryMessage m, {bool tappable = true, Color? foreground}) {
    final size = (m.attachment?['size'] as int?) ?? 0;
    final subtitleColor = _uiStyle == 'gradient' ? Colors.white70 : Colors.grey;
    // 附件消息明文是「📎 文件名」（发送端兜底文案）；名片里已有文件图标，前缀去掉
    var name = m.plaintext.trim();
    if (name.startsWith('📎')) name = name.replaceFirst('📎', '').trim();
    // 图标**单独可点**（整块不可点时——引用块——就只剩它能打开）。
    // opaque：整个 30×30 的方块都可点，不只落在字形上的那几个像素。
    final Widget icon = Clickable(
      onTap: () => _downloadFile(m),
      behavior: HitTestBehavior.opaque,
      child: Icon(Icons.insert_drive_file, size: 30, color: foreground),
    );
    // Flexible 套右列：它是 Row 里唯一的 flex 子项，拿到的是**有界**宽度（父给的
    // 上限减去图标），文件名才能按 maxLines:1 + ellipsis 截断。去掉它 → 右列变成
    // 非 flex 子项、宽度无界 → 长文件名撑破气泡（老板 2026-09-27 实测）。
    final Widget card = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        icon,
        const SizedBox(width: 8),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // maxLines:1 + ellipsis：长文件名**压成一行**，不换行、不撑破区域
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(_formatSize(size),
                  style: TextStyle(fontSize: 11, color: subtitleColor)),
            ],
          ),
        ),
      ],
    );
    if (!tappable) return card;
    return Clickable(
      onTap: () => _downloadFile(m),
      behavior: HitTestBehavior.opaque,
      child: card,
    );
  }

  String _formatSize(int bytes) {
    if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes B';
  }

  /// 文件附件：留存模式下**本机已有就直接打开**（零网络），否则下载后打开。
  /// secured 模式下沿用原来的"下载保存到应用文档目录 + 提示路径"。
  Future<void> _downloadFile(
      HistoryMessage m) async {
    final l10n = AppLocalizations.of(context)!;
    final att = m.attachment;
    if (att == null) {
      if (!mounted) return;
      _notice(context, l10n.chatPageAttachmentMetaMissing);
      return;
    }
    // 留存副本还在 → 直接交给系统应用打开。
    // Linux 没有 open_filex 实现：跳过「直接打开」，落到下方的下载→保存→
    // 提示路径流程（文件落 Documents，用户自己打开）
    final stored = await _storedFile(m);
    if (stored != null && !Platform.isLinux) {
      await _openFileWith(stored.path);
      return;
    }
    try {
      final bytes = await _repo.fetchAttachment(
        attachmentId: att['attachment_id'] as String,
        keyVersion: att['key_version'] as int,
        nonce: base64Decode(att['nonce'] as String),
      );
      // 留存落盘成功 → 交给系统应用打开；Linux 无 open_filex：落到下方的
      // Documents 保存 + 提示路径（与 secured 模式同一条出口）
      if (_storeAttachments && !Platform.isLinux) {
        final file = await AttachmentStore.ensure(
            widget.spaceId, m.env.messageId, _attachmentExtOf(m), () async => bytes);
        if (file != null) {
          await _openFileWith(file.path);
          return;
        }
      }
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/${m.plaintext}');
      await file.writeAsBytes(bytes);
      if (!mounted) return;
      _notice(context, l10n.chatPageSaved(file.path));
    } on ApiException catch (e) {
      if (!mounted) return;
      _notice(context, backendError(l10n, l10n.chatPageDownloadFailed(e.message)));
    } catch (e) {
      if (!mounted) return;
      _notice(context, l10n.chatPageDownloadFailed('$e'));
    }
  }

  /// 用系统应用打开本地文件（iOS 走预览/分享，Android 走 FileProvider）。
  Future<void> _openFileWith(String path) async {
    final res = await OpenFilex.open(path);
    if (!mounted) return;
    if (res.type != ResultType.done) {
      _notice(context, AppLocalizations.of(context)!.chatPageFileOpenFailed(res.message));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // 非 final：桌面端下面还要按需套 CallbackShortcuts（粘贴快捷键）/DropTarget
    // （拖放），见方法末尾两处包裹
    Widget page = Scaffold(
      // gradient 风格：body 延伸到 AppBar 之后，AppBar 透明浮在渐变上（同向导全屏
      // 渐变做法）；plain 风格保持原有布局（AppBar 浅粉底，body 从其下方开始）
      extendBodyBehindAppBar: _uiStyle == 'gradient',
      appBar: AppBar(
        backgroundColor: _uiStyle == 'gradient' ? Colors.transparent : null,
        // titleSpacing 8 + 内边距 8 = 原来的 16：logo 位置不变，
        // 但按住高亮的左缘退到 8（老板 2026-09-24）
        titleSpacing: 8,
        // 抬头只显示品牌名+slogan（不暴露空间 ID，对普通用户无意义）；
        // 在线状态由对话顶部条双灯呈现（「我的」灯三态：灰=未连接服务/绿=已连接/红=断线）
        //
        // 顶栏左半边现在分成**两个**点击对象（老板 2026-09-28）：
        //   ① logo 一块 → 「关于秘境」弹层；
        //   ② 标题「我的秘境」+ 下拉箭头 一块 → 「切换我的秘境」弹层，箭头紧挨着
        //      标题文字（原先是独立 IconButton，离文字一个图标按钮那么远）。
        //      只在 2 个及以上空间时给：单空间别暗示这里能切（2026-09-24 定），
        //      此时标题不可点。
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message: l10n.aboutPageTitle,
              child: InkWell(mouseCursor: SystemMouseCursors.click,
                borderRadius: BorderRadius.circular(10),
                onTap: _openAboutPage,
                child: const Padding(
                  // 给按住/长按的半透明高亮留出边距（否则会紧贴 logo 边缘）
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                  child: BrandLogo(),
                ),
              ),
            ),
            Flexible(child: _brandTitle()),
            // 其它秘境有未读 → 汇总角标（老板 2026-09-26）：不打开「选择秘境」
            // 也能一眼看到"别的秘境来消息了"。
            if (_otherUnreadTotal > 0) _UnreadBadge(count: _otherUnreadTotal),
          ],
        ),
        actions: [
          // （语音通话按钮在**状态条**里、对方芯片旁边——已加入才显示；
          //  未加入时那块位置显示「邀请加入」。见 _buildPeerChip 的 trailing）
          // 阅后即焚生效时的小标记（火苗 + 档位）：点击**直接**进档位弹层。
          // 放最左（锁屏按钮 / 汉堡菜单的左侧）。老板 2026-09-24：开了焚毁是一个
          // "会丢消息"的状态，值得在顶栏一直看得见，而不是藏进菜单里才发现。
          if (_burnSeconds > 0) _buildBurnBadge(l10n),
          // 锁屏（老板要求 2026-09-16）：一键立即锁屏，放在下拉菜单图标左侧。
          // 仅在已设置锁屏码时出现——没设 PIN 时锁屏不激活（LockPage 只会显示
          // "尚未设置锁屏码"提示页），摆一个按了没用的按钮反而误导。
          if (_hasPin)
            IconButton(
              icon: const Icon(Icons.lock_outline),
              tooltip: l10n.chatPageLockNow,
              onPressed: _lockNow,
            ),
          // 顶栏统一入口：语言/阅后即焚/本机 PIN（显示各功能当前值）
          PopupMenuButton<String>(
            // 菜单按钮：框架内部用 InkWell 且不接受 mouseCursor 参数，只能自己包一层
            // （覆盖视觉上的可点区＝图标本身；外圈 12px 留白仍是箭头）
            icon: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: const Icon(Icons.menu),
            ),
            tooltip: l10n.chatPageMenuMore,
            onSelected: (value) {
              switch (value) {
                case 'locale':
                  _menuAction(_showLocalePicker);
                case 'style':
                  _menuAction(_showStylePicker);
                case 'burn':
                  _menuAction(_showBurnPicker);
                case 'more':
                  _menuAction(_showMoreSettingsSheet);
                case 'advanced':
                  _menuAction(_showAdvancedSheet);
                case 'notify':
                  _menuAction(_showNotifyDialog);
                case 'pin':
                  _menuAction(_showSetLockDialog);
                case 'about':
                  _menuAction(_openAboutPage);
                case 'profile':
                  _menuAction(_showMyProfileSheet);
                case 'members':
                  _menuAction(_showMembersSheet);
                case 'entrancelist':
                  _menuAction(_showEntranceListSheet);
                case 'switchspace':
                  _menuAction(_openSpacePicker);
                case 'exit':
                  _menuAction(_showExitAppDialog);
              }
            },
            itemBuilder: (context) {
              // 语言当前值：取实际生效 locale 的语言码 → 中文/English 名
              final langCode = Localizations.localeOf(context).languageCode;
              // 行内左侧标签用稍淡色，与右侧当前值文字（默认 onSurface 深色）区分
              // 左侧标签 = **备注级**（淡色小字，不抢戏）；右侧"当前值" = 深色大字（老板 2026-09-23 定：
              // 左侧相当于备注，不用强调，右侧才是用户要看的东西 ✓）。
              // 显式钉死 13，与 captionStyle 一致——否则没写 fontSize 会落到平台默认
              // （macOS 偏大），同一菜单里纯标签行（头像/高级安全/关于/切换/退出）
              // 会比带值的行（我的身份/语言/主题/通道名称/阅后即焚/附件/锁屏码）显大一号
              final labelStyle = TextStyle(
                  fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant);
              final captionStyle = TextStyle(
                  fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant);
              final valueStyle = TextStyle(
                  fontSize: 14,
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.w500);
              // 「邮件通知」右侧值：没拉到（null）或没设置（none）时**不显示**——
              // 与「锁屏码」同款处理（老板 2026-09-15），静默比瞎显示"未设置"好
              final notifyValue = _notifyMenuValue(l10n, valueStyle);
              return [
                // 菜单分组（老板 2026-09-24 定；2026-09-25 删「生成通道码」项，
                // 改由「通道列表」弹层里的「新建通道」按钮承担）：
                //   ① 外观与锁：界面语言 / 界面主题 / 锁屏码
                //   ② 身份·通道·内容：我的资料（聚合原我的身份/我的头像）/ 当前通道 / 通道列表 /
                //      阅后即焚 / 附件存储 / 高级安全
                //   ③ 结尾：关于秘境 / 切换我的秘境 / 退出本应用
                PopupMenuItem(mouseCursor: SystemMouseCursors.click,
                  height: kMenuRowHeight,
                  value: 'locale',
                  child: Row(
                    children: [
                      Text(l10n.chatPageMenuLocaleLabel, style: captionStyle),
                      const Spacer(),
                      _menuValue(kLocaleLabels[langCode] ?? langCode, valueStyle),
                    ],
                  ),
                ),
                PopupMenuItem(mouseCursor: SystemMouseCursors.click,
                  height: kMenuRowHeight,
                  value: 'style',
                  child: Row(
                    children: [
                      Text(l10n.chatPageMenuStyleLabel, style: captionStyle),
                      const Spacer(),
                      _menuValue(_uiStyleLabel(_uiStyle, l10n), valueStyle),
                    ],
                  ),
                ),
                PopupMenuItem(mouseCursor: SystemMouseCursors.click,
                  height: kMenuRowHeight,
                  value: 'pin',
                  child: Row(
                    children: [
                      Text(l10n.chatPagePinLabel, style: captionStyle),
                      const Spacer(),
                      // 右簇：锁屏图标恒显；已设置再显示「已设置 · 时长」（老板
                      // 2026-10-18：右侧顺带显示当前锁屏时长，例如「已设置 · 1 分钟」）。
                      // 时长格式与阅后即焚一致（formatBurnDuration：整点值输出干净
                      // 文案，20 秒/1 分钟/5 分钟…）。未设置只有图标，不显示尾缀
                      // （老板 2026-09-15）
                      Icon(Icons.lock_outline, size: 18, color: labelStyle.color),
                      if (_hasPin) ...[
                        const SizedBox(width: 4),
                        _menuValue(
                          l10n.chatPagePinMenuValue(
                            formatBurnDuration(_lockSeconds, l10n),
                          ),
                          valueStyle,
                        ),
                      ],
                    ],
                  ),
                ),
                const PopupMenuDivider(height: kMenuDividerHeight),
                // 「我的资料」（老板 2026-10-17，聚合原「我的身份/我的头像」两项）：
                // 右侧人名+头像小图；点击 → 「我的资料」弹层（头像/名字/性别）
                PopupMenuItem(mouseCursor: SystemMouseCursors.click,
                  height: kMenuRowHeight,
                  value: 'profile',
                  child: Row(
                    children: [
                      Text(l10n.chatPageMenuMyProfile, style: labelStyle),
                      // 人名（空 → 「未设置」占位）；长名截断，与头像小图间留 6。
                      // 结构注意（老板 2026-10-17，两种失败各实测过）：
                      // - 纯 [Spacer] + [_menuValue]：PopupMenu 的内在宽度测量会把
                      //   本行报成最宽行、实际布局却给不满 → 溢出 6.4px（长名时）；
                      // - [Flexible] 包值：内在宽度失真使 Spacer 吸不到右缘 →
                      //   头像缩进 16.5px，不与其他行齐右。
                      // 最终形：Expanded 紧贴占满（不溢出）+ Align 右对齐 +
                      // [_menuValue] 的 180 上限（与整菜单共用同一截断规则），
                      // 头像恒在行最右缘。
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: _menuValue(
                            _myMemberName.isEmpty
                                ? l10n.chatPageNameUnset
                                : _myMemberName,
                            valueStyle,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      CircleAvatar(
                        radius: 12,
                        backgroundImage:
                            _myAvatarBytes != null ? MemoryImage(_myAvatarBytes!) : null,
                        child: _myAvatarBytes == null
                            ? const Icon(Icons.person, size: 16)
                            : null,
                      ),
                    ],
                  ),
                ),
                // 邮件通知（2026-10-01）：没进应用商店 → 没有后台推送，用邮件把离线的
                // 人拉回来。2026-10-02 起挪到「我的资料」之后（老板定），属分组②
                // （身份·通道·内容）。
                PopupMenuItem(mouseCursor: SystemMouseCursors.click,
                  height: kMenuRowHeight,
                  value: 'notify',
                  child: Row(
                    children: [
                      Text(l10n.chatPageNotifyLabel, style: captionStyle),
                      const Spacer(),
                      // 图标在值文字左边、图标+文字整体靠右（老板 2026-10-02；
                      // 与 devices/沙漏行同款右簇排布），尺寸同族 18
                      Icon(Icons.mark_email_unread_outlined,
                          size: 18, color: labelStyle.color),
                      if (notifyValue != null) ...[
                        const SizedBox(width: 4),
                        notifyValue,
                      ],
                    ],
                  ),
                ),
                // 「通道列表」：我本人在本空间的其他通道（老板 2026-09-25：多设备登录
                // 时看一眼"我还有哪些线挂着、在不在线"）。2026-10-02 合并原「当前通道」
                // 菜单项：改名入口收进弹层顶部的当前通道行，菜单只留这一项「我的通道」
                PopupMenuItem(mouseCursor: SystemMouseCursors.click,
                  height: kMenuRowHeight,
                  value: 'entrancelist',
                  child: Row(
                    children: [
                      Text(l10n.chatPageMenuEntranceList, style: captionStyle),
                      const Spacer(),
                      // 右侧 devices 图标 + 通道总数：与状态条「更多通道」入口同族
                      // （老板 2026-09-28）；数量是 member 维度（含本机），
                      // 轮询没拉到（离线）就不显示，不占位
                      Icon(Icons.devices, size: 18, color: labelStyle.color),
                      if (_myEntranceCount != null) ...[
                        const SizedBox(width: 4),
                        _menuValue('$_myEntranceCount', valueStyle),
                      ],
                    ],
                  ),
                ),
                // 「我的同伴」（2026-10-05 由「空间成员」改名，老板定）：成员名单 +
                // 邀请新成员。紧跟「我的通道」之后（老板定排序）——先看"我在这个
                // 空间挂了几条线"，再看"这个空间里有谁"。
                PopupMenuItem(mouseCursor: SystemMouseCursors.click,
                  height: kMenuRowHeight,
                  value: 'members',
                  child: Row(
                    children: [
                      Text(l10n.chatPageMembersTitle(_isGroup ? 'group' : 'duo'),
                          style: captionStyle),
                      const Spacer(),
                      // 「我的同伴」右簇：图标按空间类型区分（老板 2026-10-06）——
                      // duo = group_outlined（双人剪影），group = groups_outlined
                      // （多人，与创建向导「群组秘境」卡片同款）；仅群聊追加除我之外
                      // 的人数（图标在前、数字在后，与「我的通道」devices 行同风格）
                      // ——duo 不标人数。_memberCount 是身份数（含我），减 1 得同伴
                      // 数；轮询没拉到就不显示数字。
                      Icon(
                        _isGroup ? Icons.groups_outlined : Icons.group_outlined,
                        size: 18,
                        color: labelStyle.color,
                      ),
                      if (_isGroup && _memberCount > 1) ...[
                        const SizedBox(width: 4),
                        _menuValue('${_memberCount - 1}', valueStyle),
                      ],
                    ],
                  ),
                ),
                PopupMenuItem(mouseCursor: SystemMouseCursors.click,
                  height: kMenuRowHeight,
                  value: 'burn',
                  child: Row(
                    children: [
                      Text(l10n.chatPageMenuBurnLabel, style: captionStyle),
                      const Spacer(),
                      // 沙漏图标与顶栏标记同族（_BurnHourglass，老板 2026-09-28）：
                      // 未焚毁态是翻转动画的实沙漏；尺寸与 devices 图标一致（18）
                      const _BurnHourglass(burned: false, size: 18),
                      const SizedBox(width: 4),
                      // 不设期限（0）不显示档位值，菜单项只显示「阅后即焚」；
                      // 选了具体时长才在右侧显示（老板 2026-09-15）
                      if (_burnSeconds > 0)
                        _menuValue(_burnOptionLabel(_burnSeconds, l10n), valueStyle),
                    ],
                  ),
                ),
                // 更多设置（二级弹层：附件存储 + 墓碑消息；老板 2026-10-15）
                PopupMenuItem(mouseCursor: SystemMouseCursors.click,
                  height: kMenuRowHeight,
                  value: 'more',
                  child: Row(
                    children: [
                      Text(l10n.chatPageMenuMoreSettings, style: captionStyle),
                      const Spacer(),
                      // 通用设置图标（18 = 与 burn 沙漏/devices 图标同尺寸）
                      Icon(Icons.settings_outlined, size: 18, color: labelStyle.color),
                      // 右侧 > ：与「高级安全」同款二级入口标识（老板 2026-10-15）
                      const SizedBox(width: 2),
                      Icon(Icons.chevron_right, size: 18, color: labelStyle.color),
                    ],
                  ),
                ),
                // 高级（二级菜单走底部弹层）
                PopupMenuItem(mouseCursor: SystemMouseCursors.click,
                  height: kMenuRowHeight,
                  value: 'advanced',
                  child: Row(
                    children: [
                      Text(l10n.advancedMenuTitle, style: labelStyle),
                      const Spacer(),
                      // 危险/警告图标（老板 2026-10-15）：弹层里是改口令/删全部
                      // 消息/销毁通道这类破坏性操作，入口先给一个警示标识。**菜单里
                      // 不用红色**——太引人注意，红色留给弹层内部那一行
                      Icon(Icons.warning_amber_rounded,
                          size: 18, color: labelStyle.color),
                      const SizedBox(width: 2),
                      Icon(Icons.chevron_right, size: 18, color: labelStyle.color),
                    ],
                  ),
                ),
                const PopupMenuDivider(height: kMenuDividerHeight),
                // 关于与退出一组（都在分割线下方，退出垫底）
                PopupMenuItem(mouseCursor: SystemMouseCursors.click,
                  height: kMenuRowHeight,
                  value: 'about',
                  child: Row(
                    children: [
                      Text(l10n.chatPageMenuAbout, style: labelStyle),
                      const Spacer(),
                      // 右侧品牌 logo：与 devices/沙漏图标同大小（18，老板 2026-09-28）
                      const BrandLogo(size: 18),
                    ],
                  ),
                ),
                // 空间组：紧贴「退出」上方（老板 2026-09-22：切换空间属"离开当前空间"
                // 一类操作，放在关于之下、退出之上）。回调由入口注入——聊天页自己不读
                // Vault（PIN 模式下读/写 Vault 都要 pin，而它刻意不持有 PIN）。
                // 「切换空间」：唯一的空间入口（2026-09-22 由「切换空间 / 空间管理」合并，
                // 两者本来就指向同一个页面）。两个回调实际只会有一个非空（取决于谁注入）。
                PopupMenuItem(mouseCursor: SystemMouseCursors.click,
                    height: kMenuRowHeight,
                    value: 'switchspace',
                    child: Row(
                      children: [
                        Text(l10n.spaceListSwitch, style: labelStyle),
                        const Spacer(),
                        // 右侧 dynamic_feed 多窗口叠加：表达"多个空间"（老板
                        // 2026-09-28 定稿：layers/collections 对比后选回 dynamic_feed）
                        Icon(Icons.dynamic_feed, size: 18, color: labelStyle.color),
                      ],
                    ),
                  ),
                PopupMenuItem(mouseCursor: SystemMouseCursors.click,
                  height: kMenuRowHeight,
                  value: 'exit',
                  child: Row(
                    children: [
                      Text(l10n.chatPageMenuExit, style: labelStyle),
                      const Spacer(),
                      // 右侧退出图标：比纯文字更明确的「离开」信号（老板 2026-09-18）
                      Icon(Icons.logout, size: 18, color: labelStyle.color),
                    ],
                  ),
                ),
              ];
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          // 界面主题背景层：gradient=品牌粉蓝渐变（首屏/向导同款）；plain=不铺
          // 背景（露出 Scaffold 浅粉白纸感底色，与原有视觉效果完全一致）
          if (_uiStyle == 'gradient')
            const Positioned.fill(
              child: DecoratedBox(
                // Key 供测试精确断言聊天页背景（弹窗预览图也有渐变，需区分）
                key: ValueKey('chatPageGradientBackground'),
                decoration: BoxDecoration(gradient: kBrandGradient),
              ),
            ),
          // gradient 风格：body 延伸到 AppBar 之后——内容从工具栏高度下方开始
          // （避免与浮动 AppBar 重叠；同向导 SizedBox(kToolbarHeight) 做法）
          Padding(
            padding: EdgeInsets.only(
              top: _uiStyle == 'gradient'
                  ? MediaQuery.paddingOf(context).top + kToolbarHeight
                  : 0,
            ),
            child: Column(
              children: [
          // 对话顶部：双方名字 + 各自在线状态（对方左 / 我右，与消息对齐一致）
          // 两风格统一悬浮圆角条：不顶左右两头、四角有弧度、浮在背景上（老板要求
          // 2026-09-09——素雅纯色风格与渐变风格一致）
          Container(
            key: const ValueKey('chatPageStatusBar'),
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(12, 4, 12, 6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(24),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x26000000), // 柔和投影（背景上浮起）
                  blurRadius: 12,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            // 内边距不再挂在胶囊上，改由左右两块各自持有——这样左侧那块能**上/下/左
            // 三边完全贴合**胶囊边框（老板 2026-09-24）；clip 让它的方角被胶囊圆角裁掉。
            clipBehavior: Clip.antiAlias,
            // IntrinsicHeight：给这行一个确定高度，左侧那块才能用 stretch 撑满
            //（父级 Column 不限高，直接 stretch 会得到 Infinity 高度）
            child: IntrinsicHeight(
              child: Row(
                // spaceBetween + 两侧都 Flexible：名字短时左边贴左、右边贴右；名字长时
                // 各自最多占一半、超出「…」（老板 2026-09-24 实测：长名字会越过中线、
                // 冲出胶囊条）。圆点与箭头是固定项，永不被压掉。
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                // 子项撑满高度 → 左侧那块上下与胶囊贴合
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 对方（左）：圆点 + 名字（多空间时再加下拉箭头与可按底色；
                  // 对方未加入时紧跟其后的「邀请加入」链接，见 _buildPeerStatus）
                  Flexible(child: _buildPeerStatus(l10n)),
                  // 我的（右）：名字 + 状态灯/时刻 + 头像（老板 2026-09-26 新设计：
                  // 状态条加高到能放头像，**我方头像在最右**，文字在头像左侧）。
                  // 名字为空则不显示文本，只留灯与时刻。
                  //
                  // 「更多通道」的入口改成**名字左侧那个箭头**（老板 2026-09-26）：
                  // 舍弃原来的"整块可按 + 悬浮底色"的芯片效果——那一块现在只负责
                  // 展示（名字 + 状态灯/时刻），点它没有任何动作。
                  // Align 把内容收到实际宽度：不加的话会被 Flexible 撑满右半边、
                  // 内容与头像之间空一大段。
                  Flexible(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        // 右/上/下都 0：我方头像三面贴住胶囊内壁（与左侧对称）；
                        // 左 12 是"与左边那块之间的最小间隔"（名字很长被压缩时的兜底）
                        padding: const EdgeInsets.fromLTRB(12, 0, 0, 0),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // 箭头：独立可点 → 「更多通道」弹层（我的各条通道列表）
                            Material(
                              color: Colors.transparent,
                              shape: const CircleBorder(),
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                mouseCursor: SystemMouseCursors.click,
                                onTap: _showEntranceListSheet,
                                hoverColor: Colors.black.withValues(alpha: 0.05),
                                highlightColor: Colors.black.withValues(alpha: 0.08),
                                child: Tooltip(
                                  // 桌面端悬停提示：光看图标不一定看得出是"多设备"
                                  message: l10n.chatPageMenuEntranceList,
                                  child: SizedBox(
                                    // 正圆：非正方形会被 CircleBorder 拉成椭圆、顶到
                                    // 状态条上下边缘（与 invite 同源的问题）。
                                    // 边长与呼叫图标同源（kStatusAvatarSize=40）：
                                    // 32 的背景圈偏小、间距发紧（老板 2026-09-28）
                                    width: kStatusAvatarSize,
                                    height: kStatusAvatarSize,
                                    // 「手机 + 显示器」并排：比下拉箭头更能表达
                                    // "我有多条通道/设备"（老板 2026-09-26）
                                    child: Icon(Icons.devices,
                                        size: 20,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant),
                                  ),
                                ),
                              ),
                            ),
                            // 与「名字/时间」的间距 6px：加上图标在 32 宽容器里的
                            // 居中余量（(32-20)/2 = 6），到图标**视觉边缘**正好 12px，
                            // 与状态条其他间距一致（原 16px 视觉偏大，老板 2026-10-10）
                            const SizedBox(width: 6),
                            // Flexible 要包在**Column 外面**（老板 2026-09-28 实测的溢出：
                            // 名字长到 44 字时，这一行要 767px、只给 376px →
                            // "overflowed by 391 pixels on the right"）。
                            // 里面的 Flexible 只管**上下**（名字与状态行挤不开时压名字）；
                            // 横向不给任何约束 —— 名字有多长，Column 就有多宽。
                            // 对方那半格一直是外侧包 Flexible 的写法（2026-09-24 修的），
                            // 我方这半漏了。
                            Flexible(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  if (_myMemberName.isNotEmpty)
                                    Flexible(
                                      // 名字做成**可点胶囊**（老板 2026-10-09）：点击开
                                      // 「我的身份」弹窗（与菜单里「我的身份」同一入口），
                                      // 悬浮/按住变色，与状态条其他可点元素同口径。
                                      child: Tooltip(
                                        // 状态条 tooltip 全量补齐（老板 2026-10-10）
                                        message: l10n.chatPageMyNameTooltip,
                                        child: Material(
                                          color: Colors.transparent,
                                          shape: const StadiumBorder(),
                                          clipBehavior: Clip.antiAlias,
                                          child: InkWell(mouseCursor: SystemMouseCursors.click,
                                            onTap: _showRenameDialog,
                                            hoverColor:
                                                Colors.black.withValues(alpha: 0.05),
                                            highlightColor:
                                                Colors.black.withValues(alpha: 0.08),
                                            child: Padding(
                                              padding: const EdgeInsets.symmetric(
                                                  horizontal: 6, vertical: 2),
                                              child: Text(_myMemberName,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  // 不用 textAlign.end：长名被 ellipsis 截断后
                                                  // Text 盒子=约束宽度，比截断文字略宽，end 对齐
                                                  // 会把富余量挤到左侧（胶囊左边缘空一截）。
                                                  // 默认 start 对齐，富余量落在"…"右侧，几乎不可见。
                                                  // 与对方一侧同号（15），两侧视觉对称
                                                  style: const TextStyle(
                                                      fontSize: 15,
                                                      fontWeight: FontWeight.w500)),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  const SizedBox(height: 1),
                                  _statusLine(
                                    online: _ws?.connected.value ?? false,
                                    // 四态思维模型（老板 2026-10-08，与 TUI 同源）：
                                    // 灰=未连接服务 / 黄=连接中 / 绿=已连接 / 红=断线重连
                                    offlineColor:
                                        _ws == null ? Colors.grey : Colors.red,
                                    connecting:
                                        _ws?.status.value == WsStatus.connecting,
                                    sinceMs: _mySinceMs,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Tooltip(
                              // 状态条 tooltip 全量补齐（老板 2026-10-10）
                              message: l10n.chatPageMyAvatarTooltip,
                              child: _statusAvatar(
                                bytes: _myAvatarBytes,
                                gender: _myGender,
                                // 空头像：点它没有大图可看 → 直接进换头像流程；
                                // 有头像：开大图（「更换头像」+「应用于本机所有
                                // 秘境」+「保存」图标，三处一致）
                                onTap: _myAvatarBytes == null
                                    ? () => unawaited(_showAvatarUpload())
                                    : () => unawaited(_showAvatarFullscreen(
                                        _myAvatarBytes!,
                                        allowReplace: true,
                                        saveName: _myMemberName)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 离线提示条（老板 2026-09-13）：只在"有还没确认的消息 **且** 连接有问题"
          // 时出现——正常发送时 pending 只存在百毫秒，不会闪。
          _buildOfflineHint(),
          Expanded(
            // Builder：_displayMessages 只算一次给 itemCount/itemBuilder 共用
            // （getter 每次访问都重建过滤列表，逐项调用会 O(n²)）
            child: Builder(
              builder: (context) {
                final displayMessages = _displayMessages;
                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(12),
                  itemCount: displayMessages.length,
                  itemBuilder: (context, i) {
                    final m = displayMessages[i];
                final mine = m.sender == 'me';
                // 发送者 memberId：信封字段优先，缺失（旧版附件/语音消息）用通道映射兜底。
                // 群聊一期：group 空间的**气泡配色**与**发送者名字**都要它，不能只在
                // 头像开关打开时才算（配色永远按 member 走）。
                final senderMemberId =
                    m.env.senderMemberId ?? _repo.memberIdOfEntrance(m.env.senderEntranceId);
                return Align(
                  alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 气泡旁的头像：duo 默认**关**（状态条里已有双方头像，逐条再挂
                      // 一个是重复——老板 2026-09-26）；**group 默认开**（"这句是谁
                      // 说的"必须逐条标注，注释里预留的场景已到来）。
                      // `--dart-define=SHOW_MESSAGE_AVATARS=true` 可强制开（含 duo）。
                      if (_showMessageAvatars && !mine) ...[
                        // 头像 + **头像下方的发言人名字**（群聊，老板 2026-10-05）：
                        // 名字从气泡内搬到这里——气泡里只剩内容，读起来更像"对话"。
                        // 列宽固定 = 头像直径（[kMessageAvatarDiameter]），所以名字再长
                        // 也只在**自己那一列**里省略，不会把气泡推歪。
                        SizedBox(
                          width: kMessageAvatarDiameter,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _MessageAvatar(
                                  memberId: senderMemberId,
                                  server: effectiveServer,
                                  api: widget.api,
                                  radius: kMessageAvatarDiameter / 2,
                                  onSaveImage: (bytes) => _saveAvatarImage(
                                      _senderNameOf(senderMemberId), bytes)),
                              // 群空间才标名字（duo 两人世界里只有"对方"，状态条已写着）；
                              // 墓碑消息（已删除/焚毁）不标——正文都没了，署名无意义
                              if (_isGroup && !m.deleted) ...[
                                const SizedBox(height: 2),
                                Text(
                                  _senderNameOf(senderMemberId),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  // 与原来气泡内那行同一套颜色规则：gradient 主题下
                                  // 聊天区是深色粉蓝渐变，要白字才看得见
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: _uiStyle == 'gradient'
                                        ? Colors.white
                                        : Colors.grey.shade700,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Clickable(
                        // 仅跳转目标项持有 GlobalKey（ensureVisible 定位用）；
                        // 其余项无 key，不阻碍懒构建回收
                        key: m.env.messageId == _jumpTargetId ? _jumpTargetKey : null,
                        // 长按菜单挂**整条气泡**（老板 2026-10-08 定：气泡任意位置都能
                        // 开菜单）。唯一例外是顶栏（时间/快捷动作/沙漏）——它在内层
                        // **吸收**掉长按，见下面那处 GestureDetector。
                        // 墓碑消息仅当可撤回时开菜单（老板 2026-10-10：本地墓碑不
                        // 影响服务端行，未送达的仍可撤）
                        onLongPress: _messageHasActions(m)
                            ? () => _showMessageActions(m)
                            : null,
                        child: AnimatedContainer(
                          // 高亮渐变节奏（老板要求 2026-09-10）：渐变成橘黄 1.5s、
                          // 停留 0s、渐变回去 1.5s——duration 1500ms 管渐变
                          duration: const Duration(milliseconds: 1500),
                          curve: Curves.easeOut,
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          // 气泡最大宽度 = 屏幕 75%：长文本在此约束下自动换行
                          // （否则 Row(min) 给 Text 无界宽度 → 长消息挤在一行溢出屏幕）
                          constraints: BoxConstraints(
                              maxWidth: MediaQuery.sizeOf(context).width * 0.75),
                          decoration: BoxDecoration(
                            // 气泡底色按发言人性别：男天蓝 / 女品牌粉（老板要求 2026-09-09）；
                            // 跳转目标短暂高亮背景改为显眼橘黄 #FF9800（老板要求
                            // 2026-09-10：不撞任何性别气泡色系；只换背景色、尺寸
                            // 不变——边框方案实测闪烁期间气泡尺寸变化，已弃用）
                            color: m.env.messageId == _highlightMessageId
                                ? const Color(0xFFFF9800)
                                // 群聊一期：group 空间按发送者 member 取哈希色板
                                // （duo 走原来的性别/槽位规则，一字未改）
                                : _bubbleColor(mine: mine, senderMemberId: senderMemberId),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: DefaultTextStyle.merge(
                            // gradient 深色气泡下文字/图标改白色（醒目，老板要求）；
                            // plain 浅色气泡不合并颜色（保持默认深色文字/图标）。
                            // 正文字号 [kMessageFontSize]（老板 2026-09-15：原来跟着
                            // Flutter 默认 14 走，比微信小一圈）——气泡内所有跟随默认
                            // 样式的文字（正文、文件名）一起变大；时间戳/焚毁标签/
                            // 引用块各自显式设了小字号，不受影响
                            style: TextStyle(
                                color: _uiStyle == 'gradient' ? Colors.white : null,
                                fontSize: kMessageFontSize),
                            child: IconTheme.merge(
                              data: IconThemeData(
                                  color: _uiStyle == 'gradient' ? Colors.white : null),
                              child: Column(
                                crossAxisAlignment: mine
                                    ? CrossAxisAlignment.end
                                    : CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // 发言人名字**不在气泡里**（老板 2026-10-05）：
                                  // 搬到气泡左侧、头像下方（见上面那处 SizedBox）。
                                  // 气泡内只留内容本身，读起来更像"对话"。
                                  //
                                  // 顶栏**吸收长按**：不让它冒泡到外层气泡的长按菜单
                                  // （老板 2026-10-08：长按气泡任意位置都该开菜单，
                                  // 唯独顶栏不行——桌面长按顶栏按钮会误开菜单；手机
                                  // 长按顶栏该出 tooltip，Tooltip 在更内层，手势竞技场
                                  // 里本来就赢，这里只挡"没有 tooltip 的空白"）。
                                  // opaque = 整条顶栏矩形都挡，连图标之间的间隙也不漏。
                                  GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onLongPress: () {},
                                    child: Padding(
                                      padding: const EdgeInsets.only(bottom: 2),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          // 自己消息：发送状态小标放在**时间前面**（老板
                                          // 2026-09-12：原来放末尾，会被阅后即焚标记挤到
                                          // 中间/后面，无法一眼看出"这条发出去没"）。
                                          // 墓碑消息（删除/焚毁）**同样显示**（老板
                                          // 2026-09-13）：删除/焚毁只是"在本设备隐藏正文"，
                                          // 不影响消息在服务器与对方的路径——所以状态与
                                          // 点按重发都该照旧可用。
                                          if (mine) ...[
                                            _buildSendStatusIcon(m),
                                            const SizedBox(width: 4),
                                          ],
                                          Text(_messageTimeLabel(m),
                                              style: TextStyle(
                                                  fontSize: 11,
                                                  color: _uiStyle == 'gradient'
                                                      ? Colors.white70
                                                      : Colors.grey)),
                                          // 快捷动作（老板 2026-10-02）：时间后、焚毁
                                          // 指示前——引用 + 拷贝（拷贝仅文字消息）。
                                          // 点击直接执行，不用进长按菜单；墓碑消息
                                          // 无内容可操作，不显示
                                          if (!m.deleted) ...[
                                            // 时间戳 → 引用图标：比动作间间隔多 4（补齐
                                            // 图标自身 padding 造成的不对称，老板 2026-10-02）
                                            const SizedBox(width: 6),
                                            _bubbleQuickAction(
                                              m,
                                              icon: Icons.format_quote,
                                              label: l10n.chatPageActionQuote,
                                              onTap: () {
                                                setState(() => _quoteTarget = m);
                                                _inputFocusNode.requestFocus();
                                              },
                                            ),
                                            const SizedBox(width: 2),
                                            // 拷贝仅文字消息；媒体消息（图片/视频/音频/
                                            // 文件）换成「保存」——直接写本机，同长按
                                            // 菜单「保存」（老板 2026-10-02）
                                            if (m.env.type == 'text')
                                              _bubbleQuickAction(
                                                m,
                                                // 拷贝字形竖向占 20/24，比邻居
                                                // save_alt(18/24)/format_quote(10/24)
                                                // 天然高一档——缩 1 与邻居光学对齐
                                                //（2026-10-08 老板反馈：拷贝按钮偏高）
                                                icon: Icons.copy_outlined,
                                                iconSize: 15,
                                                label: l10n.chatPageCopy,
                                                onTap: () async {
                                                  await Clipboard.setData(
                                                      ClipboardData(text: m.plaintext.trim()));
                                                  if (!mounted) return;
                                                  _notice(
                                                      this.context, l10n.setupCreateCopied);
                                                },
                                              ),
                                            if (m.attachment != null)
                                              _bubbleQuickAction(
                                                m,
                                                icon: Icons.save_alt,
                                                label: l10n.chatPageActionSave,
                                                onTap: () => _saveAttachment(m),
                                              ),
                                          ],
                                          if (m.deleted) ...[
                                            // 墓碑（2026-10-11）：按来路显示图标——
                                            // 撤回→撤回图标、本机删除→删除图标
                                            //（它们的沙漏+时长并未真正起作用，
                                            // 与真焚毁的消息区分开）；焚毁到期→
                                            // 沙漏（不带时长文字）。**不依赖是否
                                            // 设过阅后即焚**——此前整块包在
                                            // expiresAt 条件里，未设焚毁的撤回/
                                            // 删除消息出不来图标（老板实测）。
                                            // 纯显示不可点。前面多补 4（老板
                                            // 2026-10-02）：活消息那路沙漏带
                                            // 4 padding，墓碑裸排会窄一截
                                            const SizedBox(width: 4),
                                            if (m.deletedKind == 'recall' ||
                                                m.deletedKind == 'delete')
                                              Icon(
                                                m.deletedKind == 'recall'
                                                    ? Icons.undo_outlined
                                                    : Icons.delete_outline,
                                                size: 14,
                                                color: _uiStyle == 'gradient'
                                                    ? Colors.white70
                                                    : Colors.grey,
                                              )
                                            else
                                              // 焚毁到期墓碑只留沙漏（2026-10-11
                                              // 老板：不显示具体时长了——沙漏
                                              // 已经漏完，时长数字没有意义）。
                                              // 颜色与相邻删除/撤回图标一致
                                              //（沙漏本继承 IconTheme，偏深）
                                              IconTheme(
                                                data: IconThemeData(
                                                  color: _uiStyle == 'gradient'
                                                      ? Colors.white70
                                                      : Colors.grey,
                                                ),
                                                child: _BurnHourglass(
                                                    burned: true, size: 14),
                                              ),
                                          ] else if (m.expiresAt != null) ...[
                                            const SizedBox(width: 4),
                                            // 沙漏=阅后即焚倒计时（老板 2026-09-12，
                                            // 替代原来的时钟图标，避免与发送中混淆）。
                                            // 可点（老板 2026-10-02）：点击进档位设置
                                            // 弹层（同长按菜单「阅后即焚」）
                                            Material(
                                              color: Colors.transparent,
                                              // 长条控件（沙漏+时长）用圆角矩形背景，
                                              // 不跟快捷图标走圆形（老板 2026-10-02）
                                              borderRadius: BorderRadius.circular(12),
                                              clipBehavior: Clip.antiAlias,
                                              child: Tooltip(
                                                // 与相邻的引用/拷贝/保存圆钮一样给 tooltip
                                                // （老板 2026-10-08；此前只有这处没有）
                                                message: l10n.chatPageActionBurn,
                                                child: InkWell(
                                                  mouseCursor: SystemMouseCursors.click,
                                                  // 悬浮/点击背景同快捷动作/状态栏图标
                                                  hoverColor:
                                                      Colors.black.withValues(alpha: 0.05),
                                                  highlightColor:
                                                      Colors.black.withValues(alpha: 0.08),
                                                  onTap: () => _setMessageBurn(m),
                                                  child: SizedBox(
                                                    // 与引用/拷贝/保存圆钮**同高**
                                                    // （老板 2026-10-08：原来被文字撑高一截）
                                                    height: _bubbleTimeRowControlHeight,
                                                    child: Padding(
                                                      padding: const EdgeInsets.symmetric(
                                                          horizontal: 4),
                                                      child: Row(
                                                        mainAxisSize: MainAxisSize.min,
                                                        children: [
                                                          _BurnHourglass(
                                                              burned: false,
                                                              size: 14),
                                                          const SizedBox(
                                                              width: 2),
                                                          // 时钟标签：焚毁时刻 HH:MM（精确到分钟，老板 2026-10-09）
                                                          Text(
                                                              _burnTagLabel(m.expiresAt,
                                                                      m.burnAfterSeconds,
                                                                      manual: m.burnManual),
                                                              style: TextStyle(
                                                                  fontSize: 11,
                                                                  color: _uiStyle == 'gradient'
                                                                      ? Colors.white70
                                                                      : Colors.grey)),
                                                        ],
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                          // 菜单「...」（老板 2026-10-12）：时间行
                                          // 最右侧（沙漏时长右边），单击 = 长按气泡
                                          // 打开消息菜单弹层；与气泡长按同条件
                                          //（_messageHasActions：墓碑仅可撤回时给）。
                                          if (_messageHasActions(m)) ...[
                                            const SizedBox(width: 2),
                                            _bubbleQuickAction(
                                              m,
                                              icon: Icons.more_horiz,
                                              // 「更多操作」：区别于汉堡菜单的
                                              // chatPageMenuMore（"菜单"），这个
                                              // 指消息操作菜单（老板 2026-10-12）
                                              label: l10n.chatPageMsgMoreActions,
                                              onTap: () => _showMessageActions(m),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                  // 墓碑消息（已删除/已焚毁）：只保留时间（+时钟+时长）
                                  // 记录，正文与引用块隐藏（老板决策 2026-09-09）
                                  if (!m.deleted) ...[
                                    _buildMessageContent(m),
                                    // 被引用的消息放在正文下方（老板要求 2026-09-09：
                                    // 引用块应在消息正文下面，而不是上面）
                                    // 点击引用卡跳转到原消息位置（老板要求 2026-09-10）
                                    if (m.quote != null)
                                      Clickable(
                                        onTap: () => _jumpToMessage(
                                            m.quote!['messageId'] as String? ?? ''),
                                        borderRadius: BorderRadius.circular(8),
                                        child: Container(
                                          margin: const EdgeInsets.only(top: 4),
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 8, vertical: 4),
                                          constraints: BoxConstraints(
                                              maxWidth: MediaQuery.sizeOf(context)
                                                      .width *
                                                  0.55),
                                          decoration: BoxDecoration(
                                            color: _uiStyle == 'gradient'
                                                ? Colors.white12
                                                : Colors.black
                                                    .withValues(alpha: 0.06),
                                            borderRadius: BorderRadius.circular(8),
                                          ),
                                          child: _buildQuoteBlockContent(m.quote!),
                                        ),
                                      ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (_showMessageAvatars && mine) ...[
                        const SizedBox(width: 6),
                        // 自己的头像也给「更换头像」「应用于本机所有秘境」
                        // （老板 2026-10-17：气泡旁/状态条/「我的资料」三处
                        // 同一份"我的头像全屏"）；「保存」人人都有
                        _MessageAvatar(
                            memberId: senderMemberId,
                            server: effectiveServer,
                            api: widget.api,
                            radius: kMessageAvatarDiameter / 2,
                            onReplaceAvatar: () => unawaited(_showAvatarUpload()),
                            onApplyAllSpaces: _hasMultipleSpaces
                                ? (bytes) => _applyAvatarAllSpaces(bytes)
                                : null,
                            onSaveImage: (bytes) => _saveAvatarImage(
                                _senderNameOf(senderMemberId), bytes)),
                      ],
                    ],
                  ),
                );
              },
            );
              },
            ),
          ),
          SafeArea(
            // 输入栏锚定在屏幕底部：必须去掉顶部 inset——extendBodyBehindAppBar 下
            // Scaffold 给 body 的 MediaQuery.padding.top 含「状态栏 + 工具栏」高度
            // （真机约 115px），SafeArea 默认会把它全垫在输入栏上方，造成约 2 个
            // 输入框高度的渐变空隙、消息列表被截断（老板实测 2026-09-09）。
            // 底部 inset 保留（Home 条防遮挡）。
            top: false,
            child: Container(
              key: const ValueKey('chatPageInputBar'),
              // gradient 风格：输入栏不顶左右两头——悬浮圆角白条（渐变从两侧/底部
              // 透出，同向导白卡在渐变上的层次）；plain 风格保持原样（全宽透明）
              color: _uiStyle == 'gradient' ? null : Colors.transparent,
              decoration: _uiStyle == 'gradient'
                  ? BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x26000000), // 柔和投影（渐变上浮起）
                          blurRadius: 12,
                          offset: Offset(0, 4),
                        ),
                      ],
                    )
                  : null,
              padding: _uiStyle == 'gradient'
                  ? const EdgeInsets.fromLTRB(12, 4, 12, 8)
                  : const EdgeInsets.all(8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_quoteTarget != null) _buildQuoteBanner(_quoteTarget!),
                  Row(
                    children: [
                      // 附件：拍照 / 相册（图像、视频共用入口）
                      IconButton(
                        onPressed: _showAttachmentSheet,
                        icon: const Icon(Icons.add_circle_outline),
                      ),
                      // 语音入口：点按=切提示态/回文字态；长按=直接开始录音（与长按录音条等价）
                      Clickable(
                        onLongPressStart: (_) => _startVoice(),
                        onLongPressEnd: (_) => _stopVoice(),
                        child: IconButton(
                          icon: Icon(_voiceEntryIcon(),
                              color:
                                  _inputMode == _InputMode.recording ? Colors.green : null),
                          onPressed: _onVoiceEntryTap,
                        ),
                      ),
                      Expanded(
                        // Stack：文字输入框始终占位（行高恒定，切换录音条时按钮不浮动），
                        // 录音/预览时录音条 Positioned.fill 覆盖其上（与输入框严格同高）
                        child: Stack(
                          children: [
                            // 录音条覆盖时完全隐藏输入框（maintainSize 保持占位高度，
                            // 行高/按钮位置不变；避免圆角录音条透出输入框边角）
                            Visibility(
                              visible: _inputMode == _InputMode.text,
                              maintainState: true,
                              maintainSize: true,
                              maintainAnimation: true,
                              child: TextField(
                                controller: _input,
                                focusNode: _inputFocusNode,
                                // 桌面端自动聚焦（老板 2026-10-12 粘贴功能配套）：
                                // Cmd/Ctrl+V 走焦点链分发——新开聊天页若输入框无
                                // 焦点，页面级 CallbackShortcuts 收不到按键，粘贴
                                // 会"没反应"（实测五种焦点状态定的方案）。桌面聊天
                                // 客户端打开会话即聚焦输入框也是惯例（Discord 同款）；
                                // 移动端不抢焦点（会弹软键盘）。
                                autofocus: _pasteShortcutSupported,
                                // 多行输入框：文字到达宽度后自动折行，输入框随之增高，
                                // 最多 8 行；超过 8 行不再增高，转为内部纵向滚动
                                // （老板要求 2026-09-13：原先单行 + 横向滚动体验差）。
                                // 非文字态（录音提示/录音/预览）把隐藏输入框按单行布局，
                                // 录音条 Positioned.fill 才不会跟着草稿高度撑到 8 行高
                                // （草稿保留在 controller 里，切回文字态自动恢复增高）
                                minLines: 1,
                                maxLines: _inputMode == _InputMode.text ? 8 : 1,
                                // 多行折行；回车键仍为「发送」（键盘右下角显示「发送」，
                                // iOS 按系统语言本地化），不插入换行——与微信一致
                                keyboardType: TextInputType.multiline,
                                textInputAction: TextInputAction.send,
                                decoration: InputDecoration(
                                  hintText: l10n.chatPageInputHint,
                                  isDense: true,
                                  // 边框到文字的间距：主题里默认 16/16（那是给
                                  // 口令、名字这类表单用的，字段少、留白宽好读），
                                  // 聊天输入框是"反复打字、希望一行多放字"的场景，
                                  // 左右收到 12（左右各省 4px），垂直同步收到 12——
                                  // 顺带让输入框高度更贴近两侧按钮（老板 2026-09-26）
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 12),
                                ),
                                // 回车发送后焦点回到输入框（键盘完成动作默认失焦——补回聚焦）
                                onSubmitted: (_) {
                                  _send();
                                  _inputFocusNode.requestFocus();
                                },
                                // 发送后键盘常驻遮挡消息流；点按输入框以外的任意处
                                // （消息列表/空白/其他控件）收起键盘（老板要求 2026-09-12）。
                                // 移动端默认不动 focus，需显式 unfocus。
                                // **桌面端不收起**：桌面没有软键盘要收，且失焦后
                                // Cmd/Ctrl+V 粘贴快捷键（焦点链上的 CallbackShortcuts）
                                // 就收不到按键了——点消息列表不该让粘贴失灵
                                // （老板 2026-10-12 粘贴功能配套）。
                                onTapOutside: (_) {
                                  if (!_pasteShortcutSupported) {
                                    FocusManager.instance.primaryFocus
                                        ?.unfocus();
                                  }
                                },
                              ),
                            ),
                            if (_inputMode != _InputMode.text)
                              // 长按手势挂在常驻的 GestureDetector 上：提示态长按开始录音，
                              // 进入录音态后此层不重建，松手能正常触发停止；预览态由
                              // _startVoice 直接忽略（长按不重录，防误触冲掉刚录好的一条）
                              Positioned.fill(
                                child: Clickable(
                                  onLongPressStart: (_) => _startVoice(),
                                  onLongPressEnd: (_) => _stopVoice(),
                                  child: _buildVoiceBar(),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      // 发送键：文字态发文字；预览态发录音；提示/录音态禁用（无可发内容）
                      // 纸飞机**朝上**（老板 2026-09-14）——消息流在输入框上方，朝上才
                      // 表达"发进上面的消息流"；Material 的 Icons.send 本身朝右，
                      // 逆时针转 90° 摆正。Transform 不改变占位，按钮布局不变
                      IconButton.filled(
                        onPressed: _inputMode == _InputMode.preview
                            ? _sendVoice
                            : (_inputMode == _InputMode.text ? _send : null),
                        icon: Transform.rotate(
                          angle: -math.pi / 2,
                          child: const Icon(Icons.send),
                        ),
                      ),
                    ],
                  ),
                  // 表情面板：展开时占据输入行下方（键盘已收起），可连续点选插入
                  if (_emojiPanelOpen)
                    EmojiPanel(
                      onEmojiSelected: _insertText,
                      onBackspace: _deleteBackward,
                      onDismiss: _closeEmojiPanel,
                    ),
                ],
              ),
            ),
          ),
              ],
            ),
          ),
          // 桌面端拖入文件的高亮浮层（覆盖整页，松手即发送）
          if (_fileDragHover) const Positioned.fill(child: _DropHintOverlay()),
        ],
      ),
    );
    // 前台无操作锁屏（老板 2026-10-17）：整页套两层（包在最内层，后面的
    // CallbackShortcuts/DropTarget 不消费指针事件，都能正常收到）。
    // ① Listener：点/滑/拖都在 onPointerDown 抓到 → 重排 idle 计时器。
    //    打字由输入框控制器监听兜底（软键盘在 Flutter 视图外，点不到）。
    // ② 通知：滚轮/触控板/惯性滚动不产生 pointer down，用 ScrollNotification
    //    兜住（持续滚动看消息的用户不该被锁）。
    // 「在栈顶」守卫不在 build：用 ModalRoute.isCurrent（见 _fireIdleLock）。
    page = NotificationListener<ScrollUpdateNotification>(
      onNotification: (_) {
        _onScrollInteraction();
        return false;
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _onPointerInteraction(),
        child: page,
      ),
    );
    // 桌面端：整页套一个投递区，从访达/资源管理器拖文件进来即发送；移动端不挂
    // （无此交互，且 desktop_drop 的 Android 实现是 preview，不挂更稳）。
    if (!_fileDropSupported) return page;
    // 桌面端：Cmd/Ctrl+V 粘贴快捷通道（与附件面板「粘贴」入口同汇到
    // _pasteFromClipboard；移动端没有键盘这一说，只走面板入口）。
    // CallbackShortcuts 内部就是一层 canRequestFocus:false + skipTraversal 的
    // Focus——不抢焦点、不进 Tab 遍历，只在页面内任意控件（含输入框）持焦时
    // 沿焦点链收到按键。匹配即消费：文字分支由 _pasteFromClipboard 自己插，
    // WidgetsApp 默认粘贴不会跑。**对话框/弹层打开时本层自然失活**——焦点已
    // 移到上层路由，不是本 Shortcuts 的后代（实测）。
    if (_pasteShortcutSupported) {
      page = CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          SingleActivator(
            LogicalKeyboardKey.keyV,
            control: !Platform.isMacOS, // Win/Linux 用 Ctrl
            meta: Platform.isMacOS, // macOS 用 Cmd
          ): () => unawaited(_pasteFromClipboard()),
        },
        child: page,
      );
    }
    return DropTarget(
      onDragEntered: (_) => setState(() => _fileDragHover = true),
      onDragExited: (_) => setState(() => _fileDragHover = false),
      onDragDone: (detail) {
        setState(() => _fileDragHover = false);
        unawaited(_sendDroppedFiles(detail.files));
      },
      child: page,
    );
  }
}

/// 拖入文件时覆盖整页的提示浮层（松手即发送）。
class _DropHintOverlay extends StatelessWidget {
  const _DropHintOverlay();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // IgnorePointer：只做视觉提示，不拦截指针（拖放命中在最外层的 DropTarget）
    return IgnorePointer(
      child: ColoredBox(
        color: const Color(0x66000000),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: const [
                BoxShadow(
                    color: Color(0x33000000), blurRadius: 24, offset: Offset(0, 8)),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.move_to_inbox_outlined,
                    size: 48, color: Color(0xFF3BAFFD)),
                const SizedBox(height: 12),
                Text(l10n.chatPageDropHint,
                    style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF33415A))),
                const SizedBox(height: 4),
                Text(l10n.chatPageDropHintSub,
                    style: const TextStyle(fontSize: 13, color: Color(0xFF5C6B82))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 补设/重设启动锁弹窗（StatefulWidget）：controller 生命周期随 State 卸载同步释放，
/// 避免"点设置后 dispose 竞态"（TextField 卸载动画中向已销毁 controller 加 listener
/// → debugAssertNotDisposed / _dependents.isEmpty 红屏，2026-09-05 真机定位）。
class _SetLockDialog extends StatefulWidget {
  const _SetLockDialog({
    required this.payload,
    required this.db,
    required this.hasPin,
  });

  final AppLockPayload payload;
  final LocalDatabase db;

  /// 打开弹窗**之前**读好的"本机是否已设锁屏码"（开弹窗前读、不在弹窗里异步读，
  /// 避免毫秒级窗口里验证被跳过）。
  final bool hasPin;

  @override
  State<_SetLockDialog> createState() => _SetLockDialogState();
}

class _SetLockDialogState extends State<_SetLockDialog> {
  final _oldCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  String? _error;
  // 已设锁屏码 → 出「当前锁屏码」验证框（老板 2026-09-14）
  bool get _hasPin => widget.hasPin;
  bool _busy = false; // 当前锁屏码校验中（Argon2id）：防连点重复提交
  // 锁屏时长（前台闲置锁与后台锁共用，老板 2026-10-18 定）：对数刻度轴
  // （30 秒~30 分钟，仿阅后即焚 burn_duration_sheet）。initState 异步读持久化值
  // 换成轴位置；读回前按默认 30 秒渲染（同 _loadUiStyle 套路）。
  // _initialSeconds = 打开弹窗时的档位，提交时判"是否真改过"。
  double _axisT = 0.0; // 轴位置 t∈[0,1]（对数刻度）
  int? _initialSeconds;

  /// 轴位置 → 当前档位（秒）。档位吸附：≤1 分钟吸附 10 秒（20/30/…/60 都能停），
  /// >1 分钟吸附整分钟——拖出来永远是 "30 秒 / 5 分钟" 这样的干净值，超过 1 分钟
  /// 不显示秒数（与焚毁轴同策略）。
  static int _lockSecondsFromT(double t) {
    final raw = kLockMinSeconds *
        math.pow(kLockMaxSeconds / kLockMinSeconds, t.clamp(0.0, 1.0));
    final snapped = raw <= 60 ? (raw / 10).round() * 10 : (raw / 60).round() * 60;
    return snapped.clamp(kLockMinSeconds, kLockMaxSeconds);
  }

  /// 秒数 → 轴位置（对数刻度；越界先钳）。
  static double _lockTFromSeconds(int seconds) {
    final clamped = seconds.clamp(kLockMinSeconds, kLockMaxSeconds);
    return math.log(clamped / kLockMinSeconds) /
        math.log(kLockMaxSeconds / kLockMinSeconds);
  }

  int get _axisSeconds => _lockSecondsFromT(_axisT);

  // —— 弹窗宽度策略（老板 2026-10-18）——
  // 手机版：与其它弹窗一致——Dialog 默认 insetPadding（左右各 40），宽度吃满
  // 可用宽度。minWidth 360 是兜底：本弹窗没有长文案，内容 intrinsic 很窄，
  // 不兜底会缩到 Dialog 默认 minWidth 280，比邻居们还窄（老板 2026-10-18
  // 早前嫌过的"太窄"正是这么来的）。
  // 桌面版：再放宽一档（屏宽 ≥ 600 时 min/max 都取 480；老板 2026-10-19：560 太宽，
  // 再缩小一点）。轴下标注的定位几何依赖这套值（见 [_setLockAxisWidth]），改宽策略要同步。
  static const double _kDialogInsetH = 40;
  static const double _kDialogMinWidthPhone = 360;
  static const double _kDialogWidthDesktop = 480;
  static const double _kDialogWideBreakpoint = 600;
  // 内容/卡片的水平边距：轴宽几何要从弹窗宽里减掉它们（两处 padding 用同常量，防漂移）
  static const double _kDialogContentPadH = 24;
  static const double _kCardPadH = 14;

  /// 分组卡片内宽（轴下标注 [_lockAxisLabels] 定位用）。
  /// 弹窗宽 = min(屏幕可用宽, minWidth)：内容 intrinsic 远小于 minWidth，Dialog 的
  /// IntrinsicWidth+tighten 正好把内容定到 minWidth；可用宽更小则吃满可用宽
  /// （BoxConstraints.enforce 会把 minWidth clamp 到可用宽，不会溢出）。
  double _setLockAxisWidth(double screenWidth, double dialogMinWidth) {
    final dialogWidth = math.min(screenWidth - 2 * _kDialogInsetH, dialogMinWidth);
    return dialogWidth - 2 * _kDialogContentPadH - 2 * _kCardPadH;
  }
  // 已设锁屏码时的标签页：0=更换锁屏码，1=清除锁屏码（老板 2026-10-18 定，
  // 标题行双标签取代上一轮的「清除锁屏码」文字按钮；未设 PIN 时无标签页）。
  int _setLockTab = 0;

  @override
  void initState() {
    super.initState();
    // 更换场景确认行的显隐跟随「新 PIN」行是否有内容（老板 2026-10-19）：TextField
    // 自己改文本不会重建弹窗，这里用 controller 监听补一次 setState
    _pinCtrl.addListener(() {
      if (mounted) setState(() {});
    });
    AppLockService(widget.db).loadLockSeconds().then((value) {
      if (!mounted) return;
      setState(() {
        _axisT = _lockTFromSeconds(value);
        // 吸附后的档位作初始值：老库存值（如 45 秒这种非整档）不会因归一化
        // 被误判成"改过"而白写一次盘
        _initialSeconds ??= _axisSeconds;
      });
    });
  }

  @override
  void dispose() {
    _oldCtrl.dispose();
    _pinCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  /// 验证当前锁屏码并取出整包 Vault（修改/清除 PIN 共用）。失败时已置 _error，
  /// 返回 null（含"没输当前锁屏码"——直接红字提示，不发后台）。
  Future<VaultPayload?> _verifyOldPin() async {
    final l10n = AppLocalizations.of(context)!;
    if (_oldCtrl.text.isEmpty) {
      setState(() => _error = l10n.chatPageSetLockOldRequired);
      return null;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final vault = await AppLockService(widget.db).unlockVault(_oldCtrl.text);
      if (!mounted) return null;
      setState(() => _busy = false);
      return vault;
    } on AppLockLockedException catch (e) {
      if (!mounted) return null;
      setState(() {
        _busy = false;
        _error = l10n.lockPageTooManyAttempts(e.remainingSeconds);
      });
    } on AppLockException {
      if (!mounted) return null;
      setState(() {
        _busy = false;
        _error = l10n.setPinDialogOldWrong;
      });
    } catch (e) {
      if (!mounted) return null;
      setState(() {
        _busy = false;
        _error = l10n.setPinDialogSetupFailed('$e');
      });
    }
    return null;
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    if (_busy) return;
    // 每次点主按钮：先清掉上一轮残留的红字，再做本轮检测（老板 2026-10-19）——
    // 否则旧错误横在页面下方，容易误当成新提交的结果
    setState(() => _error = null);
    final pin = _pinCtrl.text;
    final confirm = _confirmCtrl.text;
    // 两框都空 = 不改 PIN（老板 2026-10-18 方案二：原先"两空=清空"的隐式语义
    // 会和"只想调自动锁屏时长"撞车——时长改成可调后，空着提交反而把 PIN 清掉。
    // 清空改由弹窗内显性「清除锁屏码」按钮承担，见 _clearPin）。
    final changePin = pin.isNotEmpty || confirm.isNotEmpty;
    // async gap 前同步捕获 overlay（根 Overlay 在路由 pop 后仍存活）
    final overlay = Overlay.of(context, rootOverlay: true);
    // 时长是否真的动过（初始值还没异步读回时不写盘）
    final secondsChanged = _initialSeconds != null && _axisSeconds != _initialSeconds;
    Future<void> saveSecondsIfChanged() async {
      if (secondsChanged) {
        await AppLockService(widget.db).saveLockSeconds(_axisSeconds);
      }
    }

    if (changePin) {
      // 新 PIN 非空必须先行校验（老板 2026-10-19）：只填了确认框、新 PIN 空着
      // 时，落进下面的 digitsOnly/length 校验会报"只能是数字/太短"这种不着边的
      // 红字——真正的错误是"新 PIN 没填"。统一报 chatPageSetLockPinRequired。
      if (pin.isEmpty) {
        setState(() => _error = l10n.chatPageSetLockPinRequired);
        return;
      }
      // 已设锁屏码：修改必须先验证当前锁屏码（老板 2026-09-14 定）——
      // 否则"清空 → 重设"两步即可绕过验证；手机被他人短暂拿到就能装一个自己的 PIN。
      // 验证走 AppLockService.unlockVault（与锁屏同一套防爆破：连错 5 次锁 30 秒）。
      //
      // 顺带把整包 Vault 取出来：多空间下"改锁屏码"必须把**全部空间**一起搬
      // （重加密整包）。已有的明文包在 PIN 模式下按设计不存在，不给整包就只能写进
      // 当前这一个空间、静默丢掉其他秘境——见 AppLockService.setPin 的 existing 参数
      // （2026-10-06 模拟器实测的截断 bug）。
      VaultPayload? existingVault;
      if (_hasPin) {
        existingVault = await _verifyOldPin();
        if (existingVault == null) return; // 校验失败已在表单内置 _error
      }
      // 新旧码相同 → 红字提示，不真去设置（老板 2026-09-14）。放在旧码校验之后：
      // 先验完旧码再比，避免把"你猜对了当前锁屏码"当成提示漏出去
      if (_hasPin && pin == _oldCtrl.text) {
        setState(() => _error = l10n.chatPageSetLockSameAsOld);
        return;
      }
      if (!AppLockService.isPinDigitsOnly(pin)) {
        setState(() => _error = l10n.setPinDialogPinDigitsOnly);
        return;
      }
      if (pin.length < AppLockService.pinMinLength) {
        setState(() => _error = l10n.setPinDialogPinTooShort);
        return;
      }
      if (pin != confirm) {
        setState(() => _error = l10n.setPinDialogPinMismatch);
        return;
      }
      // 设置/重设不再弹二次确认（老板 2026-09-14：新码/确认两栏已足够，多一次确认多余）
      try {
        await AppLockService(widget.db).setPin(pin, payload: widget.payload, existing: existingVault);
        await saveSecondsIfChanged();
        if (!mounted) return;
        Navigator.of(context).pop(true); // true = 设置成功（菜单刷新「PIN: 已设置」）
        // 提示带上本次生效的自动锁屏时长（老板 2026-10-19：clockPageSetLockDone
        // 加 {duration} 占位）；未动过时长时就是弹窗读回的当前档位
        showTopNoticeOn(overlay,
            l10n.chatPageSetLockDone(_formatLockSeconds(_axisSeconds, l10n)),
            extraTop: kNoticeExtraTopBelowStatusBar);
      } catch (e) {
        if (!mounted) return; // 弹窗可能已被关闭（barrier/返回），避免 setState on disposed
        setState(() => _error = l10n.setPinDialogSetupFailed('$e'));
      }
      return;
    }

    // 不改 PIN：只提交时长。已设锁屏码时**改时长同样要验老 PIN**（老板 2026-10-19）：
    // 时长也是锁配置的一部分，手机被他人短暂拿到不该能把自动锁改到永不/极短；
    // 什么都没动就点「更改」→ 红字明示（不再静默返回）。
    if (!_hasPin) {
      // 未设锁屏码时两框全空就点「启用」＝什么都没设（老板 2026-10-19）：
      // 留在弹窗内红字要求输入——不想设的正确出路是「取消」按钮
      setState(() => _error = l10n.chatPageSetLockPinRequired);
      return;
    }
    if (!secondsChanged) {
      // 已设锁屏码、PIN 和时长都没动：红字明示"没有做任何修改"（老板 2026-10-19）
      setState(() => _error = l10n.chatPageSetLockNothingChanged);
      return;
    }
    // 时长动过：先验老 PIN（与改码同一套防爆破），通过才写盘
    final existingVault = await _verifyOldPin();
    if (!mounted) return;
    if (existingVault == null) return; // 校验失败已在表单内置 _error
    await AppLockService(widget.db).saveLockSeconds(_axisSeconds);
    if (!mounted) return;
    // 回 true：调用方要重载时长，菜单右侧的「已设置 · 时长」显示随弹窗关闭即时
    // 刷新（老板 2026-10-18）。通知条与改锁屏码本身同款（老板 2026-10-19）
    showTopNoticeOn(overlay,
        l10n.chatPageSetLockDone(_formatLockSeconds(_axisSeconds, l10n)),
        extraTop: kNoticeExtraTopBelowStatusBar);
    Navigator.of(context).pop(true);
  }

  /// 「清除锁屏码」标签页的执行（老板 2026-10-18）：验旧码 → 直接清除。
  /// 标签页本身就是警示页（警告文案 + 红底「清除」主按钮），不再叠二次确认弹窗；
  /// 但验旧码仍然必须（2026-09-14 定：否则手机被他人短暂拿到就能清锁再装自己的 PIN）。
  Future<void> _clearPin() async {
    final l10n = AppLocalizations.of(context)!;
    if (_busy) return;
    // 与 _submit 同口径：先清残留红字再做本轮检测（老板 2026-10-19）
    setState(() => _error = null);
    final existingVault = await _verifyOldPin();
    if (!mounted) return;
    if (existingVault == null) return; // 校验失败已在表单内置 _error
    // async gap 前同步捕获 overlay（根 Overlay 在路由 pop 后仍存活），避免 use_build_context_synchronously
    final overlay = Overlay.of(context, rootOverlay: true);
    try {
      await AppLockService(widget.db).savePlain(widget.payload, existing: existingVault);
      await AppLockService(widget.db).clearPackage();
      if (!mounted) return;
      Navigator.of(context).pop(true); // 菜单刷新「PIN: 未设置」
      showTopNoticeOn(overlay, l10n.chatPageSetLockCleared, extraTop: kNoticeExtraTopBelowStatusBar);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = l10n.setPinDialogSetupFailed('$e'));
    }
  }

  /// 锁屏时长档位 → 人读标签。超过 1 分钟只显示分钟、不显示秒数
  /// （老板 2026-10-18；轴上界 30 分钟，走不到小时）。
  String _formatLockSeconds(int seconds, AppLocalizations l10n) {
    if (seconds >= 60) return l10n.lockDurationMin(seconds ~/ 60);
    return l10n.lockDurationSecs(seconds);
  }

  /// 轴下的阶段性可点标注（老板 2026-10-18，仿阅后即焚轴）：20 秒（最左）/
  /// 1 分钟 / 5 分钟 / 20 分钟（最右），点了立刻把轴跳到该点。默认就带一层
  /// 淡背景色提示可点（与焚毁轴的标注同款：primary 6% 淡底 + InkWell 反馈）。
  ///
  /// 标签 x 用与 Slider thumb 完全相同的几何（`trackLeft + t × trackWidth`，
  /// 见 burn_duration_sheet._axisLabels 同款算法），保证对准刻度。
  ///
  /// **两个坑都踩过，别再踩**：
  /// 1. 宽度不量：AlertDialog 被 Dialog 包在 `IntrinsicWidth` 里，intrinsic 尺寸
  ///    计算会遍历整棵子树，子树中出现 LayoutBuilder 就抛
  ///    "LayoutBuilder does not support returning intrinsic dimensions"，
  ///    **整个弹窗直接打不开**（2026-10-18 实测）。所以轴宽由调用方按弹窗自身
  ///    几何算好传进来（[_setLockAxisWidth]），标注方法自己不再量。
  /// 2. [axisWidth] 必须与分组卡片的实际内宽一致：改 build() 里的
  ///    insetPadding / contentPadding 或卡片 padding 时，[_setLockAxisWidth]
  ///    里的减法要同步改，否则标注对不准刻度。
  Widget _lockAxisLabels(
    AppLocalizations l10n,
    ColorScheme scheme,
    double axisWidth,
  ) {
    final theme = SliderTheme.of(context);
    final thumbWidth = theme.thumbShape?.getPreferredSize(true, false).width ?? 0;
    final overlayWidth = theme.overlayShape?.getPreferredSize(true, false).width ?? 0;
    final trackLeft = math.max(overlayWidth / 2, thumbWidth / 2);
    final trackInset = math.max(thumbWidth, overlayWidth);
    final width = axisWidth;
    final marks = <({double t, String label, bool rightAligned})>[
      (t: 0.0, label: l10n.lockDurationSecs(kLockMinSeconds), rightAligned: false),
      (t: _lockTFromSeconds(60), label: l10n.lockDurationMin(1), rightAligned: false),
      (t: _lockTFromSeconds(300), label: l10n.lockDurationMin(5), rightAligned: false),
      (t: 1.0, label: l10n.lockDurationMin(kLockMaxSeconds ~/ 60), rightAligned: true),
    ];
    return SizedBox(
      height: 26,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final mark in marks)
            Align(
              alignment: Alignment(
                  mark.rightAligned
                      ? 1
                      : 2 * (trackLeft + mark.t * (width - trackInset)) / width - 1,
                  -1),
              child: Material(
                color: scheme.primary.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  mouseCursor: SystemMouseCursors.click,
                  borderRadius: BorderRadius.circular(8),
                  hoverColor: Colors.black.withValues(alpha: 0.05),
                  highlightColor: Colors.black.withValues(alpha: 0.08),
                  onTap: () => setState(() => _axisT = mark.t),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Text(
                      mark.label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.2,
                        color: scheme.outline,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 弹窗分组卡片（老板 2026-10-18：老码、新码、时长轴必须有醒目的分组区分，
  /// 不能几个框竖着堆成一坨、看不出谁管谁）。白底 + 细描边，从弹窗粉底上"浮"
  /// 出来。标题行可选：有时长卡的「标题 + 右侧当前值」，也有只有标签行的
  /// 「验证 / 设置 / 确认」卡（老板 2026-10-18：老码与新码再分两组）。
  Widget _setLockGroup({
    String? title,
    Widget? trailing,
    Widget? trailingInline,
    required List<Widget> children,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      // 无标题行（纯输入行卡）时上下padding撑开一点，别显得空
      // （标题行→内容 12→8 保留，老板 2026-10-20；其余 padding 维持原样）
      padding: EdgeInsets.fromLTRB(_kCardPadH, title == null ? 14 : 12, _kCardPadH, 14),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest, // 白卡：与弹窗粉底分层
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Row(
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurface,
                  ),
                ),
                // trailingInline：紧跟标签（12px 间距，老板 2026-10-19 从 8 加大，
                // 与描述文字拉开层次），不推到行尾
                if (trailingInline != null) ...[
                  const SizedBox(width: 12),
                  trailingInline,
                ],
                if (trailing != null) ...[const Spacer(), trailing],
              ],
            ),
            const SizedBox(height: 8),
          ],
          ...children,
        ],
      ),
    );
  }

  /// 分组卡内的「标签 + 输入框」同行行（老板 2026-10-18）：标签占固定宽度列
  /// （中英标签宽度不一，固定列才能让各行的输入框左右对齐），输入框 Expanded
  /// 占满剩余宽度。obscure + 纯数字是锁屏码输入框的共性，抽在这里少写三遍。
  /// [revealable]：true 时输入框右侧带小眼睛（老板 2026-10-19：老 PIN 与
  /// 第一个新 PIN），点按切换明文/暗码。
  Widget _setLockPinRow({
    required String label,
    required TextEditingController controller,
    required String fieldLabel,
    bool autofocus = false,
    bool revealable = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 56, // 标签列：en 最长的 "Confirm"（13px w600）放得下
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: colors.onSurface,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          // 小眼睛统一走共用组件 PassphraseField（老板 2026-10-19：与修改口令
          // 弹窗同款行为——3 秒后自动变回暗码 + tooltip + TAB 跳过眼睛；确认框
          // 按组件惯例不给眼睛）。纯数字键盘 + digitsOnly 由调用参数传入。
          child: PassphraseField(
            controller: controller,
            labelText: fieldLabel,
            autofocus: autofocus,
            showReveal: revealable,
            revealTip: l10n.chatPagePassphraseRevealTip,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          ),
        ),
      ],
    );
  }

  /// 标题行双标签（更换 / 清除，老板 2026-10-18）：胶囊分段控件——外层淡色圆角
  /// 轨道 + 选中项实心药丸。每个标签常驻自己的色系（更换=蓝、清除=粉），激活 /
  /// 未激活只是同色系的深 / 浅：选中=实心深色，未激活=同色系浅底 + 同色系深字。
  /// 蓝=品牌天蓝 #3BAFFD（新 Logo「粉蓝图标」里的那个蓝）+ 浅蓝 tertiaryContainer；
  /// 粉=Logo 粉系强调 secondary 深粉 + secondaryContainer 浅粉。天蓝是与主按钮
  /// 的 primary 深蓝明确区分开的"粉蓝里的蓝"（老板 2026-10-18：标签色不能和
  /// 主按钮一样深蓝）。不激活也看得出哪边是危险操作。
  /// AnimatedContainer 平滑过渡。M3 SegmentedButton 默认样式生硬（高、方、灰），
  /// 老板嫌不好看，改用与全局 StadiumBorder 按钮同语言的胶囊。
  Widget _buildSetLockTabs(BuildContext context, AppLocalizations l10n) {
    final colors = Theme.of(context).colorScheme;
    Widget segment(
      int index,
      String label, {
      required Color activeBg,
      required Color activeFg,
      required Color idleBg,
      required Color idleFg,
    }) {
      final selected = _setLockTab == index;
      return Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (_setLockTab == index) return;
            setState(() {
              _setLockTab = index;
              _error = null; // 换页不残留上一页的红字
            });
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(vertical: 9),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              // 选中：本页色系实心深色；未激活：同色系浅底
              color: selected ? activeBg : idleBg,
              borderRadius: BorderRadius.circular(999),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: activeBg.withValues(alpha: 0.35),
                        blurRadius: 6,
                        offset: const Offset(0, 1),
                      ),
                    ]
                  : const [],
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? activeFg : idleFg,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          segment(
            0,
            l10n.chatPageSetLockTabChange,
            activeBg: const Color(0xFF3BAFFD), // 品牌天蓝（Logo 粉蓝图标）
            activeFg: Colors.white,
            idleBg: colors.tertiaryContainer, // 浅蓝
            idleFg: colors.onTertiaryContainer,
          ),
          segment(
            1,
            l10n.chatPageSetLockClearButton,
            activeBg: colors.secondary, // 深粉（Logo 粉系强调）
            activeFg: colors.onSecondary,
            idleBg: colors.secondaryContainer, // 浅粉
            idleFg: colors.onSecondaryContainer,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final clearing = _hasPin && _setLockTab == 1; // 当前在「清除锁屏码」标签页
    // 弹窗宽度（老板 2026-10-18）：手机版与其它弹窗一致（Dialog 默认
    // insetPadding 左右各 40 + minWidth 兜底吃满可用宽度）；桌面端（屏宽
    // ≥ 600）再放宽一档到 480（老板 2026-10-19 从 560 缩小）。几何推导见 [_setLockAxisWidth]。
    final screenWidth = MediaQuery.sizeOf(context).width;
    final dialogMinWidth = screenWidth >= _kDialogWideBreakpoint
        ? _kDialogWidthDesktop
        : _kDialogMinWidthPhone;
    return AlertDialog(
      // 已设锁屏码：标题行换成双标签（更换锁屏码 / 清除锁屏码，老板 2026-10-18）；
      // 未设锁屏码：保持原「设置锁屏码」单标题（没有可清除的东西）
      title: _hasPin
          ? _buildSetLockTabs(context, l10n)
          : Center(child: Text(l10n.chatPageSetLockTitle)),
      // 标签页模式下标题行就是胶囊轨道：底部留 8 再进第一张分组卡片（老板
      // 2026-10-20 键盘遮挡整改：从 12 收紧）；未设锁屏码仍是老节奏
      titlePadding: _hasPin ? const EdgeInsets.fromLTRB(24, 24, 24, 8) : null,
      contentPadding: _hasPin
          ? EdgeInsets.fromLTRB(_kDialogContentPadH, 0, _kDialogContentPadH, 16)
          : const EdgeInsets.fromLTRB(24, 4, 24, 24),
      // 手机版 insetPadding 与 Dialog 默认一致（左右各 40）；minWidth 兜底理由
      // 见 [_setLockAxisWidth]，maxWidth 防桌面端被内容 intrinsic 无限拉宽。
      insetPadding: const EdgeInsets.symmetric(horizontal: _kDialogInsetH, vertical: 24),
      constraints: BoxConstraints(minWidth: dialogMinWidth, maxWidth: _kDialogWidthDesktop),
      // 三组卡片比旧的"提示+三框+轴"高：小屏（或键盘弹起挤压高度）时允许滚动，
      // 不出 RenderFlex overflow——滚动收在 content 内层 Flexible 的
      // SingleChildScrollView 里（外层 Column 不滚），错误红字才能**固定**
      // 在按钮区上方不随内容滚走（老板 2026-10-20）。
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                // 正文（小字提示/输入框）保持靠左——居中的只是标题（老板 2026-09-25）
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (clearing) ...[
            // 「清除锁屏码」标签页（老板 2026-10-18）：红色「清除」主按钮本身就是
            // 警示，页面不再叠备注/警告文案，只留旧码验证框——与更换页第一组同款
            // 的「验证」行卡片，保持结构一致。验旧码仍然必须（2026-09-14 定：否则
            // 手机被他人短暂拿到就能清锁再装自己的 PIN）。
            _setLockGroup(
              children: [
                _setLockPinRow(
                  label: l10n.chatPageSetLockRowVerify,
                  controller: _oldCtrl,
                  fieldLabel: l10n.chatPageSetLockOldLabel,
                  autofocus: true, // 本页唯一输入框
                  revealable: true, // 小眼睛（老板 2026-10-19）
                ),
              ],
            ),
          ] else ...[
            // 未设锁屏码：一句"为什么要设"（老板 2026-09-14）。已设锁屏码时页面
            // 自解释（分组卡片标签 + 主按钮），不再放备注（老板 2026-10-18）
            if (!_hasPin) ...[
              Text(
                l10n.chatPageSetLockHintNoPin,
                style: TextStyle(
                  fontSize: 12,
                  color: colors.outline,
                ),
              ),
              const SizedBox(height: 14),
            ],
            // 第一组：验证当前锁屏码（老码独占一组，只读"验证"标签行；
            // 已设锁屏码才有——没设就没什么可验证的）
            if (_hasPin) ...[
              _setLockGroup(
                children: [
                  _setLockPinRow(
                    label: l10n.chatPageSetLockRowVerify,
                    controller: _oldCtrl,
                    fieldLabel: l10n.chatPageSetLockOldLabel,
                    autofocus: true, // 已设锁屏码时这是第一个框
                    revealable: true, // 小眼睛（老板 2026-10-19）
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            // 第二组：新 PIN（设置 / 确认 两行同卡——新码的两行归一组）。
            // 确认行仅在**已设 PIN 的更换场景**下随第一行显隐（老板 2026-10-19）：
            // 首设场景保持常驻。此前撤回的原因是"第二个填了又清空第一个，确认行
            // 隐藏后与报错对不上"——现在 _submit 先校验第一行非空，该矛盾已拆除。
            // 顺带确认行清空：第一行清空即视作放弃更换，残留的确认值无意义。
            _setLockGroup(
              children: [
                _setLockPinRow(
                  label: l10n.chatPageSetLockRowSet,
                  controller: _pinCtrl,
                  // 首设（未设 PIN）与更换两个场景的文案不同：首设要讲清位数要求，
                  // 更换要讲清"留空=只调时长"——两个 hint 各自独立键（老板 2026-10-18）
                  fieldLabel: _hasPin
                      ? l10n.chatPageSetLockNewPinLabel
                      : l10n.chatPageSetLockNewPinLabelNoPin,
                  autofocus: !_hasPin, // 未设锁屏码时 PIN 是第一个框
                  revealable: true, // 小眼睛（老板 2026-10-19）
                ),
                if (!_hasPin || _pinCtrl.text.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _setLockPinRow(
                    label: l10n.chatPageSetLockRowConfirm,
                    controller: _confirmCtrl,
                    // 确认行与设置行同文案，靠左侧 设置/确认 标签区分
                    // （老板 2026-10-18 原话："第一行标签设置、第二行标签确认"）
                    fieldLabel: _hasPin
                        ? l10n.chatPageSetLockNewPinLabel
                        : l10n.chatPageSetLockNewPinLabelNoPin,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            // 第三组：自动锁屏时长（对数轴 30 秒~30 分钟，老板 2026-10-18：仿阅后
            // 即焚轴，档位吸附 + 轴下可点标注）。前台闲置锁与后台回来锁共用同一值；
            // 改它不需要验当前锁屏码，与前两组互不干扰。
            _setLockGroup(
              // 当前档位紧跟在标签之后（老板 2026-10-19）：不要 Spacer 推到最右，
              // 拖轴时数值就在标签旁边变化，视线不用横跨整张卡
              title: l10n.chatPageSetLockDurationLabel,
              trailingInline: Text(
                _formatLockSeconds(_axisSeconds, l10n),
                style: TextStyle(
                  // 字号明显大于左侧描述（13）+ 更大间距（老板 2026-10-19）：
                  // 与描述文字一眼区分开
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: colors.primary,
                ),
              ),
              children: [
                Slider(
                  value: _axisT,
                  min: 0,
                  max: 1,
                  label: _formatLockSeconds(_axisSeconds, l10n),
                  onChanged: (value) => setState(() => _axisT = value),
                ),
                // 轴下阶段性可点标注：20 秒 / 2 分钟 / 5 分钟 / 20 分钟
                _lockAxisLabels(
                  l10n,
                  colors,
                  _setLockAxisWidth(screenWidth, dialogMinWidth),
                ),
              ],
            ),
          ],
                ],
              ),
            ),
          ),
          // 错误红字固定在按钮区上方、不随内容滚动（老板 2026-10-20）：
          // 在外层不滚的 Column 里、actions 之前，FullWidth 行左对齐 + 软换行，
          // 长文案（如「两次输入不一致」英文句）自动折行不被截断。
          if (_error != null) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: const TextStyle(color: Colors.red, fontSize: 13),
              ),
            ),
          ],
        ],
      ),
      actions: [
        CancelButton(onPressed: () => Navigator.of(context).pop()),
        // 主按钮按标签页切换：更换页=「更换」（老板 2026-10-18：从"启用"改，
        // 只改已设 PIN 的更换场景；未设 PIN 的首次设置仍是「启用」）；
        // 清除页=红底白字「清除」（与删除消息弹窗同款警示配色——老板 2026-10-18）
        if (clearing)
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: _busy ? null : _clearPin,
            child: Text(l10n.chatPageLockClearConfirm),
          )
        else
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: Text(
              _hasPin ? l10n.chatPageSetLockSubmitChange : l10n.setPinDialogSetPin,
            ),
          ),
      ],
    );
  }
}

/// 修改口令弹窗（StatefulWidget）。两种情形：
/// ① 服务器有密保箱 → 旧口令验证（fetch 解密）→ 新口令重加密上传；
/// ② 服务器**无**密保箱（数据丢失）→ 无从校验旧口令，跳过校验直接用新口令
///    重建（通道已认证且持有 Space Key，不新增权限）。
/// 本地一律不落共享口令（与 TUI 对齐；服务器为唯一真相源）。
class _ChangePassphraseDialog extends StatefulWidget {
  const _ChangePassphraseDialog({
    required this.server,
    required this.spaceKeyB64,
    required this.spaceId,
    required this.keyVersion,
    required this.spaceMode,
    required this.session,
    required this.onPassphraseUpdated,
    this.api, // 测试注入（fake api，不触网）；默认按 server 新建
  });

  final String server;
  final ApiClient? api;
  final String spaceKeyB64;
  final String spaceId;
  final int keyVersion;

  /// 秘境类型（'duo' | 'group'）——这句文案里「同伴」的单复数按它选
  /// （`wizardPassphraseHint` 的 ICU select 形参 mode）。
  final String spaceMode;

  /// 本空间的会话（**不是裸 token**）：改口令要连发两次带鉴权请求（读密保箱 + 上传），
  /// 拿裸 token 的话 24h 后这两步都会 401「invalid session」（见 data/space_session.dart）。
  final SpaceSession session;

  /// 上传成功后回传服务端 updated_at（聊天页记录已知时间，防下次补查误报自己改了口令）。
  final ValueChanged<int?> onPassphraseUpdated;

  @override
  State<_ChangePassphraseDialog> createState() => _ChangePassphraseDialogState();
}

class _ChangePassphraseDialogState extends State<_ChangePassphraseDialog> {
  final _oldCtrl = TextEditingController();
  final _newCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  // 与创建向导共用同一策略（shared 的 passphrase_policy.dart）
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _oldCtrl.dispose();
    _newCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    // 提交即清上一轮红字：否则校验通过进入显性确认弹窗时，旧错误仍残留在其背后
    if (_error != null) setState(() => _error = null);
    final oldPass = _oldCtrl.text.trim();
    final newPass = _newCtrl.text.trim();
    final confirm = _confirmCtrl.text.trim();
    if (newPass.isEmpty) {
      setState(() => _error = l10n.setupPageNeedPassphrase);
      return;
    }
    // 口令策略（唯一来源 shared/passphrase_policy.dart）：只要求最短 8 位，
    // 字符种类不限（老板 2026-09-15：复杂度交给用户自己决定）
    if (checkPassphrasePolicy(newPass) != null) {
      setState(() => _error = l10n.wizardPassphraseTooShort);
      return;
    }
    if (newPass != confirm) {
      setState(() => _error = l10n.chatPageChangePassphraseMismatch);
      return;
    }
    // 先取服务端密保箱状态：决定是否需要旧口令、以及确认文案。
    // 无包（服务端数据丢失）时旧口令无从校验——直接重建，不新增权限。
    final api = widget.api ?? ApiClient(effectiveServer);
    final escrow = KeyEscrowService(api);
    setState(() => _busy = true);
    PassphraseEnvelope? serverFile;
    try {
      serverFile = (await widget.session.call((t) => api.getKeyEscrow(t))).file;
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = backendError(l10n, l10n.chatPageChangePassphraseFailed(e.message));
      });
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = l10n.chatPageChangePassphraseFailed('$e');
      });
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    final rebuilding = serverFile == null;
    // 旧口令没填 → 先报第一个框的错（老板 2026-09-23：三框全空报"请设置共享口令"
    // 不合理，第一个空的是当前口令）。重建路径（无密保箱）不需要旧口令，不拦。
    if (!rebuilding && oldPass.isEmpty) {
      setState(() => _error = l10n.chatPageChangePassphraseOldRequired);
      return;
    }
    // 新口令与旧口令相同 → 红字提示，不真去改（老板 2026-09-14）。放在拿到服务端状态
    // 之后：无密保箱（重建路径）本就不用旧口令，那种情况下不该拦（用户可能只是重填同一个口令重建）
    if (!rebuilding && oldPass == newPass) {
      setState(() => _error = l10n.chatPageChangePassphraseSame);
      return;
    }
    // 不再弹第二个确认弹窗（老板 2026-09-15：两个叠着累赘）——校验都过了就直接改：
    // 口令已在三个输入框里输过一遍，本身就是确认；有错一律在弹窗内红字报出。
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // 1) 有密保箱才校验旧口令；无包 = 重建路径，跳过校验
      if (!rebuilding) {
        try {
          await escrow.openPackage(passphrase: oldPass, envelope: serverFile);
        } on FormatException {
          if (!mounted) return;
          setState(() => _error = l10n.chatPageChangePassphraseOldWrong);
          return;
        }
      }
      // 2) 新口令重加密 + 上传（rotated: true → 服务端广播口令重设通知并推进 updated_at）
      await widget.session.call((t) => escrow.upload(
            passphrase: newPass,
            spaceKeyB64: widget.spaceKeyB64,
            spaceId: widget.spaceId,
            keyVersion: widget.keyVersion,
            token: t,
            rotated: true,
          ));
      // 3) 记录本端已知口令更新时间（避免下次上线补查误报"对方重设"——
      //    其实是自己刚改的）。本地不存口令（服务器为唯一真相源）。
      int? serverUpdatedAt;
      try {
        serverUpdatedAt =
            (await widget.session.call((t) => api.getKeyEscrow(t))).updatedAt;
      } catch (_) {
        // 记录失败不影响结果（下次上线补查再对比）
      }
      widget.onPassphraseUpdated(serverUpdatedAt); // 聊天页记录已知时间
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = backendError(l10n, l10n.chatPageChangePassphraseFailed(e.message)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = l10n.chatPageChangePassphraseFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Center(child: Text(l10n.chatPageChangePassphraseTitle)),
      // 标题→备注 4 / 备注→内容 14（参考底部弹层的节奏；老板 2026-10-15）
      contentPadding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 说明文字（与创建向导**共用同一句** wizardPassphraseHint，老板 2026-09-15
          // 要求统一口径；样式与通道码 / PIN 弹窗一致：大标题下小字说明）
          Text(
            l10n.wizardPassphraseHint(widget.spaceMode),
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          const SizedBox(height: 14),
          // 旧口令/新口令可临时查看明文（点眼睛，3 秒后自动回暗码）；
          // **确认新口令不给眼睛**——确认框是用来复核的，给"看一眼"反而容易顺手点开
          // （老板 2026-09-15）。
          PassphraseField(
            controller: _oldCtrl,
            labelText: l10n.chatPageChangePassphraseOldLabel,
            revealTip: l10n.chatPagePassphraseRevealTip,
            autofocus: true, // 改口令弹窗第一个框
          ),
          const SizedBox(height: 8),
          PassphraseField(
            controller: _newCtrl,
            labelText: l10n.chatPageChangePassphraseNewLabel,
            hintText: l10n.wizardPassphraseMinLengthHint,
            revealTip: l10n.chatPagePassphraseRevealTip,
          ),
          const SizedBox(height: 8),
          PassphraseField(
            controller: _confirmCtrl,
            labelText: l10n.chatPageChangePassphraseConfirmLabel,
            showReveal: false,
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
          ],
        ],
      ),
      actions: [
        CancelButton(onPressed: () => Navigator.of(context).pop(false)),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(l10n.chatPageChangePassphraseSubmit),
        ),
      ],
    );
  }
}

/// 波形条（录音条内）：等宽竖条，高度按振幅采样归一化值；
/// 按可用宽度只渲染能放下的条数（取尾部最新采样），窄屏也不会顶出屏幕。
class _WaveformBars extends StatelessWidget {
  const _WaveformBars({required this.samples, required this.color});

  final List<double> samples;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      const step = 6.0; // 每根条占宽：3px 本体 + 1.5px 边距 ×2
      final maxBars = (constraints.maxWidth / step).floor();
      final count = maxBars <= 0 ? 0 : (samples.length < maxBars ? samples.length : maxBars);
      final shown = count <= 0 ? const <double>[] : samples.sublist(samples.length - count);
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (final sample in shown)
            Container(
              width: 3,
              height: 8 + sample * 22,
              margin: const EdgeInsets.symmetric(horizontal: 1.5),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(1.5),
              ),
            ),
        ],
      );
    });
  }
}

/// 语音波形图（老板要求 2026-09-13）：长方形区域里一排等宽竖条。
///
/// 竖条振幅二选一：[samples] 给了就用真实录音采样（录音条预览态，按 [width]
/// 重采样成对应的条数）；否则用 [seed]（气泡里的 messageId）确定性生成——
/// 同一条消息每次进页面形状一致（接收端拿不到对方录音的振幅）。
///
/// 播放时按时间比例把已播过的条染成 [activeColor]（阴影从左往右扩散），并在
/// 进度位置画一根竖线走过去；走完/停止即复原。时长未知时改为循环扫掠的波浪动画。
/// 进度只用一个 AnimationController 的 value 驱动，重绘仅限这个 CustomPaint。
class _VoiceWaveform extends StatefulWidget {
  const _VoiceWaveform({
    required this.playing,
    required this.durationSeconds,
    required this.activeColor,
    required this.inactiveColor,
    this.samples,
    this.seed,
    this.width = 120,
  });

  final bool playing;
  final int durationSeconds;
  final Color activeColor;
  final Color inactiveColor;
  final List<double>? samples; // 真实振幅采样（非空时优先于 seed）
  final String? seed;
  final double width;

  @override
  State<_VoiceWaveform> createState() => _VoiceWaveformState();
}

class _VoiceWaveformState extends State<_VoiceWaveform>
    with SingleTickerProviderStateMixin {
  static const double _barWidth = 3;
  static const double _barGap = 2;
  static const double _height = 28;

  late final AnimationController _progress;
  late List<double> _amplitudes;

  @override
  void initState() {
    super.initState();
    _amplitudes = _resolveAmplitudes();
    _progress = AnimationController(vsync: this, duration: _animationDuration);
    _sync();
  }

  @override
  void didUpdateWidget(covariant _VoiceWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playing != widget.playing ||
        oldWidget.durationSeconds != widget.durationSeconds) {
      _sync();
    }
    if (oldWidget.width != widget.width ||
        oldWidget.samples?.length != widget.samples?.length) {
      _amplitudes = _resolveAmplitudes();
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  /// 竖条数由宽度决定（3px 条 + 2px 间隔）。
  int get _barCount =>
      math.max(4, ((widget.width + _barGap) / (_barWidth + _barGap)).floor());

  /// 动画时长：时长已知=按时长走一遍；未知=2s 循环扫掠。
  Duration get _animationDuration => widget.durationSeconds > 0
      ? Duration(milliseconds: widget.durationSeconds * 1000)
      : const Duration(seconds: 2);

  void _sync() {
    if (!widget.playing) {
      _progress.stop();
      _progress.value = 0;
      return;
    }
    _progress.duration = _animationDuration;
    if (widget.durationSeconds > 0) {
      _progress.forward(from: 0);
    } else {
      _progress.repeat(); // 时长未知：反复扫掠（动态波浪效果）
    }
  }

  /// 竖条振幅：有真实采样就重采样到 [_barCount]，否则按 seed 确定性生成。
  List<double> _resolveAmplitudes() {
    final samples = widget.samples;
    if (samples != null && samples.isNotEmpty) return _resample(samples, _barCount);
    return _buildAmplitudes(widget.seed ?? '');
  }

  /// 把任意长度的采样压成 [count] 根条（每根取该区间的均值）。
  List<double> _resample(List<double> samples, int count) {
    if (samples.length == count) return samples;
    return List<double>.generate(count, (index) {
      final start = (index * samples.length / count).floor();
      final end = math.max(start + 1, ((index + 1) * samples.length / count).floor());
      var sum = 0.0;
      for (var i = start; i < end && i < samples.length; i++) {
        sum += samples[i];
      }
      return sum / (end - start);
    });
  }

  /// 按 seed 生成竖条振幅：中间高两头低的包络 + 确定性伪随机抖动。
  List<double> _buildAmplitudes(String seed) {
    var hash = 2166136261; // FNV-1a 起点
    for (final unit in seed.codeUnits) {
      hash = (hash ^ unit) * 16777619;
    }
    final random = math.Random(hash & 0x7fffffff);
    final count = _barCount;
    return List<double>.generate(count, (index) {
      final envelope = math.sin(math.pi * (index + 1) / (count + 1));
      return (0.35 + 0.65 * random.nextDouble()) * (0.45 + 0.55 * envelope);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _progress,
      builder: (context, _) => CustomPaint(
        size: Size(widget.width, _height),
        painter: _WaveformPainter(
          amplitudes: _amplitudes,
          progress: _progress.value,
          activeColor: widget.activeColor,
          inactiveColor: widget.inactiveColor,
        ),
      ),
    );
  }
}

/// 波形绘制：progress 左侧的条 + 进度竖线用高亮色，其余用底色。
class _WaveformPainter extends CustomPainter {
  const _WaveformPainter({
    required this.amplitudes,
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
  });

  static const double _barWidth = 3;
  static const double _barGap = 2;

  final List<double> amplitudes;
  final double progress;
  final Color activeColor;
  final Color inactiveColor;

  @override
  void paint(Canvas canvas, Size size) {
    final playedTo = progress * size.width;
    final paint = Paint()..style = PaintingStyle.fill;
    for (var index = 0; index < amplitudes.length; index++) {
      final left = index * (_barWidth + _barGap);
      final height = 4 + amplitudes[index] * (size.height - 4);
      paint.color = left + _barWidth <= playedTo ? activeColor : inactiveColor;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, (size.height - height) / 2, _barWidth, height),
          const Radius.circular(1.5),
        ),
        paint,
      );
    }
    if (progress > 0 && progress < 1) {
      paint.color = activeColor;
      canvas.drawRect(
        Rect.fromLTWH((playedTo - 1).clamp(0.0, size.width - 2), 0, 2, size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.activeColor != activeColor ||
      oldDelegate.inactiveColor != inactiveColor;
}

/// 消息发送者头像：按 memberId 从服务端加载（静态缓存避免重复请求），
/// 未设置/加载失败显示默认图标；点击有头像时放大到全屏查看。
/// 是否在每条消息气泡旁显示发送者头像（编译期开关，`--dart-define` 可覆盖）。
///
/// 群聊一期（2026-10-03）起**按空间类型自动**（见 [_ChatPageState._showMessageAvatars]）：
/// duo 默认关（状态条已有双方头像）、group 默认开（必须逐条标注是谁说的）；
/// `--dart-define=SHOW_MESSAGE_AVATARS=true` 强制全开（临时验证用）。
///
/// 用 `bool.fromEnvironment`（编译期常量、但分析器不知道值）而不是写死 false：
/// 写死会让整段 `if` 被判定为死代码，将来改开关时反而不好维护。
const bool kShowMessageAvatarsOverride = bool.fromEnvironment('SHOW_MESSAGE_AVATARS');

/// 状态条里**操作控件**（电话图标 / 下拉箭头 / 邀请链接）的背景高度。
///
/// 比头像（[kStatusAvatarSize]=40）矮：圆形控件的圆弧在上下顶点附近会收窄，
/// 视觉上"离胶囊边缘有距离"；而胶囊形（邀请链接）是**满高的直边**——同样给 40
/// 就直接顶住状态条上下边缘（老板 2026-09-26 实测）。所以统一的背景高度取 32。
const double kStatusControlSize = 32;

/// 状态条上的头像边长（= 名字 + 红绿灯两行的高度）。头像**上下不留白**，
/// 三面贴住胶囊内壁（老板 2026-09-26）。
const double kStatusAvatarSize = 40;

/// 状态条左侧「成员头像条」里每个头像的直径。
///
/// 与右侧我自己的 [kStatusAvatarSize]（40）**同尺寸**：老板 2026-10-06 改版——
/// 头像条要像右侧头像一样**上下顶满**状态条高（40），头像之间**不留空隙**；
/// 32 的小一号挤在胶囊里反而要留边。群空间专用。
const double kStatusMemberAvatarSize = 40;

/// 消息气泡旁的头像直径（`_MessageAvatar` 的默认半径 16 × 2）。
///
/// 群聊里**发言人名字列宽就取它**（名字在头像下方，老板 2026-10-05）：列宽固定 =
/// 头像直径，所以再长的名字也只在自己那一列里省略，**不会把气泡推歪**——
/// 气泡左缘在每条消息上都是对齐的。
const double kMessageAvatarDiameter = 32;

/// 顶部「切换秘境」旁的**未读汇总角标**（其它空间的未读总数）。
///
/// 数字变化时用 [AnimatedSwitcher] 缩放一下（老板 2026-09-26 要的"闪动"）——
/// key 取数字本身，数字一变就重建 child、触发一次缩放动画。
/// 只有**多空间**时才可能出现（单空间没有"其它空间"）。
class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      transitionBuilder: (child, animation) =>
          ScaleTransition(scale: animation, child: child),
      child: Container(
        key: ValueKey<int>(count),
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: theme.colorScheme.error,
          borderRadius: BorderRadius.circular(10),
        ),
        // 与空间卡片上的角标同口径：>99 折成 "99+"
        child: Text(
          count > 99 ? '99+' : '$count',
          style: const TextStyle(
              color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

/// 状态条上的头像（可点开全屏大图）。
///
/// **桌面端的悬浮反馈**（老板 2026-09-26）：鼠标移上去变手型 + 头像轻微放大（1.06，
/// 用 [ClipOval] 关住，避免放大后顶出胶囊被裁）+ 压暗一层。触屏没有 hover，
/// 这些层不会出现，等于零影响。
class _StatusAvatar extends StatefulWidget {
  const _StatusAvatar(
      {this.bytes, required this.tint, this.onTap, this.icon = Icons.person});

  final Uint8List? bytes;
  final Color tint;
  final VoidCallback? onTap;

  /// 没头像时显示的图标。默认单人形；**群空间**传 `Icons.groups_outlined`
  /// ——那一格代表的是一群人，不是某一个人（老板 2026-10-05）。
  final IconData icon;

  @override
  State<_StatusAvatar> createState() => _StatusAvatarState();
}

class _StatusAvatarState extends State<_StatusAvatar> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final avatar = CircleAvatar(
      backgroundColor: widget.tint,
      backgroundImage: widget.bytes != null ? MemoryImage(widget.bytes!) : null,
      child: widget.bytes == null ? Icon(widget.icon, size: 22) : null,
    );
    final body = SizedBox(
      width: kStatusAvatarSize,
      height: kStatusAvatarSize,
      child: ClipOval(
        child: Stack(
          fit: StackFit.expand,
          children: [
            AnimatedScale(
              scale: _hovered ? 1.06 : 1,
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              child: avatar,
            ),
            // 悬浮压暗一层（**只留遮罩**，不放放大镜图标——老板 2026-09-26）
            if (widget.onTap != null)
              IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _hovered ? 1 : 0,
                  duration: const Duration(milliseconds: 120),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.18),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    if (widget.onTap == null) return body;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Clickable(onTap: widget.onTap, circle: true, child: body),
    );
  }
}

/// 全屏查看（图片 / 视频 / 头像大图）右上角的关闭键（老板 2026-10-12）：
/// 白 ✕ + 黑 54% 半透明圆底。内容铺满全屏时若图片偏白，纯白 ✕ 会融进背景
/// 看不见；半透明深灰圆底压在任何底色上都能衬出白叉——用半透明而非实心灰，
/// 是会随底色自适应：深色内容上不显脏、浅色内容上够压得住。48 直径正好是
/// Material 最小触控区域，不比原来的裸 IconButton 多占地方。
/// 四间全屏查看（消息图片 / 视频 / 消息头像 / 状态条头像）共用这一只。
class _FullscreenCloseButton extends StatelessWidget {
  const _FullscreenCloseButton();

  @override
  Widget build(BuildContext context) {
    return IconButton(
      style: IconButton.styleFrom(
        backgroundColor: Colors.black54,
        shape: const CircleBorder(),
      ),
      icon: const Icon(Icons.close, color: Colors.white),
      onPressed: () => Navigator.of(context).pop(),
    );
  }
}

/// 粘贴待确认的内容（老板 2026-10-12 确认弹窗的载荷）：
/// - 图片：clipboard 里的图片**字节**（截图 / 图片 App 拷贝），弹窗给缩略图；
/// - 文件：访达/资源管理器里拷的**文件路径**，按扩展名归类到
///   [kind]（image/video/audio/file），弹窗按类型问、图标按类型给。
/// 两者都空不可能出现（那走文本分支，不弹窗）。
class _PastePayload {
  const _PastePayload.image(this.bytes)
      : files = null,
        kind = 'image';
  const _PastePayload.files(this.files, this.kind) : bytes = null;

  final Uint8List? bytes;
  final List<XFile>? files;
  final String kind;
}

/// 头像全屏页（**唯一实现**，老板 2026-10-17 要求三处共享）：状态条头像 /
/// 消息气泡旁头像 / 「我的资料」弹层头像共用。品牌渐变背景 + 轻触关闭 + 右上
/// 关闭键；底部按钮按回调组合（都**先关大图再执行**）：
/// - [onReplace]：「更换头像」（顶部居中；本人的头像才传）；
/// - [onApplyAllSpaces]：「应用于本机所有秘境」（字号小一档分主次；本人的
///   头像才传，参数 = 要扇出的 bytes，即本页展示的那张）；
/// - [onSave]：「保存」——与 [onApplyAllSpaces] **并排时**缩成图标圆钮
///   （我的头像 = 下载图标 + 应用所有秘境）；[onApplyAllSpaces] 为 null
///   （对方头像）时独占一行，用与消息图片全屏同款的「图标+保存」完整按钮。
Future<void> showMyAvatarFullscreen(
  BuildContext context, {
  required Uint8List bytes,
  VoidCallback? onReplace,
  Future<void> Function(Uint8List bytes)? onApplyAllSpaces,
  Future<void> Function(Uint8List bytes)? onSave,
}) async {
  await withImmersiveFullscreen(() => showDialog<void>(
        context: context,
        barrierDismissible: true,
        useSafeArea: false,
        builder: (ctx) => Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: EdgeInsets.zero,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          child: SizedBox.expand(
            child: DecoratedBox(
              decoration: const BoxDecoration(gradient: kBrandGradient),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Clickable(
                      onTap: () => Navigator.of(ctx).pop(),
                      child: InteractiveViewer(
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Image.memory(bytes, fit: BoxFit.contain),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 顶部「更换头像」（SafeArea 内居中；关闭键独立一层浮右上角，
                  // 不挤占居中按钮）。先关大图再进选图——不关的话取消选图会
                  // 回到一张"已经没意义"的大图（头像还没换）。
                  if (onReplace != null)
                    Positioned(
                      top: 8,
                      left: 0,
                      right: 0,
                      child: SafeArea(
                        child: Center(
                          child: FilledButton.icon(
                            onPressed: () {
                              Navigator.of(ctx).pop();
                              onReplace();
                            },
                            icon: const Icon(Icons.photo_camera_outlined),
                            label: Text(AppLocalizations.of(ctx)!
                                .chatPageAvatarChange),
                          ),
                        ),
                      ),
                    ),
                  // 右上角关闭键（独立一层，居中按钮不挤占它）
                  Positioned(
                    top: 8,
                    right: 8,
                    child: SafeArea(child: _FullscreenCloseButton()),
                  ),
                  // 底部一行（SafeArea 内居中，bottom:32）：
                  // - **本人的头像**：「保存」图标圆钮 +「应用于本机所有秘境」
                  //   并排（老板 2026-10-17：下载图标不抢戏，悬停有 tooltip）；
                  // - **对方头像**（无 apply 回调）：与普通图片全屏同款的
                  //   「图标+保存」完整按钮。
                  // 先关大图再执行——顶部提示/加载是聊天页的覆盖层，压在
                  // Dialog 下面看不见。
                  if (onSave != null || onApplyAllSpaces != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 32,
                      child: SafeArea(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (onSave != null && onApplyAllSpaces != null) ...[
                              // 我的头像：图标圆钮版
                              Tooltip(
                                message:
                                    AppLocalizations.of(ctx)!.chatPageActionSave,
                                child: IconButton.filled(
                                  onPressed: () {
                                    Navigator.of(ctx).pop();
                                    unawaited(onSave(bytes));
                                  },
                                  icon: const Icon(Icons.save_alt),
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            if (onApplyAllSpaces != null)
                              FilledButton.icon(
                                style: FilledButton.styleFrom(
                                  textStyle: const TextStyle(fontSize: 13),
                                ),
                                onPressed: () {
                                  Navigator.of(ctx).pop();
                                  unawaited(onApplyAllSpaces(bytes));
                                },
                                icon: const Icon(Icons.layers_outlined),
                                label: Text(
                                    AppLocalizations.of(ctx)!.settingsScopeAll),
                              ),
                            // 对方头像（无 apply）：完整「图标+保存」按钮，
                            // 与消息图片全屏同款（老板 2026-10-17）
                            if (onSave != null && onApplyAllSpaces == null)
                              FilledButton.icon(
                                onPressed: () {
                                  Navigator.of(ctx).pop();
                                  unawaited(onSave(bytes));
                                },
                                icon: const Icon(Icons.save_alt),
                                label: Text(
                                    AppLocalizations.of(ctx)!.chatPageActionSave),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ));
}

class _MessageAvatar extends StatefulWidget {
  const _MessageAvatar(
      {super.key,
      this.memberId,
      required this.server,
      this.api,
      this.radius = 16,
      this.openFullscreenOnTap = true,
      this.onSaveImage,
      this.onReplaceAvatar,
      this.onApplyAllSpaces,
      this.onTapWithoutImage});

  final String? memberId;
  final String server;
  final ApiClient? api;

  /// 头像半径（成员卡里放大到 20；消息区保持 16）。
  final double radius;

  /// 点按是否打开头像大图。**状态条的头像条传 false**——那一串的点按应落到外层
  /// 「我的同伴」胶囊；否则**有头像图片**的成员会被这里抢走点击、误开全览页，
  /// 而无图的成员又能正常进弹层（同一排头像行为不一致，老板 2026-10-08 报）。
  final bool openFullscreenOnTap;

  /// 全屏大图底部「保存」按钮的回调（老板 2026-10-08：别人的头像大图可下载）。
  /// null = 不放按钮（如状态条头像条：它压根不开全屏）。存哪儿由聊天页决定
  /// （移动端入相册、桌面弹保存对话框）。
  final Future<void> Function(Uint8List bytes)? onSaveImage;

  /// 顶部「更换头像」按钮的回调（老板 2026-10-17：本人的头像才给——「我的资料」
  /// 弹层/状态条用，点「我的头像」大图能直接去换头像）。null = 不放按钮
  /// （别人的头像，没有权限改）。
  final VoidCallback? onReplaceAvatar;

  /// 「应用于本机所有秘境」按钮的回调（老板 2026-10-17：把这份头像扇出到本机
  /// 其它秘境）。与 [onReplaceAvatar] 同源——都是本人的头像才给。
  /// 参数 = 全屏里实际展示的 bytes（扇出去的必须就是用户看的那张）。
  final Future<void> Function(Uint8List bytes)? onApplyAllSpaces;

  /// **没有头像图片**时点头像的动作（如「我的资料」弹层：直接进选图流程）。
  ///
  /// 为什么由本组件自己决定：图在不在，只有本组件的静态缓存说了算
  /// （[_MessageAvatarState._load] 独立加载）。调用方另存一份 bytes
  /// （如 `_myAvatarBytes`）来猜，两次独立加载不一致时会**错航**（有图却进
  /// 选图）或**死区**（没图却不开全屏）——2026-10-17 代码复查发现的竞态，
  /// 故把决策权收回到唯一的数据源。
  final VoidCallback? onTapWithoutImage;

  @override
  State<_MessageAvatar> createState() => _MessageAvatarState();
}

class _MessageAvatarState extends State<_MessageAvatar> {
  static final Map<String, Uint8List> _cache = {}; // memberId → 头像 bytes

  /// 头像失效广播（memberId）：通知当前在树上的头像重拉——否则静态缓存只在
  /// 进程内有效，换了头像要重启 App 才看得到（老板 2026-09-11）。
  static final ValueNotifier<String?> invalidated = ValueNotifier<String?>(null);

  /// 让某人的头像失效：上传本人头像 / 收到对方 profile.updated 时调用。
  static void invalidate(String? memberId) {
    if (memberId == null || memberId.isEmpty) return;
    invalidated.value = memberId;
  }

  Uint8List? get _bytes => widget.memberId == null ? null : _cache[widget.memberId];

  @override
  void initState() {
    super.initState();
    final pid = widget.memberId;
    if (pid != null && !_cache.containsKey(pid)) {
      _load(pid);
    }
    invalidated.addListener(_onInvalidated);
  }

  @override
  void dispose() {
    invalidated.removeListener(_onInvalidated);
    super.dispose();
  }

  void _onInvalidated() {
    final pid = widget.memberId;
    if (pid == null || invalidated.value != pid) return;
    _load(pid); // 覆盖旧缓存后再 setState（不先清空——避免闪成默认图标）
  }

  Future<void> _load(String memberId) async {
    try {
      final api = widget.api ?? ApiClient(effectiveServer);
      final bytes = await api.getAvatar(memberId);
      if (bytes == null) return;
      // 缓存写入不看 mounted：失效广播时未挂载的实例（滚出屏幕被回收）若丢弃结果，
      // 静态缓存会一直留着旧图，滚动回来 initState 见缓存命中也不再重拉
      _cache[memberId] = bytes;
      if (mounted) setState(() {});
    } catch (_) {
      // 网络失败：保持默认图标
    }
  }

  /// 全屏查看头像：走共享的 [showMyAvatarFullscreen]（老板 2026-10-17：
  /// 状态条/「我的资料」/本头像三处必须同一份全屏实现）。按钮集合由回调决定：
  /// 「更换头像」「应用于本机所有秘境」仅本人头像有（调用方传）；「保存」
  /// 人人都有（[onSaveImage]，本人是图标圆钮、对方是完整按钮——见共享页注释）。
  Future<void> _showFullscreen() async {
    final bytes = _bytes;
    if (bytes == null) return;
    final onReplace = widget.onReplaceAvatar;
    final onApplyAll = widget.onApplyAllSpaces;
    final onSave = widget.onSaveImage;
    await showMyAvatarFullscreen(
      context,
      bytes: bytes,
      onReplace: onReplace,
      onApplyAllSpaces: onApplyAll,
      onSave: onSave,
    );
  }

  /// 点按动作：本组件唯一的「去向」决策——有图 → 全屏大图；没图 → 调用方的
  /// [onTapWithoutImage]。
  ///
  /// 对外公开是给「我的资料」弹层用的（老板 2026-10-17）：那里把头像和编辑角标
  /// 包成一个方形热区，点在角标或圆的四角也要落到和图像同一动作上——外层热区
  /// 直接调这个方法，内层则传 `openFullscreenOnTap: false` 让出点击，避免两个
  /// 手势识别器抢同一个 tap。
  void handleTap() {
    if (_bytes != null) {
      _showFullscreen();
    } else {
      widget.onTapWithoutImage?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    // 点按去向由**本组件**决定（有图 → 全屏；没图 → 调用方的 onTapWithoutImage），
    // 不靠调用方从外部猜缓存状态（见 onTapWithoutImage 注释）。
    final onTap = widget.openFullscreenOnTap ? handleTap : null;
    return Clickable(
      onTap: onTap,
      circle: true,
      child: CircleAvatar(
        radius: widget.radius,
        backgroundColor: Colors.grey.shade300,
        backgroundImage: bytes != null ? MemoryImage(bytes) : null,
        child: bytes == null
            ? Icon(Icons.person, size: widget.radius + 2)
            : null,
      ),
    );
  }
}

/// 邀请链接二维码（自绘，替代 QrImageView）。
///
/// QrImageView（qr_flutter 4.1.0）两个坑（2026-09-08 老板真机报告：生成通道码
/// 时屏幕变暗但弹窗不出现；且弹窗里的二维码从未显示）：
/// 1. 内部无条件包 LayoutBuilder，而 AlertDialog 用 IntrinsicWidth 包裹内容做
///    固有尺寸测量 → performLayout 抛 "LayoutBuilder does not support returning
///    intrinsic dimensions"（Flutter issue #46063 同款签名）→ 弹窗首帧布局中断，
///    遮罩变暗、内容不显示；
/// 2. 其绘制面 CustomPaint 无显式尺寸、被内部 Padding 松约束包裹 → 实际 0x0，
///    QrPainter.paint 直接 return，二维码不可见。
/// 这里直接用 QrCode + QrPainter 自绘：无 LayoutBuilder（固有测量安全）、
/// 显式 SizedBox 定尺寸（必定可见）。
class _InviteQrCode extends StatelessWidget {
  const _InviteQrCode({required this.data});

  /// 二维码内容：邀请链接（`https://einz.tic.cc/join/<token>`，约 80 字符；
  /// QR 容量绰绰有余，不会超长）。
  final String data;

  @override
  Widget build(BuildContext context) {
    final qr = QrCode.fromData(
      data: data,
      errorCorrectLevel: QrErrorCorrectLevel.L,
    );
    return SizedBox(
      width: 160,
      height: 160,
      child: CustomPaint(painter: QrPainter.withQr(qr: qr)),
    );
  }
}

/// 视频消息内联预览：暂停态显示首帧 + 播放按钮；点击全屏播放。
/// 发送端本地密文即时显示（上传完成前/失败后也能看），接收端服务端拉取
/// （老板 2026-09-11：改回 v1 直接显示视频）。
class _VideoPreview extends StatefulWidget {
  const _VideoPreview(
      {required this.bytes,
      required this.spaceId,
      required this.messageId,
      this.onDownload});

  final Uint8List bytes;
  final String spaceId; // 缓存按空间分目录（与服务端 files/<space_id>/ 同构）
  final String messageId; // 解密缓存确定性键：重复预览复用同一缓存文件

  /// 全屏播放器底部「保存」按钮的回调（老板 2026-10-08）。null = 不放按钮。
  /// 具体存哪儿由聊天页决定：移动端入相册、桌面弹保存对话框（见 `_saveAttachment`）。
  final VoidCallback? onDownload;

  @override
  State<_VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<_VideoPreview> {
  VideoPlayerController? _controller;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    // Linux 没有 video_player 实现（连最新 2.14.1 也只有 android/ios/macos/
    // web）：初始化必失败，跳过——build 里走「保存到本地」占位
    if (!Platform.isLinux) _init();
  }

  Future<void> _init() async {
    if (_failed && mounted) setState(() => _failed = false); // 重试：先清掉上次的失败态
    try {
      // 解密缓存：确定性路径按 messageId 复用（重复打开预览不再重复落盘解密）
      final tmp = await MediaCache.pathFor(widget.spaceId, widget.messageId, 'mp4');
      if (!await tmp.exists()) {
        await tmp.writeAsBytes(widget.bytes, flush: true);
      }
      final c = VideoPlayerController.file(tmp);
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _controller = c);
    } catch (e) {
      // 留痕：此前这里静默成空白，桌面端排查时完全看不出线索（老板 2026-09-20
      // 报「视频在消息流里是空白」就是这么藏了很久）
      debugPrint('视频预览初始化失败（${widget.messageId}）：$e');
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Linux（无 video_player 实现）：不摆播放器，给「保存到本地」入口——
    // 字节已解密到手（_buildVideo 的 FutureBuilder 传进来的），保存走桌面
    // 保存对话框（_saveAttachment → FilePicker.saveFile）。与失败态同尺寸，
    // 但不可重试（重试无意义）——文案说清「不支持播放」而非「加载失败」
    if (Platform.isLinux) {
      return Clickable(
        key: const ValueKey('videoPreview'),
        onTap: widget.onDownload == null ? null : () => widget.onDownload!(),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 180,
          height: 100,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.movie_outlined, size: 26),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(l10n.chatPageVideoUnsupportedPlatform,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
      );
    }
    final c = _controller;
    // 初始化失败：给可点重试的明确错误态，而不是一个没有内容的空白框
    // （三种状态都带同一个 key：测试按 key 定位视频气泡，不受具体控件类型影响）
    if (_failed) {
      return Clickable(
        key: const ValueKey('videoPreview'),
        onTap: _init,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 180,
          height: 100,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off_outlined, size: 26),
              const SizedBox(height: 6),
              Text(AppLocalizations.of(context)!.chatPageVideoLoadFailed,
                  style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
      );
    }
    // 初始化中：显示进度（与失败态分开，避免"转圈"和"空白"看起来一样）
    if (c == null) {
      return SizedBox(
          key: const ValueKey('videoPreview'),
          width: 180,
          height: 100,
          child: const Center(child: CircularProgressIndicator(strokeWidth: 2)));
    }
    return Clickable(
      key: const ValueKey('videoPreview'),
      onTap: () => _playFullscreen(c),
      borderRadius: BorderRadius.circular(8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 180,
          height: 180,
          child: Stack(
            fit: StackFit.expand,
            children: [
              VideoPlayer(c), // 暂停态显示首帧
              const Center(
                child: Icon(Icons.play_circle_fill, size: 44, color: Colors.white70),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 全屏播放（品牌渐变底 + 铺满整屏 + 点任何位置关闭）。
  /// 轻触关闭（老板 2026-10-12）与图片/头像全屏一致：点画面或四周压边都返回
  /// 聊天页；右上角 ✕ 保留作显式出口。
  Future<void> _playFullscreen(VideoPlayerController c) async {
    await c.seekTo(Duration.zero);
    await c.play();
    if (!mounted) return;
    await withImmersiveFullscreen(() => showDialog<void>(
          context: context,
          barrierDismissible: true,
          useSafeArea: false,
          builder: (ctx) => Dialog(
            // 与图片全屏一致：品牌渐变底 + 铺满全屏 + 隐藏系统状态栏（老板要求
            // 2026-09-12 / 2026-09-15——视频全屏也应是渐变大画面，且背景要盖到
            // 屏幕最顶端，而不是默认半透明遮罩下的圆角小卡）
            backgroundColor: Colors.transparent,
            insetPadding: EdgeInsets.zero,
            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
            child: SizedBox.expand(
              child: DecoratedBox(
                decoration: const BoxDecoration(gradient: kBrandGradient),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Clickable(
                        // opaque：视频在 AspectRatio 里不遮满屏幕，四周渐变压边
                        // 也要接得住轻触（deferToChild 会漏掉这些区域）——
                        // 老板 2026-10-12：点任何地方关闭全屏
                        behavior: HitTestBehavior.opaque,
                        onTap: () => Navigator.of(ctx).pop(),
                        child: Center(
                          child: AspectRatio(
                            aspectRatio: c.value.aspectRatio,
                            child: VideoPlayer(c),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: SafeArea(child: _FullscreenCloseButton()),
                    ),
                    // 底部「保存」（老板 2026-10-08）：移动端存相册、桌面弹保存对话框。
                    // 先关全屏再保存——顶部提示是聊天页覆盖层，压在 Dialog 下面看不见。
                    if (widget.onDownload != null)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 32,
                        child: Center(
                          child: FilledButton.icon(
                            onPressed: () {
                              Navigator.of(ctx).pop();
                              widget.onDownload!();
                            },
                            icon: const Icon(Icons.save_alt),
                            label: Text(
                                AppLocalizations.of(ctx)!.chatPageActionSave),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ));
    await c.pause();
  }
}

/// 「发送中」的**动态**小飞机（老板 2026-09-13）：轻微上下浮动 + 左右小幅平移 +
/// 一点点俯仰，读起来像"飞行中"。原来是个静态图标，看不出"正在动"。
///
/// 无障碍/测试友好：`MediaQuery.disableAnimations` 为真时退化为静态图标——
/// 既尊重"减少动态效果"的系统偏好，也让 widget 测试里的 `pumpAndSettle` 不会
/// 被这个常驻动画卡住（常驻动画会让 pumpAndSettle 一直等到超时）。
class _SendingPlane extends StatefulWidget {
  const _SendingPlane({this.color, this.size = 11});

  final Color? color;

  /// 图标边长（2026-10-11 起气泡里传 16，与时间行快捷动作图标同档）。
  final double size;

  @override
  State<_SendingPlane> createState() => _SendingPlaneState();
}

class _SendingPlaneState extends State<_SendingPlane>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final icon = Icon(Icons.send, size: widget.size, color: widget.color);
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) return icon;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value * 2 * math.pi;
        return Transform.translate(
          offset: Offset(math.sin(t) * 1.5, -math.cos(t) * 1.2),
          child: Transform.rotate(angle: math.sin(t) * 0.15, child: child),
        );
      },
      child: icon,
    );
  }
}

/// 阅后即焚「沙漏」小图标（老板 2026-09-12）：未焚毁时在 hourglass_top ↔
/// hourglass_bottom 之间缓慢翻转，暗示倒计时在流逝；**已焚毁（[burned]）时改为
/// 静态空沙漏**——沙漏已经漏完了，还在翻转不符合直觉（老板 2026-09-12）。
/// 颜色不指定 → 继承 IconTheme（渐变风格下为白系，与相邻的时间/时长文字一致）。
/// 尺寸默认 11（消息气泡时间行的小标）；汉堡菜单等大号场景传 [size] 覆盖
/// （老板 2026-09-28：菜单里与 devices 图标同大小）。
class _BurnHourglass extends StatelessWidget {
  const _BurnHourglass({this.burned = false, this.size = 11});

  /// 该消息是否已被焚毁/删除（到期或手动删除）——是则显示静态空沙漏。
  final bool burned;

  /// 图标边长。
  final double size;

  @override
  Widget build(BuildContext context) {
    // 已焚毁：静态空沙漏（不创建动画控制器，避免无谓的逐帧重建）
    if (burned) return Icon(Icons.hourglass_empty, size: size);
    return _HourglassFlip(size: size);
  }
}

class _HourglassFlip extends StatefulWidget {
  const _HourglassFlip({this.size = 11});

  final double size;

  @override
  State<_HourglassFlip> createState() => _HourglassFlipState();
}

class _HourglassFlipState extends State<_HourglassFlip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 「减少动态效果」（含 widget 测试：见 test/real_async_settle.dart 的
    // disableAnimationsInTests）→ 不翻转。**关键是停掉 ticker**：只把画面换成
    // 静态图标、控制器还在 repeat 的话，帧仍会一直排下去，`pumpAndSettle` 照样
    // 超时。恢复动态偏好时再续上。
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 减少动态效果 → 静态沙漏（取上壶：与"时间在往下漏"的直觉一致）
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      return Icon(Icons.hourglass_top, size: widget.size);
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Icon(
        _controller.value < 0.5 ? Icons.hourglass_top : Icons.hourglass_bottom,
        size: widget.size,
      ),
    );
  }
}
