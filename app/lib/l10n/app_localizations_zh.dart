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
  String get setupPageEnvelopeKeyHint => '密保信封是通过不对称加密，进行线下交接的一段文本。请联系秘境伴侣获取。';

  @override
  String get setupPageNeedPassphrase => '❗️ 必须设置共享口令';

  @override
  String get wizardJoinPassphraseRequired => '❗️ 请输入共享口令进行验证';

  @override
  String get setupEnrollBoundNotice => '🎉 新入口已开通';

  @override
  String get wizardStartTitle => '秘境向导';

  @override
  String get wizardDetectTitle => '正在检测服务器状态…';

  @override
  String get wizardDetectHint => '自动判断是否全秘境里的首个入口';

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
  String get wizardNameRequired => '填写我的名字';

  @override
  String get wizardPeerNameRequired => '填写我的秘境伴侣的名字';

  @override
  String get wizardNameInvalidError => '名字只能用中文字、英文字母、数字、下划线(_)、中划线(-)和表情符';

  @override
  String wizardNameTooLongError(int max) {
    return '名字最多 $max 个字符';
  }

  @override
  String get wizardNameHintInput => '输入我的昵称';

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
  String get wizardIdentityHint => '秘境仅限两人，选择我的身份';

  @override
  String get wizardIdentityCreator => '秘境创建者';

  @override
  String get wizardIdentityPartner => '秘境共有者';

  @override
  String get wizardIdentityFirst => '⚠️ 选择我的身份';

  @override
  String get wizardInviteHint => '令牌可由任意一个已开通的入口生成，24 小时内一次性有效。';

  @override
  String get wizardRoleOffline => '导入线下密保信封';

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
  String get wizardJoinIdentityHint => '一个秘境仅限两人，选择我的名字。';

  @override
  String get wizardJoinNoSlots => '该空间未预置成员身份，无法加入';

  @override
  String get wizardSlotOnline => '已在线';

  @override
  String get wizardSlotRequired => '必须选择一个身份';

  @override
  String get wizardSpaceLimit => '空间数量已达上限（服务器 maxSpaces 限制）——暂不能新建空间';

  @override
  String get wizardTitleInvite => '验证令牌';

  @override
  String get wizardTitlePassphrase => '设置共享口令';

  @override
  String get wizardJoinPassphraseTitle => '验证共享口令';

  @override
  String get wizardTitlePin => '设置锁屏码';

  @override
  String get wizardTitleEnvelope => '解析密保信封';

  @override
  String get wizardTitleIdentity => '我是';

  @override
  String get wizardEnrollExists =>
      '该服务器已有空间（由另一个入口创建）。请改用“加入”向导，凭对方提供的一次性令牌加入。';

  @override
  String get wizardEnrollGoJoin => '改用“加入”向导';

  @override
  String wizardEnrollFailed(String error) {
    return '❌ 登记失败: $error';
  }

  @override
  String get wizardPassphraseHint => '共享口令由你和伴侣共同持有，用于加密所有消息。务必牢记；除伴侣外不要告诉任何人。';

  @override
  String get wizardPassphraseMinLengthHint => '至少 8 位';

  @override
  String get wizardPassphraseTooShort => '口令不得少于 8 位';

  @override
  String get wizardPassphraseConfirmHint => '再输一次以确认';

  @override
  String get wizardPassphraseMismatch => '两次输入的口令不一致';

  @override
  String get wizardJoinPassphraseHint => '共享口令由你和伴侣共同持有，用于保护私密消息。不知道口令？问你的伴侣。';

  @override
  String get wizardJoinPassphraseWrong => '口令错误：请确认首个入口创建时设置的口令';

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
  String get welcomeDialogMessage => '仅限两人，所有消息端到端加密，确保绝对隐私！进入秘境，开始聊天吧。';

  @override
  String get welcomeDialogStart => '进入秘境';

  @override
  String setupPageKeyGenFailed(String error) {
    return '❌ 密钥生成失败: $error';
  }

  @override
  String get setupEntryTitle => '选择秘境';

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
    return '本机 App 版本过旧，与服务器对不上（$code）——请更新 App 后重试';
  }

  @override
  String setupTokenRateLimited(String seconds) {
    return '请求太频繁：请 $seconds 秒后再试（这不是令牌本身的问题）';
  }

  @override
  String get setupTokenRateLimitedNoWait => '请求太频繁，请稍后再试（这不是令牌本身的问题）';

  @override
  String get setupTokenTitle => '验证令牌';

  @override
  String get setupTokenHint => '填写令牌，24 小时内一次性有效';

  @override
  String get setupTokenInputHint => '填写令牌或邀请链接';

  @override
  String get setupTokenNeedInput => '请填写令牌';

  @override
  String get setupTokenInvalid => '令牌无效';

  @override
  String get setupTokenExpired => '令牌已过期';

  @override
  String get setupTokenUsed => '令牌已被使用';

  @override
  String get setupTokenSpaceFull => '空间已满';

  @override
  String setupTokenOtherServer(String other, String current) {
    return '该邀请链接来自 $other，本机连的是 $current，不能混用';
  }

  @override
  String setupTokenSpaceInfo(String name) {
    return '加入 $name 的空间';
  }

  @override
  String get setupTokenSpacePrivate => '加入私密空间（等待第二位成员）';

  @override
  String get setupCreateShareTitle => '把令牌发给对方（也可用在自己的另一台设备上）';

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
  String get setupPagePasteEnvelope => '⚠️ 请粘贴密保信封（base64）';

  @override
  String get wizardEnvelopeWrong => '密保信封无效：请确认对方「导出线下密保信封」的完整内容已粘贴';

  @override
  String get setupPageInviteHint => '输入令牌';

  @override
  String get setupPageNeedInvite => '⚠️ 填写一次性令牌';

  @override
  String get setupPageScanInvite => '扫码填入令牌';

  @override
  String get setupPageScannerHint => '把令牌二维码对准取景框';

  @override
  String get wizardInviteWrong => '令牌无效。请使用任意一个已开通的入口生成的 24 小时一次性令牌。';

  @override
  String get setupPageNoEscrow => '❌ 服务器上找不到共享口令的密保箱，无法凭口令加入。请尝试其他方式。';

  @override
  String setupPageEscrowFailed(String error) {
    return '❌ 共享口令验证失败。请询问你的伴侣。';
  }

  @override
  String get setPinDialogPinLabel => 'PIN（至少 6 位数字）';

  @override
  String get setPinDialogPinHint => '至少 6 位数字';

  @override
  String get setPinDialogConfirmLabel => '确认 PIN';

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
  String get chatPageSetLockClearHint =>
      '设置后，每次进入秘境都要解锁，更安全。修改或清空都需先输入当前锁屏码；新锁屏码留空 = 清空。';

  @override
  String get chatPageSetLockHintNoPin => '设置后，每次进入秘境都要解锁，更安全。';

  @override
  String get chatPageSetLockOldLabel => '当前锁屏码';

  @override
  String get chatPageSetLockOldRequired => '请先输入当前锁屏码';

  @override
  String get chatPageSetLockSameAsOld => '新锁屏码与当前锁屏码相同，未作修改';

  @override
  String get chatPageSetLockNoPinNotice => '锁屏码为空，下次启动可直接进入秘境';

  @override
  String get chatPageSetLockDone => '锁屏码已设置，下次启动需解锁';

  @override
  String get chatPageSetLockCleared => '已清空锁屏码（下次启动直接进入）';

  @override
  String get chatPageClearLockTitle => '清空锁屏码？';

  @override
  String get chatPageClearLockMessage => '新锁屏码留空 = 清空锁屏码。确定要清除吗？清除后下次启动直接进入聊天。';

  @override
  String get chatPageMenuInvite => '新入口令牌';

  @override
  String get chatPageInviteDialogTitle => '令牌已生成';

  @override
  String get chatPageInviteDialogHint =>
      '一次性令牌：凭它可以开通一个新入口（给对方，也可给自己的另一台设备）。24 小时内有效。';

  @override
  String get chatPageInviteCopyLinkTooltip => '复制邀请链接';

  @override
  String get chatPageInviteCopyCodeTooltip => '复制令牌';

  @override
  String get chatPageInviteLinkCopied => '邀请链接已复制';

  @override
  String get chatPageInviteCodeCopied => '令牌已复制';

  @override
  String chatPageInviteFailed(String error) {
    return '令牌生成失败: $error';
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
  String get chatPageRenameNameTitle => '我的个人资料';

  @override
  String get chatPageRenameNameLabel => '我的名字';

  @override
  String get chatPageGenderLabel => '性别';

  @override
  String get chatPageRenameDeviceTitle => '入口信息（本秘境）';

  @override
  String get chatPageRenameDeviceLabel => '入口名称';

  @override
  String get chatPageDeviceScopeHint => '这个入口的名称与公钥只属于当前秘境——同一台机器在别的秘境是另一套入口。';

  @override
  String get chatPageRenameDeviceEmptyError => '名称不能为空';

  @override
  String get chatPageRenameDeviceInvalidError => '只能用中文字、英文字母、数字、下划线(_)、中划线(-)';

  @override
  String chatPageRenameDeviceTooLongError(int max) {
    return '最多 $max 个字符';
  }

  @override
  String get chatPageRenameMyselfEmptyError => '名字不能为空';

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
  String get chatPageChangePassphraseOldLabel => '旧口令';

  @override
  String get chatPageChangePassphraseNewLabel => '新口令';

  @override
  String get chatPageChangePassphraseConfirmLabel => '确认新口令';

  @override
  String get chatPagePassphraseRevealTip => '查看明文（3 秒后自动变回暗码）';

  @override
  String get chatPageChangePassphraseMismatch => '两次输入的新口令不一致';

  @override
  String get chatPageChangePassphraseSame => '新口令与旧口令相同，未作修改';

  @override
  String get chatPageChangePassphraseOldWrong => '旧口令错误';

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
      '每次打开附件都重新下载并解密，本机不留明文副本，更私密';

  @override
  String get chatPageAttachmentStorageStored => '本地留存';

  @override
  String get chatPageAttachmentStorageStoredDesc =>
      '第一次下载附件时保存明文副本，以后本机可直接打开，更方便';

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
  String get chatPageMenuDeviceNameLabel => '入口名称';

  @override
  String get chatPagePinLabel => '锁屏码';

  @override
  String get chatPageLockNow => '锁屏';

  @override
  String get chatPagePinSetValue => '已设置';

  @override
  String get chatPagePinUnsetValue => '未设置';

  @override
  String get chatPageBurnHeading => '阅后即焚（仅本机生效）';

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
  String get chatPageMsgSending => '发送中…';

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
  String get chatPageDeviceUnrecognized =>
      '这个入口未被服务器识别（服务器数据可能已重置）· 仅可查看本地消息，联网功能暂停；本地数据未清除';

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
  String get chatPageVideoMetaMissing => '视频附件元数据缺失';

  @override
  String chatPageVideoPlayFailed(String error) {
    return '视频播放失败: $error';
  }

  @override
  String chatPageImageLoadFailed(String plaintext) {
    return '$plaintext\n（加载失败）';
  }

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
  String get chatPageDeviceRevoked => '这个入口已被撤销，本地数据已清除，请重新配置';

  @override
  String get chatPageDevicePublicKeyLabel => '入口公钥';

  @override
  String get chatPageDevicePublicKeyFailed => '未记录';

  @override
  String get burnOptionKeepIndefinitely => '不设期限';

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
  String get lockPagePinLabel => '锁屏码';

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
  String get advancedMenuTitle => '高级';

  @override
  String get advancedLeaveSpace => '销毁本秘境入口';

  @override
  String get leaveSpaceTitle => '销毁本秘境入口？';

  @override
  String get leaveSpaceMessage =>
      '将销毁本机在这个秘境里的入口，并清除本机上的聊天记录与密钥。\n\n秘境本身与服务器上的数据都还在，其他空间也不受影响——以后凭新的令牌可以重新加入。\n\n此操作无法撤销！';

  @override
  String resetDeviceNameLabel(String name) {
    return '输入「$name」以确认';
  }

  @override
  String get resetDeviceNameMismatch => '输入不符，请重输';

  @override
  String get resetDeviceConfirmWord => '重置';

  @override
  String get resetDevicePinLabel => '本机锁屏码';

  @override
  String get resetDeviceServerResidualHint =>
      '⚠️ 本地数据已清除，但服务端退役未完成——对方的入口列表里可能仍留有这个入口';

  @override
  String get spaceListTitle => '我的空间';

  @override
  String get spaceListEmpty => '还没有加入任何空间';

  @override
  String get spaceListAdd => '新建/加入空间';

  @override
  String get spaceListSwitch => '切换空间';

  @override
  String get promptLockCodeTitle => '输入锁屏码';

  @override
  String get promptLockCodeHint => '新增空间要写入加密锁包，先验证本机锁屏码';

  @override
  String get spaceListDeleteConfirm => '移除';

  @override
  String spaceListMe(String name) {
    return '我：$name';
  }

  @override
  String get setupPinReuseNotice => '该空间将沿用你当前的锁屏码。';
}
