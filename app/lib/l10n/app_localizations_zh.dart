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
  String get setupPageEnvelopeKeyHint => '粘贴密保信封（envelope-*.txt 内容）';

  @override
  String get setupPageNeedPassphrase => '⚠️ 先在上方填写密保口令';

  @override
  String get setupEnrollBoundNotice => '🎉 新设备已成功绑定';

  @override
  String get wizardStartTitle => '寻找秘境...';

  @override
  String get wizardDetectTitle => '正在检测服务器状态…';

  @override
  String get wizardDetectHint => '自动判断你是第几个用户（首个设备将创建空间）';

  @override
  String get wizardDetectFailed => '暂时无法连接服务器，正在自动重试…';

  @override
  String get wizardNameHint => '请输入我的名字（将来可以随时修改）。';

  @override
  String get wizardPeerNameHint => '填写伴侣的名字（将来可以随时修改）：';

  @override
  String get wizardPeerNameHintInput => '例如 Alice';

  @override
  String get wizardNameRequired => '填写我的名字';

  @override
  String get wizardPeerNameRequired => '填写伴侣的名字';

  @override
  String get wizardNameHintInput => '例如 Lukas';

  @override
  String get wizardIdentityHint => '一个秘境仅限两人。';

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
  String get wizardAppBarCreate => 'Einz 秘境';

  @override
  String get wizardAppBarJoin => 'Einz 秘境';

  @override
  String get wizardAppBarOffline => '导入密保信封';

  @override
  String get wizardNext => '下一步';

  @override
  String get wizardBack => '上一步';

  @override
  String get wizardDone => '完成';

  @override
  String get wizardStepShortEnvelope => '密保信封';

  @override
  String get wizardTitleName => '我的名字';

  @override
  String get wizardTitlePeerName => '伴侣名字';

  @override
  String get wizardTitleInvite => '邀请码';

  @override
  String get wizardTitlePassphrase => '设置密保口令';

  @override
  String get wizardTitlePin => '设置锁屏码';

  @override
  String get wizardTitleEnvelope => '密保信封';

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
  String get wizardPassphraseHint => '对所有消息进行加密、解密。务必牢记，严禁泄漏！仅可将口令分享给秘境伴侣。';

  @override
  String get wizardJoinPassphraseHint => '对所有消息进行加密、解密。如还不知道口令，询问秘境伴侣。';

  @override
  String get wizardJoinPassphraseWrong => '口令错误：请确认首台设备创建时设置的口令';

  @override
  String get wizardSwitchToEnvelope => '改用线下密保信封';

  @override
  String get wizardSwitchToPassphrase => '改用线上密保口令';

  @override
  String get wizardPinHint => '每次启动需输入此 PIN 解锁';

  @override
  String get welcomeDialogTitleCreate => '🎉 一切就绪！';

  @override
  String get welcomeDialogTitleJoin => '🎉 一切就绪！';

  @override
  String get welcomeDialogMessage => '秘境仅限两人。所有消息端到端加密，确保绝对隐私，开始聊天吧。';

  @override
  String get welcomeDialogStart => '开始聊天';

  @override
  String setupPageKeyGenFailed(String error) {
    return '❌ 密钥生成失败: $error';
  }

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
  String get setupPageInviteHint => '粘贴或输入邀请码';

  @override
  String get setupPageNeedInvite => '⚠️ 填写一次性邀请码（由已认证设备生成）';

  @override
  String get wizardInviteWrong => '邀请码无效：请使用任意一个已绑定设备生成的24小时一次性邀请码';

  @override
  String get setupPageNoEscrow => '❌ Server 无口令密保箱（请先在对端设置接入口令）';

  @override
  String setupPageEscrowFailed(String error) {
    return '❌ 口令接入失败: $error';
  }

  @override
  String get setPinDialogPinLabel => 'PIN（至少 4 位）';

  @override
  String get setPinDialogPinHint => '至少 4 位数字';

  @override
  String get setPinDialogConfirmLabel => '确认 PIN';

  @override
  String get setPinDialogConfirmHint => '再输一遍以确认';

  @override
  String get setPinDialogSetPin => '设置 PIN';

  @override
  String get setupPageSkipPinTitle => '暂不设置锁屏码？';

  @override
  String get setupPageSkipPinMessage => '如果不设锁屏码，本应用启动时将直接进入对话，容易被窃取隐私。确定跳过吗？';

  @override
  String get setPinDialogPinTooShort => 'PIN 至少 4 位';

  @override
  String get setPinDialogPinMismatch => '两次输入的 PIN 不一致';

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
  String get chatPageSetLockClearHint => '可留空直接提交，即可清空 PIN';

  @override
  String get chatPageSetLockDone => '锁屏码已设置，下次启动需解锁';

  @override
  String get chatPageSetLockConfirmTitle => '设置 PIN 锁屏？';

  @override
  String get chatPageSetLockConfirmMessage =>
      '确定要设置 PIN 锁屏吗？设置后每次启动需输入 PIN 解锁。';

  @override
  String get chatPageSetLockCleared => '已清除 PIN 锁屏（下次启动直接进入）';

  @override
  String get chatPageClearLockTitle => '清除 PIN 锁屏？';

  @override
  String get chatPageClearLockMessage =>
      '两个 PIN 输入框均为空——确定要清除锁屏码吗？清除后下次启动直接进入聊天。';

  @override
  String get chatPageMenuInvite => '邀请码';

  @override
  String get chatPageTitleBrand => 'Einz 秘境';

  @override
  String get chatPageMenuChangePassphrase => '密保口令';

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
  String get chatPageRenameNameTitle => '修改我的名字';

  @override
  String get chatPageRenameNameLabel => '新名字';

  @override
  String get chatPageRenameDeviceTitle => '修改设备名称';

  @override
  String get chatPageRenameDeviceLabel => '新设备名';

  @override
  String chatPageRenameFailed(String error) {
    return '修改失败: $error';
  }

  @override
  String get chatPageExitTitle => '退出秘境？';

  @override
  String get chatPageExitMessage => '将在本设备上退出 Einz 秘境。';

  @override
  String get save => '保存';

  @override
  String get chatPageChangePassphraseTitle => '修改口令';

  @override
  String get chatPageChangePassphraseOldLabel => '旧口令';

  @override
  String get chatPageChangePassphraseNewLabel => '新口令';

  @override
  String get chatPageChangePassphraseConfirmLabel => '确认新口令';

  @override
  String get chatPageChangePassphraseMismatch => '两次输入的新口令不一致';

  @override
  String get chatPageChangePassphraseConfirmTitle => '修改密保口令？';

  @override
  String get chatPageChangePassphraseConfirmMessage =>
      '确定要修改密保口令吗？修改后需用新口令解密内容密文。';

  @override
  String get chatPageChangePassphraseOldWrong => '旧口令错误';

  @override
  String get chatPageChangePassphraseNoEscrow => '尚未设置口令（无口令密保箱可修改）';

  @override
  String get chatPageChangePassphraseDone => '✅ 口令已修改（新设备加入时请使用新口令）';

  @override
  String chatPageChangePassphraseFailed(String error) {
    return '修改口令失败: $error';
  }

  @override
  String get chatPageEscrowRotatedNotice => '对方已重设密保口令——生成邀请码或修改口令时将要求输入新口令';

  @override
  String get chatPageMenuLocaleLabel => '界面语言';

  @override
  String get chatPageMenuBurnLabel => '阅后即焚';

  @override
  String get chatPageMenuMyNameLabel => '我的名字';

  @override
  String get chatPageMenuDeviceNameLabel => '我的设备';

  @override
  String get chatPagePinLabel => '锁屏码';

  @override
  String get chatPagePinSetValue => '已设置';

  @override
  String get chatPagePinUnsetValue => '未设置';

  @override
  String get chatPageBurnHeading => '阅后即焚（仅本设备生效）';

  @override
  String get chatPageBurnOff => '阅后即焚已关闭（消息永久保留）';

  @override
  String chatPageBurnWillDelete(String duration) {
    return '消息将在 $duration 后自动删除';
  }

  @override
  String get chatPageBurnBadge => '⏱ 阅后即焚';

  @override
  String chatPageSendFailed(String error) {
    return '发送失败: $error';
  }

  @override
  String chatPageVoiceStartFailed(String error) {
    return '录音启动失败: $error';
  }

  @override
  String chatPageVoiceFailed(String error) {
    return '录音失败: $error';
  }

  @override
  String get chatPageLongPressToRecord => '长按即可录音';

  @override
  String get chatPageInputHint => '输入消息…';

  @override
  String get chatPageAudioMetaMissing => '音频附件元数据缺失';

  @override
  String chatPageAudioPlayFailed(String error) {
    return '音频播放失败: $error';
  }

  @override
  String get chatPageAttachPhoto => '拍照';

  @override
  String get chatPageAttachGalleryImage => '相册图片';

  @override
  String get chatPageAttachVideoCamera => '拍摄视频';

  @override
  String get chatPageAttachVideoGallery => '相册视频';

  @override
  String get chatPageAttachAudioFile => '音频文件（mp3 等）';

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
  String get chatPageDeviceRevoked => '设备已被撤销，本地数据已清除，请重新配置';

  @override
  String get burnOptionUnlimited => '无限';

  @override
  String get burnOption1Minute => '1 分钟';

  @override
  String get burnOption5Minutes => '5 分钟';

  @override
  String get burnOption30Minutes => '30 分钟';

  @override
  String get burnOption1Hour => '1 小时';

  @override
  String get burnOption1Day => '1 天';

  @override
  String get burnOption7Days => '7 天';

  @override
  String get lockPageTitle => 'Einz 已锁定';

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
}
