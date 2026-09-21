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
  String get setupPageNeedPassphrase => '❗️ 必须设置密保口令';

  @override
  String get wizardJoinPassphraseRequired => '❗️ 请输入密保口令进行验证';

  @override
  String get setupEnrollBoundNotice => '🎉 新设备已成功绑定';

  @override
  String get wizardStartTitle => '秘境入口';

  @override
  String get wizardDetectTitle => '正在检测服务器状态…';

  @override
  String get wizardDetectHint => '自动判断是否全秘境里的首个设备';

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
  String get wizardInviteHint => '邀请码可由任意一个已绑定设备生成，24 小时内一次性有效。';

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
  String get wizardTitleInvite => '验证邀请码';

  @override
  String get wizardTitlePassphrase => '设置密保口令';

  @override
  String get wizardJoinPassphraseTitle => '验证密保口令';

  @override
  String get wizardTitlePin => '设置锁屏码';

  @override
  String get wizardTitleEnvelope => '解析密保信封';

  @override
  String get wizardTitleIdentity => '我是';

  @override
  String get wizardEnrollExists =>
      '该服务器已有空间（由其他设备创建）。请改用“加入”向导，凭对方提供的一次性邀请码加入。';

  @override
  String get wizardEnrollGoJoin => '改用“加入”向导';

  @override
  String wizardEnrollFailed(String error) {
    return '❌ 登记失败: $error';
  }

  @override
  String get wizardPassphraseHint =>
      '口令对所有消息进行加密，保障隐私安全。务必牢记，严禁泄漏！仅可将口令分享给秘境伴侣。';

  @override
  String get wizardPassphraseMinLengthHint => '至少 8 位';

  @override
  String get wizardPassphraseTooShort => '口令不得少于 8 位';

  @override
  String get wizardPassphraseConfirmHint => '再输一次以确认';

  @override
  String get wizardPassphraseMismatch => '两次输入的口令不一致';

  @override
  String get wizardJoinPassphraseHint => '口令是与伴侣共享的密码，用于保护私密消息。如果不知道口令，请询问伴侣。';

  @override
  String get wizardJoinPassphraseWrong => '口令错误：请确认首台设备创建时设置的口令';

  @override
  String get wizardSwitchToEnvelope => '改用线下密保信封';

  @override
  String get wizardSwitchToPassphrase => '改用线上密保口令';

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
  String get setupEntryTitle => '选择秘境入口';

  @override
  String get setupEntryHint => '秘境是仅限两人的私密世界，可以从头创建，或者受邀加入。';

  @override
  String get setupEntryCreate => '创建秘境';

  @override
  String get setupEntryJoin => '加入秘境';

  @override
  String get setupEntryLegacyServer => '服务器版本过低，请升级后再使用';

  @override
  String get setupTokenTitle => '验证邀请码';

  @override
  String get setupTokenHint => '填写邀请码，24小时内一次性有效';

  @override
  String get setupTokenInputHint => '邀请码';

  @override
  String get setupTokenNeedInput => '必须填写邀请码';

  @override
  String get setupTokenInvalid => '无效的邀请码';

  @override
  String get setupTokenExpired => '邀请码已过期';

  @override
  String get setupTokenUsed => '邀请码已被使用';

  @override
  String get setupTokenSpaceFull => '空间已满';

  @override
  String setupTokenSpaceInfo(String name) {
    return '加入 $name 的空间';
  }

  @override
  String get setupTokenSpacePrivate => '加入私密空间（等待第二位成员）';

  @override
  String get setupCreateShareTitle => '转发邀请链接给伴侣';

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
  String get setupPageInviteHint => '输入邀请码';

  @override
  String get setupPageNeedInvite => '⚠️ 填写一次性邀请码';

  @override
  String get setupPageScanInvite => '扫码填入邀请码';

  @override
  String get setupPageScannerHint => '将邀请码二维码对准取景框';

  @override
  String get wizardInviteWrong => '邀请码无效。请使用任意一个已绑定设备生成的24小时一次性邀请码。';

  @override
  String get setupPageNoEscrow => '❌ 找不到受托管的口令密保箱，无法凭口令加入。请尝试其他方式。';

  @override
  String setupPageEscrowFailed(String error) {
    return '❌ 口令验证失败。请询问秘境伴侣获得口令。';
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
  String get chatPageClearLockMessage =>
      '新锁屏码留空 = 清空锁屏码——确定要清除吗？清除后下次启动直接进入聊天。';

  @override
  String get chatPageMenuInvite => '邀请码';

  @override
  String get chatPageInviteDialogTitle => '邀请码已生成';

  @override
  String get chatPageInviteDialogHint => '邀请新设备加入当前秘境。24 小时内一次性有效。';

  @override
  String get chatPageInviteCopyLinkTooltip => '复制邀请链接';

  @override
  String get chatPageInviteCopyCodeTooltip => '复制邀请码';

  @override
  String get chatPageInviteLinkCopied => '邀请链接已复制';

  @override
  String get chatPageInviteCodeCopied => '邀请码已复制';

  @override
  String chatPageInviteFailed(String error) {
    return '邀请码生成失败: $error';
  }

  @override
  String get chatPageTitleBrand => '我的秘境';

  @override
  String get chatPageMenuChangePassphrase => '修改口令';

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
  String get chatPageMenuExit => '退出秘境';

  @override
  String get chatPageMenuMore => '菜单';

  @override
  String get chatPageRenameNameTitle => '我的个人资料';

  @override
  String get chatPageRenameNameLabel => '我的名字';

  @override
  String get chatPageGenderLabel => '性别';

  @override
  String get chatPageRenameDeviceTitle => '我的设备信息';

  @override
  String get chatPageRenameDeviceLabel => '设备名称';

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
  String get chatPagePublicKeyCopied => '已复制设备公钥';

  @override
  String get chatPageEdit => '编辑';

  @override
  String chatPageRenameFailed(String error) {
    return '修改失败: $error';
  }

  @override
  String get chatPageExitTitle => '退出秘境？';

  @override
  String get chatPageExitMessage => '即将在本机上退出秘境。';

  @override
  String get save => '保存';

  @override
  String get chatPageChangePassphraseTitle => '修改密保口令';

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
  String get chatPageChangePassphraseDone => '✅ 口令已修改（请告知伴侣，以后必须使用新口令）';

  @override
  String chatPageChangePassphraseFailed(String error) {
    return '修改口令失败: $error';
  }

  @override
  String get chatPageEscrowRotatedNotice => '伴侣已重设密保口令，以后必须使用新口令';

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
  String get chatPageMenuStyleLabel => '界面风格';

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
  String get chatPageMenuDeviceNameLabel => '我的设备';

  @override
  String get chatPagePinLabel => '锁屏码';

  @override
  String get chatPageLockNow => '锁屏';

  @override
  String get chatPagePinSetValue => '已设置';

  @override
  String get chatPagePinUnsetValue => '未设置';

  @override
  String get chatPageBurnHeading => '阅后即焚（仅本设备生效）';

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
      '删除后仅在本机消失，对方设备不受影响，且无法恢复。确定删除这条消息吗？';

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
      '本设备未被服务器识别（服务器数据可能已重置）· 仅可查看本地消息，联网功能暂停；本地数据未清除';

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
  String get chatPageDeviceRevoked => '本设备已被撤销，本地数据已清除，请重新配置';

  @override
  String get chatPageDevicePublicKeyLabel => '设备公钥';

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
  String get advancedResetDevice => '重置设备';

  @override
  String get resetDeviceTitle => '重置设备？';

  @override
  String get resetDeviceMessage =>
      '将清除本设备上的全部消息、附件与密钥，并回到新设备入网步骤。\n\n秘境本身仍保留在服务器上，你和对方的其他设备不受影响。\n\n此操作无法撤销！';

  @override
  String get resetDeviceConfirm => '确认重置';
}
