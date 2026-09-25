// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get cancel => '取消';

  @override
  String get ok => '确定';

  @override
  String get send => '发送';

  @override
  String get confirm => '确认';

  @override
  String get delete => '删除';

  @override
  String get settings => '设置';

  @override
  String get skip => '跳过';

  @override
  String get close => '关闭';

  @override
  String get setupPageEnvelopeKeyHint => '密保信封是线下安全交接的一段不对称加密文本。请询问你的秘境伴侣获取。';

  @override
  String get setupPageNeedPassphrase => '请设置共享口令';

  @override
  String get wizardJoinPassphraseRequired => '请输入共享口令进行验证';

  @override
  String get wizardStartTitle => '秘境';

  @override
  String get wizardDetectTitle => '正在检测服务器状态…';

  @override
  String get wizardDetectHint => '自动判断是否全秘境里的首条通道';

  @override
  String get wizardDetectFailed => '暂时无法连接服务器，正在自动重试…';

  @override
  String wizardProbeConnecting(String server) {
    return '正在连接 $server…';
  }

  @override
  String get wizardNameHint => '我的名字（以后可以随时修改）';

  @override
  String get wizardPeerNameHint => '伴侣的名字（以后可以随时修改）';

  @override
  String get wizardPeerNameHintInput => '伴侣的昵称';

  @override
  String get wizardNameRequired => '请填写我的名字';

  @override
  String get wizardPeerNameRequired => '请填写伴侣的名字';

  @override
  String get wizardPeerNameSameName => '两人的名字不能相同';

  @override
  String get wizardNameInvalidError => '名字只能用中文字、英文字母、数字、下划线(_)、中划线(-)和表情符。';

  @override
  String wizardNameTooLongError(int max) {
    return '名字最多 $max 个字符';
  }

  @override
  String get wizardNameHintInput => '我的昵称';

  @override
  String get wizardMyGenderLabel => '我的性别';

  @override
  String get wizardPeerGenderLabel => '伴侣的性别';

  @override
  String get wizardGenderMale => '男';

  @override
  String get wizardGenderFemale => '女';

  @override
  String get wizardGenderRequired => '请选择性别';

  @override
  String get wizardAppBarCreate => '创建秘境';

  @override
  String get wizardAppBarJoin => '加入秘境';

  @override
  String get wizardAppBarOffline => '导入密保信封';

  @override
  String get wizardNext => '下一步';

  @override
  String get wizardBack => '上一步';

  @override
  String get wizardDone => '完成';

  @override
  String get wizardTitleName => '关于我';

  @override
  String get wizardTitlePeerName => '关于伴侣';

  @override
  String get wizardTitleJoinIdentity => '选择身份';

  @override
  String get wizardJoinIdentityHint => '一个秘境仅限两人，你是哪一位？';

  @override
  String get wizardJoinNoSlots => '该秘境未预置成员身份，无法加入';

  @override
  String get wizardSlotRequired => '必须选择一个身份';

  @override
  String get wizardSpaceLimit => '秘境数量已达上限（服务器 maxSpaces 限制），暂不能新建秘境';

  @override
  String get wizardTitlePassphrase => '设置共享口令';

  @override
  String get wizardJoinPassphraseTitle => '验证共享口令';

  @override
  String get wizardTitlePin => '设置锁屏码';

  @override
  String get wizardTitleEnvelope => '解析密保信封';

  @override
  String get wizardEnrollExists =>
      '该服务器已有秘境（由另一条通道创建）。请改用“加入”向导，凭对方提供的一次性开通码加入。';

  @override
  String get wizardEnrollGoJoin => '改用“加入”向导';

  @override
  String wizardEnrollFailed(String error) {
    return '❌ 登记失败: $error';
  }

  @override
  String get wizardPassphraseHint =>
      '共享口令由你和伴侣共同持有，用于保护私密消息。务必牢记，不可泄漏；只可与秘境伴侣分享。';

  @override
  String get wizardPassphraseMinLengthHint => '至少 8 位';

  @override
  String get wizardPassphraseTooShort => '口令不得少于 8 位';

  @override
  String get wizardPassphraseConfirmHint => '再输一次以确认';

  @override
  String get wizardPassphraseMismatch => '两次输入的口令不一致';

  @override
  String get wizardJoinPassphraseHint =>
      '共享口令由你和伴侣共同持有，用于保护私密消息。不知道口令？询问你的秘境伴侣。';

  @override
  String get wizardJoinPassphraseWrong => '口令错误：请确认首条通道创建时设置的口令';

  @override
  String get wizardSwitchToEnvelope => '改用线下密保信封';

  @override
  String get wizardSwitchToPassphrase => '改用共享口令';

  @override
  String get wizardPinHint => '每次启动秘境，需输入锁屏码才能进入。当前也可先跳过，进入秘境后能够随时设置。';

  @override
  String get welcomeDialogTitleCreate => '一切就绪！';

  @override
  String get welcomeDialogTitleJoin => '一切就绪！';

  @override
  String get welcomeDialogMessage => '仅限两人，所有消息端到端加密，确保绝对隐私！';

  @override
  String get welcomeDialogStart => '进入秘境';

  @override
  String setupPageKeyGenFailed(String error) {
    return '❌ 密钥生成失败: $error';
  }

  @override
  String get setupEntryTitle => '秘境向导';

  @override
  String get setupEntryHint => '秘境是仅限两人的私密世界，可以从头创建，或者受邀加入。';

  @override
  String get setupEntryCreate => '创建秘境';

  @override
  String get setupEntryJoin => '加入秘境';

  @override
  String get setupEntryLegacyServer => '服务器版本过低，请升级后再使用';

  @override
  String setupTokenAppTooOld(String code) {
    return '本机 App 版本过旧，与服务器对不上（$code）。请更新 App 后重试';
  }

  @override
  String setupTokenRateLimited(String seconds) {
    return '请求太频繁：请 $seconds 秒后再试（这不是开通码本身的问题）';
  }

  @override
  String get setupTokenRateLimitedNoWait => '请求太频繁，请稍后再试（这不是开通码本身的问题）';

  @override
  String get setupTokenTitle => '验证开通码';

  @override
  String get setupTokenHint => '开启本机到秘境的专属通道。开通码 24 小时内一次性有效，可从本秘境任一已认证的通道生成。';

  @override
  String get setupTokenInputHint => '开通码或邀请链接';

  @override
  String get setupTokenNeedInput => '请填写开通码';

  @override
  String get setupTokenInvalid => '开通码无效';

  @override
  String get setupTokenExpired => '开通码已过期';

  @override
  String get setupTokenUsed => '开通码已被使用';

  @override
  String get setupTokenSpaceAlreadyAdded => '这个秘境已经添加过了（一台设备只能有一条通道到同一个秘境）';

  @override
  String setupTokenOtherServer(String other, String current) {
    return '该邀请链接来自 $other，本机连的是 $current，不能混用';
  }

  @override
  String get setupCreateShareTitle => '快把邀请链接发给伴侣，一起体验秘境吧';

  @override
  String get setupCreateCopy => '复制邀请链接';

  @override
  String get setupCreateCopied => '已复制';

  @override
  String get setupPageInitFailed => '初始化失败，正在自动重试…';

  @override
  String get startupInitFailed => '启动初始化失败，配置未丢失，请重试';

  @override
  String get startupInitRetry => '重试';

  @override
  String get startupInitClearData => '清除本机数据并重来';

  @override
  String get startupInitClearDataTitle => '清除本机数据？';

  @override
  String get startupInitClearDataMessage =>
      '这会清除本机全部本地数据（秘境、消息、附件、锁屏码与密钥），并回到入网向导。仅在反复重试仍失败时使用——不可恢复。';

  @override
  String get startupInitClearedRestart => '本机数据已清除。请完全退出并重新打开 App。';

  @override
  String get setupPagePasteEnvelope => '⚠️ 请粘贴密保信封（base64）';

  @override
  String get setupPageScanInvite => '扫码填入开通码';

  @override
  String get setupPageScannerHint => '把开通码二维码对准取景框';

  @override
  String get setupPageNoEscrow => '❌ 服务器上找不到共享口令的密保箱，无法凭口令加入。请尝试其他方式。';

  @override
  String setupPageEscrowFailed(String error) {
    return '❌ 共享口令验证失败。请询问你的伴侣。';
  }

  @override
  String get setupJoinEntranceLimitReached => '该秘境的通道数量已达服务器上限，无法再开通新通道。';

  @override
  String get setPinDialogPinLabel => '新 PIN（至少 6 位数字）';

  @override
  String get setPinDialogPinHint => '至少 6 位数字';

  @override
  String get setPinDialogConfirmLabel => '确认新 PIN';

  @override
  String get setPinDialogConfirmHint => '再输一次以确认';

  @override
  String get setPinDialogSetPin => '提交';

  @override
  String get setPinDialogPinTooShort => 'PIN 至少 6 位数字';

  @override
  String get setPinDialogPinDigitsOnly => 'PIN 只能是数字';

  @override
  String get setPinDialogPinMismatch => '两次输入的 PIN 不一致';

  @override
  String get setPinDialogOldWrong => '当前锁屏码错误';

  @override
  String get verifyPinRequired => '请输入锁屏码以验证';

  @override
  String get verifyPinWrong => '锁屏码错误';

  @override
  String setPinDialogSetupFailed(String error) {
    return '设置失败: $error';
  }

  @override
  String chatPageLocaleSwitched(String label) {
    return '已切换：$label';
  }

  @override
  String get chatPageSetLockTitle => '设置锁屏码';

  @override
  String get chatPageSetLockClearHint => '设置后，每次进入秘境都要解锁。也可设为空，即可删除当前锁屏码。';

  @override
  String get chatPageSetLockHintNoPin => '设置后，每次进入秘境都要解锁，更安全。';

  @override
  String get chatPageSetLockOldLabel => '当前锁屏码';

  @override
  String get chatPageSetLockOldRequired => '请先输入当前锁屏码';

  @override
  String get chatPageSetLockSameAsOld => '新锁屏码与当前锁屏码相同，未作修改';

  @override
  String get chatPageSetLockNoPinNotice => '锁屏码仍然为空，下次启动应用可直接进入秘境。';

  @override
  String get chatPageSetLockDone => '锁屏码已设置，下次启动需解锁';

  @override
  String get chatPageSetLockCleared => '已删除锁屏码，下次启动应用可直接进入秘境。';

  @override
  String get chatPageClearLockTitle => '删除锁屏码？';

  @override
  String get chatPageClearLockMessage => '确定要删除锁屏码吗？删除后下次启动将直接进入聊天。';

  @override
  String get chatPageMenuInvite => '生成开通码';

  @override
  String get chatPageInviteDialogTitle => '开通码已生成';

  @override
  String get chatPageInviteRegenerate => '重新生成';

  @override
  String get chatPageInviteDialogHint =>
      '发送给伴侣或自己的其他设备，开启一条新通道加入当前秘境。24 小时内一次性有效。';

  @override
  String get chatPageInviteCopyLinkTooltip => '复制邀请链接';

  @override
  String get chatPageInviteCopyCodeTooltip => '复制开通码';

  @override
  String get chatPageInviteLinkCopied => '邀请链接已复制';

  @override
  String get chatPageInviteCodeCopied => '开通码已复制';

  @override
  String chatPageInviteFailed(String error) {
    return '开通码生成失败: $error';
  }

  @override
  String get chatPageTitleBrand => '我的秘境';

  @override
  String get chatPageMenuChangePassphrase => '修改共享口令';

  @override
  String get chatPageMenuAvatar => '我的头像';

  @override
  String get chatPageAvatarUploaded => '✅ 头像已更新';

  @override
  String get chatPageAvatarTooLarge => '图片过大（最大 2MB）';

  @override
  String chatPageAvatarFailed(String error) {
    return '头像上传失败: $error';
  }

  @override
  String get chatPageNameUnset => '未设置';

  @override
  String get chatPageMenuExit => '退出本应用';

  @override
  String get chatPageMenuMore => '菜单';

  @override
  String get chatPageRenameNameTitle => '我的身份';

  @override
  String get chatPageRenameNameLabel => '名字';

  @override
  String get chatPageGenderLabel => '性别';

  @override
  String get chatPageRenameEntranceTitle => '当前通道';

  @override
  String get chatPageRenameEntranceLabel => '通道名称';

  @override
  String get chatPageEntranceScopeHint => '通道是设备连接到秘境的专属线路。当前通道的设置仅对本机和当前秘境有效。';

  @override
  String get chatPageRenameEntranceEmptyError => '请填写通道名称';

  @override
  String get chatPageRenameEntranceInvalidError =>
      '只能用中文字、英文字母、数字、下划线(_)、中划线(-)';

  @override
  String chatPageRenameEntranceTooLongError(int max) {
    return '最多 $max 个字符';
  }

  @override
  String get chatPageRenameMyselfEmptyError => '请填写名字';

  @override
  String get chatPageRenameNameInvalidError =>
      '只能用中文字、英文字母、数字、下划线(_)、中划线(-)和表情符';

  @override
  String chatPageRenameNameTooLongError(int max) {
    return '最多 $max 个字符';
  }

  @override
  String get chatPageRenameSameAsPeerError => '不能与对方同名，请换个名字';

  @override
  String get chatPageCopy => '复制';

  @override
  String get chatPagePublicKeyCopied => '已复制公钥';

  @override
  String get chatPageEdit => '编辑';

  @override
  String chatPageRenameFailed(String error) {
    return '修改失败: $error';
  }

  @override
  String get chatPageExitTitle => '退出本应用？';

  @override
  String get chatPageExitMessage => '即将关闭本应用。';

  @override
  String get save => '保存';

  @override
  String get chatPageChangePassphraseTitle => '修改共享口令';

  @override
  String get chatPageChangePassphraseSubmit => '修改';

  @override
  String get chatPageChangePassphraseOldLabel => '当前口令';

  @override
  String get chatPageChangePassphraseNewLabel => '新口令';

  @override
  String get chatPageChangePassphraseConfirmLabel => '确认新口令';

  @override
  String get chatPagePassphraseRevealTip => '查看明文（3 秒后自动变回暗码）';

  @override
  String get chatPageChangePassphraseMismatch => '两次输入的新口令不一致';

  @override
  String get chatPageChangePassphraseSame => '新口令不能与当前口令相同';

  @override
  String get chatPageChangePassphraseOldRequired => '请先输入当前口令';

  @override
  String get chatPageChangePassphraseOldWrong => '当前口令错误';

  @override
  String get chatPageChangePassphraseDone => '✅ 共享口令已修改（请告知伴侣，以后必须使用新口令）';

  @override
  String chatPageChangePassphraseFailed(String error) {
    return '修改口令失败: $error';
  }

  @override
  String get chatPageEscrowRotatedNotice => '伴侣已重设共享口令，以后必须使用新口令';

  @override
  String get chatPageMenuLocaleLabel => '界面语言';

  @override
  String get chatPageMenuAttachmentStorage => '附件存储';

  @override
  String get chatPageAttachmentStorageSecured => '远程托管';

  @override
  String get chatPageAttachmentStorageSecuredDesc =>
      '每次打开都重新下载并解密，本机不留明文副本，更私密。';

  @override
  String get chatPageAttachmentStorageStored => '本地留存';

  @override
  String get chatPageAttachmentStorageStoredDesc =>
      '第一次下载时保存明文副本，以后本机可直接打开，更方便。';

  @override
  String get chatPageAttachmentStorageSubmit => '提交';

  @override
  String get chatPageAttachmentStorageWarnClear => '切到「远程托管」会立即删除本机已留存的附件明文';

  @override
  String get chatPageMenuStyleLabel => '界面主题';

  @override
  String get chatPageUiStylePlain => '素雅纯色';

  @override
  String get chatPageUiStylePlainDesc => '浅粉纯色背景，清淡优雅';

  @override
  String get chatPageUiStyleGradient => '渐变粉蓝';

  @override
  String get chatPageUiStyleGradientDesc => '粉蓝渐变背景，深情典雅';

  @override
  String get chatPageMenuBurnLabel => '阅后即焚';

  @override
  String get chatPageMenuMyNameLabel => '我的身份';

  @override
  String get chatPageMenuEntranceNameLabel => '当前通道';

  @override
  String get chatPageMenuEntranceList => '通道列表';

  @override
  String get chatPageEntranceListFailed => '无法获取其他通道（当前离线？）';

  @override
  String get chatPageEntranceTagLocal => '本机';

  @override
  String get chatPageEntranceTagOnline => '在线';

  @override
  String get chatPageEntranceTagOffline => '离线';

  @override
  String get chatPageEntranceTagRevoked => '已撤销';

  @override
  String get chatPageEntranceListNew => '新建通道';

  @override
  String chatPageEntranceSince(Object time) {
    return 'since $time';
  }

  @override
  String get chatPagePinLabel => '锁屏码';

  @override
  String get chatPageLockNow => '锁屏';

  @override
  String get chatPagePinSetValue => '已设置';

  @override
  String get chatPageBurnHeading => '阅后即焚';

  @override
  String get chatPageBurnOff => '阅后即焚已关闭（消息永久保留）';

  @override
  String get chatPageBurnFailed => '设置阅后即焚失败';

  @override
  String chatPageBurnWillDelete(String duration) {
    return '新的消息将在 $duration 后自动删除';
  }

  @override
  String get chatPageActionDelete => '立刻删除';

  @override
  String get chatPageActionQuote => '引用';

  @override
  String get chatPageActionBurn => '阅后即焚';

  @override
  String get chatPageDeleteConfirmTitle => '删除消息';

  @override
  String get chatPageDeleteConfirmMessage =>
      '删除后仅在本机消失，对方不受影响，且无法恢复。确定删除这条消息吗？';

  @override
  String get chatPageDeleteCancel => '取消';

  @override
  String get chatPageDeleteConfirmOk => '删除';

  @override
  String chatPageSendFailed(String error) {
    return '发送失败: $error';
  }

  @override
  String get chatPageMsgSent => '已发送';

  @override
  String get chatPageMsgSendingTap => '发送中，点击验证是否已送达并重发';

  @override
  String get chatPageMsgDelivered => '已送达';

  @override
  String get chatPageMsgFailed => '发送失败，点击重试';

  @override
  String get chatPageMsgFailedTap => '点击重发';

  @override
  String chatPageOfflineUnsent(int count) {
    return '离线 · $count 条待发送';
  }

  @override
  String get chatPageEntranceUnrecognized =>
      '这条通道未被服务器识别（服务器数据可能已重置）· 仅可查看本地消息，联网功能暂停；本地数据未清除';

  @override
  String get chatPageOfflineLocalOnly => '离线 · 仅可查看本地消息，无法收发';

  @override
  String get chatPageMsgResending => '重发中…';

  @override
  String get chatPageMsgSpeedingUp => '加速中…';

  @override
  String chatPageVoiceStartFailed(String error) {
    return '录音启动失败: $error';
  }

  @override
  String chatPageVoiceFailed(String error) {
    return '录音失败: $error';
  }

  @override
  String get chatPageVoicePermissionDenied => '麦克风权限被拒绝，请到系统设置里开启。';

  @override
  String get chatPageVoiceEmpty => '录音内容为空，已丢弃。';

  @override
  String get chatPageLongPressToRecord => '长按开始录音';

  @override
  String get chatPageInputHint => '输入消息…';

  @override
  String get chatPageAudioMetaMissing => '音频附件元数据缺失';

  @override
  String chatPageAudioPlayFailed(String error) {
    return '音频播放失败';
  }

  @override
  String get chatPageAttachEmoji => '表情符';

  @override
  String get chatPageEmojiKeyboard => '键盘';

  @override
  String get chatPageAttachPhoto => '拍照';

  @override
  String get chatPageAttachGalleryImage => '相册图片';

  @override
  String get chatPageAttachVideoCamera => '拍视频';

  @override
  String get chatPageAttachVideoGallery => '相册视频';

  @override
  String get chatPageAttachAudioFile => '音频文件';

  @override
  String get chatPageAttachAnyFile => '任意文件';

  @override
  String get chatPagePlaying => '播放中…';

  @override
  String get chatPageVoiceLabel => '语音';

  @override
  String get chatPageAttachmentMetaMissing => '附件元数据缺失';

  @override
  String chatPageSaved(String path) {
    return '已保存: $path';
  }

  @override
  String chatPageDownloadFailed(String error) {
    return '下载失败: $error';
  }

  @override
  String get chatPageAttachmentTapToDownload => '附件不在本机，点击重新下载';

  @override
  String get chatPageVideoLoadFailed => '视频加载失败，点击重试';

  @override
  String chatPageFileOpenFailed(String error) {
    return '打开文件失败: $error';
  }

  @override
  String get chatPageEntranceRevoked => '这条通道已被撤销，本地数据已清除，请重新配置';

  @override
  String get chatPageEntrancePublicKeyLabel => '通道公钥';

  @override
  String get chatPageEntrancePublicKeyFailed => '未记录';

  @override
  String get burnOptionOff => '关闭';

  @override
  String get burnOption1Minute => '1 分钟';

  @override
  String get burnOption5Minutes => '5 分钟';

  @override
  String get burnOption1Hour => '1 小时';

  @override
  String get burnOption1Day => '1 天';

  @override
  String get burnOption7Days => '7 天';

  @override
  String get lockPageTitle => '我的秘境';

  @override
  String get lockPagePinPrompt => '输入锁屏码';

  @override
  String lockPageLockedSeconds(int seconds) {
    return '已锁定 $seconds 秒';
  }

  @override
  String get lockPageNoPinSet => '尚未设置锁屏码（为空时不启用）';

  @override
  String get lockPageUnlock => '解锁';

  @override
  String lockPageTooManyAttempts(int seconds) {
    return '尝试次数过多，请 $seconds 秒后再试';
  }

  @override
  String lockPageUnlockFailed(String error) {
    return '解锁失败: $error';
  }

  @override
  String get chatPageMenuAbout => '关于秘境';

  @override
  String get aboutPageTitle => '关于秘境';

  @override
  String get aboutIntro =>
      '秘境是仅限两人的私密聊天和共享空间，端到端加密所有消息和附件，没有任何第三方（包括秘境自身）能够读到内容，严格保障隐私安全。';

  @override
  String get aboutVersionLabel => '版本号';

  @override
  String get aboutServerLabel => '服务器地址';

  @override
  String get aboutServerDevNote => '开发地址（非生产），仅用于开发调试';

  @override
  String get advancedMenuTitle => '高级安全';

  @override
  String get advancedDestroyEntrance => '销毁本通道';

  @override
  String get leaveSpaceTitle => '销毁本通道？';

  @override
  String get leaveSpaceMessage =>
      '彻底删除当前秘境在本机上的全部消息、附件和凭证，并回到秘境向导页。秘境本身及其数据仍在，其他通道不受影响。此操作无法撤销！';

  @override
  String resetEntranceNameLabel(String name) {
    return '$name';
  }

  @override
  String resetEntranceNameHint(String name) {
    return '请输入当前通道名称“$name”';
  }

  @override
  String get resetEntranceNameMismatch => '请输入正确的通道名称以确认';

  @override
  String get resetEntranceConfirmWord => '重置';

  @override
  String get resetEntrancePinLabel => '锁屏码';

  @override
  String get resetEntrancePinHint => '请输入本机锁屏码';

  @override
  String get resetEntranceServerResidualHint =>
      '⚠️ 本地数据已清除，但服务端退役未完成，对方的通道列表里可能仍留有这条通道';

  @override
  String get spaceListTitle => '切换我的秘境';

  @override
  String get spaceListEmpty => '还没有加入任何秘境';

  @override
  String get spaceListAdd => '添加秘境';

  @override
  String get spaceListSwitch => '切换我的秘境';

  @override
  String get promptLockCodeTitle => '输入锁屏码';

  @override
  String get promptLockCodeHint => '请先验证本机锁屏码';

  @override
  String get leaveSpaceConfirm => '销毁';

  @override
  String get setupPinReuseNotice => '本秘境将共用当前的锁屏码。';
}
