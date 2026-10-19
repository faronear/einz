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
  String get settingsScopeAll => '应用于本机所有秘境';

  @override
  String get settingsScopeAllDone => '已应用到本机所有秘境';

  @override
  String get close => '关闭';

  @override
  String get setupPageNeedPassphrase => '请设置共享口令';

  @override
  String get upgradeFrozenTitle => '必须升级';

  @override
  String upgradeFrozenBody(String min, String current) {
    return '您的应用版本 $current 已经过期，最低需要 $min。升级后才能继续使用。';
  }

  @override
  String get upgradeFrozenDownload => '下载新版本';

  @override
  String get upgradeCoolingTitle => '建议升级';

  @override
  String upgradeCoolingBody(String latest) {
    return '您的应用版本即将过期，目前最新版本为 $latest，建议您抽空升级。';
  }

  @override
  String get upgradeCoolingDownload => '下载新版本';

  @override
  String get upgradeCoolingLater => '以后再说';

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
  String get wizardMyNameLabel => '名字';

  @override
  String get wizardNameRequired => '请填写我的名字';

  @override
  String get wizardNameInvalidError => '名字只能用中文字、英文字母、数字、下划线(_)、中划线(-)和表情符。';

  @override
  String wizardNameTooLongError(int max) {
    return '名字最多 $max 个字符';
  }

  @override
  String get wizardMyGenderLabel => '性别';

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
  String get wizardNext => '下一步';

  @override
  String get wizardBack => '上一步';

  @override
  String get wizardDone => '完成';

  @override
  String get wizardTitleName => '关于我';

  @override
  String get wizardTitleSpaceKind => '秘境类型';

  @override
  String get wizardSpaceKindHint => '这个秘境里将有几个人？';

  @override
  String get wizardSpaceKindDuo => '双人秘境';

  @override
  String get wizardSpaceKindDuoDesc => '仅限两人，永远没有其他人。';

  @override
  String get wizardSpaceKindGroup => '群组秘境';

  @override
  String get wizardSpaceKindGroupDesc => '多人群组，每个成员都可以添加新人。';

  @override
  String get wizardSpaceKindRequired => '请选择秘境类型';

  @override
  String get wizardSpaceLimit => '秘境数量已达上限（服务器 maxSpaces 限制），暂不能新建秘境';

  @override
  String get wizardTitlePassphrase => '设置共享口令';

  @override
  String get wizardJoinPassphraseTitle => '验证共享口令';

  @override
  String get wizardEnrollExists =>
      '该服务器已有秘境（由另一条通道创建）。请改用“加入”向导，凭对方提供的一次性通道码加入。';

  @override
  String get wizardEnrollGoJoin => '改用“加入”向导';

  @override
  String wizardEnrollFailed(String error) {
    return '❌ 登记失败: $error';
  }

  @override
  String wizardPassphraseHint(String mode) {
    return '共享口令是打开秘境的唯一钥匙，由你和同伴共同保管。务必牢记、严禁泄漏给秘境之外的任何人！';
  }

  @override
  String get wizardPassphraseMinLengthHint => '至少 8 位';

  @override
  String get wizardPassphraseTooShort => '口令不得少于 8 位';

  @override
  String get wizardPassphraseConfirmHint => '再输一次以确认';

  @override
  String get wizardPassphraseMismatch => '两次输入的口令不一致';

  @override
  String wizardJoinPassphraseHint(String mode) {
    return '共享口令是打开秘境的唯一钥匙，由你和同伴共同保管。不知道口令？询问你的秘境同伴。';
  }

  @override
  String get wizardJoinPassphraseWrong => '口令错误！请询问你的秘境同伴获取正确的口令。';

  @override
  String get welcomeDialogTitleCreate => '一切就绪！';

  @override
  String get welcomeDialogTitleJoin => '一切就绪！';

  @override
  String get welcomeDialogMessage => '你的秘境已开启，所有消息端到端加密，确保绝对隐私。进入秘境，开始聊天吧！';

  @override
  String get welcomeDialogStart => '进入秘境';

  @override
  String setupPageKeyGenFailed(String error) {
    return '❌ 密钥生成失败: $error';
  }

  @override
  String get setupEntryTitle => '秘境向导';

  @override
  String get setupEntryHint => '秘境是你的私密聊天和共享空间，可以从头创建，或者受邀加入。';

  @override
  String get setupEntryCreate => '创建秘境';

  @override
  String get setupEntryJoin => '加入秘境';

  @override
  String get setupEntryDemo => '先看看演示（无需创建秘境）';

  @override
  String get setupEntryLegacyServer => '服务器版本过低，请升级后再使用';

  @override
  String setupTokenAppTooOld(String code) {
    return '本机 App 版本过旧，与服务器对不上（$code）。请更新 App 后重试';
  }

  @override
  String setupTokenRateLimited(String seconds) {
    return '请求太频繁：请 $seconds 秒后再试（这不是通道码本身的问题）';
  }

  @override
  String get setupTokenRateLimitedNoWait => '请求太频繁，请稍后再试（这不是通道码本身的问题）';

  @override
  String get setupTokenTitle => '验证通道码';

  @override
  String get setupTokenHint => '连接本机到本秘境。24 小时内一次性有效，可由本秘境任一已认证的通道生成。';

  @override
  String get setupTokenInputHint => '通道码';

  @override
  String get setupTokenNeedInput => '请填写通道码';

  @override
  String get setupTokenInvalid => '通道码无效';

  @override
  String get setupTokenExpired => '通道码已过期';

  @override
  String get setupTokenUsed => '通道码已被使用';

  @override
  String get setupTokenSpaceAlreadyAdded => '本机已经有通道加入了这个秘境（一台设备只能有一条通道到同一个秘境）';

  @override
  String setupTokenOtherServer(String other, String current) {
    return '该邀请链接来自 $other，本机连的是 $current，不能混用';
  }

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
  String get setupPageScanInvite => '扫码填入通道码';

  @override
  String get setupPageScannerHint => '把通道码二维码对准取景框';

  @override
  String get setupPageNoEscrow => '❌ 服务器上找不到共享口令的密保箱，无法凭口令加入。请尝试其他方式。';

  @override
  String setupPageEscrowFailed(String error) {
    return '❌ 共享口令验证失败。请询问你的同伴。';
  }

  @override
  String get setupJoinEntranceLimitReached => '该秘境的通道数量已达服务器上限，无法再开通新通道。';

  @override
  String get setPinDialogPinLabel => '新 PIN（至少 6 位数字）';

  @override
  String get setPinDialogConfirmLabel => '确认新 PIN';

  @override
  String get setPinDialogSetPin => '启用';

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
  String get chatPageSetLockHintNoPin => '设置后，每次离开一定时间后就自动锁屏，必须解锁才能进入秘境。';

  @override
  String get chatPageSetLockRowVerify => '验证';

  @override
  String get chatPageSetLockRowSet => '设置';

  @override
  String get chatPageSetLockRowConfirm => '确认';

  @override
  String get chatPageSetLockNewPinLabel => '新 PIN 或者留空不填';

  @override
  String get chatPageSetLockNewPinLabelNoPin => '新 PIN（至少 6 位数字）';

  @override
  String get chatPageSetLockSubmitChange => '更改';

  @override
  String get chatPageSetLockDurationLabel => '自动锁屏每当离开';

  @override
  String get chatPageSetLockTabChange => '更改锁屏码';

  @override
  String get chatPageSetLockClearButton => '清除锁屏码';

  @override
  String lockDurationSecs(int n) {
    return '$n 秒';
  }

  @override
  String lockDurationMin(int n) {
    return '$n 分钟';
  }

  @override
  String get chatPageSetLockOldLabel => '当前锁屏码';

  @override
  String get chatPageSetLockOldRequired => '请先输入当前锁屏码';

  @override
  String get chatPageSetLockSameAsOld => '新锁屏码不能与当前锁屏码相同';

  @override
  String get chatPageSetLockPinRequired => '请输入新 PIN';

  @override
  String get chatPageSetLockNothingChanged => '你没有做任何修改';

  @override
  String chatPageSetLockDone(String duration) {
    return '锁屏码已设置，每次离开 $duration 后自动锁屏。';
  }

  @override
  String get chatPageSetLockCleared => '已清除锁屏码，其他人拿到这台设备就能进入秘境。';

  @override
  String get chatPageLockClearConfirm => '清除';

  @override
  String get chatPageInviteDialogTitleInvite => '邀请';

  @override
  String get chatPageInviteDialogTitleAttachSelf => '添加我的新通道';

  @override
  String get chatPageInviteDialogTitleReinvite => '重新邀请';

  @override
  String get chatPageInviteJoinLink => '邀请';

  @override
  String get chatPageInviteRegenerate => '重新生成';

  @override
  String get chatPageInviteDialogHintInvite =>
      '把以下的专属通道码发给受邀人，凭它加入本秘境。24 小时内一次性有效。';

  @override
  String get chatPageInviteDialogHintAttachSelf =>
      '使用以下的专属通道码，在我的其他设备上加入本秘境。24 小时内一次性有效。';

  @override
  String chatPageInviteDialogHintReinvite(String name) {
    return '如果“$name”丢失了进入本秘境的所有通道，可凭以下的专属通道码重新加入本秘境。24 小时内一次性有效。';
  }

  @override
  String get chatPageInviteDialogReinviteFallbackName => '对方';

  @override
  String get chatPageInviteCopyLinkTooltip => '复制邀请链接';

  @override
  String get chatPageInviteCopyCodeTooltip => '复制通道码';

  @override
  String get chatPageInviteLinkCopied => '邀请链接已复制';

  @override
  String get chatPageInviteCodeCopied => '通道码已复制';

  @override
  String chatPageInviteFailed(String error) {
    return '通道码生成失败: $error';
  }

  @override
  String get chatPageTitleBrand => '我的秘境';

  @override
  String get chatPageMenuChangePassphrase => '修改共享口令';

  @override
  String get chatPageMenuMyProfile => '我的资料';

  @override
  String get chatPageAvatarUploaded => '✅ 我的头像已更新';

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
  String get chatPageMenuMore => '主菜单';

  @override
  String get chatPageMsgMoreActions => '更多操作';

  @override
  String get chatPageRenameNameTitle => '我的名字';

  @override
  String get chatPageRenameNameLabel => '名字';

  @override
  String get chatPageGroupNameTitle => '群组名称';

  @override
  String get chatPageGroupNameEditTooltip => '修改群名';

  @override
  String get chatPageMyAvatarTooltip => '修改我的头像';

  @override
  String get chatPageMyNameTooltip => '修改我的名字';

  @override
  String get chatPageGroupNameLabel => '名称';

  @override
  String get chatPageGenderLabel => '性别';

  @override
  String get chatPageRenameEntranceTitle => '当前通道';

  @override
  String get chatPageRenameEntranceHint => '修改当前通道名称，不超过32字符';

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
  String get chatPageRenameSameAsPeerError => '不能与同伴同名，请换个名字';

  @override
  String get chatPageCopy => '复制';

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
  String get chatPageEmailSubmit => '提交';

  @override
  String get chatPageRenamingSubmit => '保存';

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
  String chatPageChangePassphraseDone(String mode) {
    return '✅ 共享口令已修改（请告知同伴，以后必须使用新口令）';
  }

  @override
  String chatPageChangePassphraseFailed(String error) {
    return '修改口令失败: $error';
  }

  @override
  String chatPageEscrowRotatedNotice(String mode) {
    return '同伴已更换共享口令，以后必须使用新口令';
  }

  @override
  String get chatPageMenuLocaleLabel => '界面语言';

  @override
  String get chatPageMenuAttachmentStorage => '附件存储';

  @override
  String get chatPageMenuMoreSettings => '更多设置';

  @override
  String get chatPageMoreSettingsTitle => '更多设置';

  @override
  String get chatPageMoreSettingsStorage => '附件存储';

  @override
  String get chatPageMoreSettingsTombstone => '消息留痕';

  @override
  String get chatPageAttachmentStorageNote => '图片、视频、音频、文件等附件存放在哪里？';

  @override
  String get chatPageAttachmentStorageSecured => '远程托管';

  @override
  String get chatPageAttachmentStorageSecuredDesc =>
      '每次打开都重新下载并解密，本机不留明文副本，更私密。';

  @override
  String get chatPageAttachmentStorageStored => '本地保存';

  @override
  String get chatPageAttachmentStorageStoredDesc =>
      '第一次下载时保存明文副本，以后本机可直接打开，更方便。';

  @override
  String get chatPageAttachmentStorageSubmit => '启用';

  @override
  String get chatPageAttachmentStorageWarnClear =>
      '切到“远程托管”会立即删除本机已留存的附件明文。真的要切换吗？';

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
  String get chatPageMenuEntranceList => '我的设备通道';

  @override
  String wizardJoinInviteHint(String name, int count) {
    return '被“$name”邀请加入秘境';
  }

  @override
  String wizardJoinInviteHintNoName(int count) {
    return '被邀请加入秘境';
  }

  @override
  String wizardJoinAttachHint(String name) {
    return '新增一条“$name”的通道';
  }

  @override
  String wizardJoinReinviteHint(String name, String target) {
    return '“$name”重新邀请“$target”加入秘境';
  }

  @override
  String wizardJoinReinviteHintNoName(String target) {
    return '重新邀请“$target”加入秘境';
  }

  @override
  String chatPageMembersTitle(String mode) {
    String _temp0 = intl.Intl.selectLogic(mode, {
      'duo': '我的同伴',
      'group': '我的群组',
      'other': '我的秘境',
    });
    return '$_temp0';
  }

  @override
  String get chatPageMembersUnnamed => '未命名';

  @override
  String get chatPageMembersInvite => '邀请';

  @override
  String get chatPageMembersReinvite => '重新邀请';

  @override
  String get chatPageReinvitePassphraseTitle => '验证共享口令';

  @override
  String chatPageReinvitePassphraseHint(String name) {
    return '验证后，即可重新邀请“$name”';
  }

  @override
  String get chatPagePassphraseFieldHint => '共享口令';

  @override
  String get chatPagePassphraseShow => '显示';

  @override
  String get chatPagePassphraseHide => '隐藏';

  @override
  String get chatPageMembersInviteNew => '邀请新同伴';

  @override
  String chatPageMembersFullWithMax(int current, int max) {
    return '成员已满（$current/$max）';
  }

  @override
  String get chatPageEntranceListFailed => '无法获取其他通道（当前离线？）';

  @override
  String get chatPageEntranceScopeHint => '通道是设备连接到秘境的专属线路。以下是您绑定到当前秘境的所有通道。';

  @override
  String get chatPageEntranceListThisDevice => '当前通道名称';

  @override
  String get chatPageEntranceListNew => '添加我的新通道';

  @override
  String get chatPageEntranceListRefresh => '刷新';

  @override
  String get chatPagePinLabel => '锁屏码';

  @override
  String get chatPageLockNow => '锁屏';

  @override
  String chatPagePinMenuValue(String duration) {
    return '已设 · $duration';
  }

  @override
  String get chatPageNotifyLabel => '我的邮件通知';

  @override
  String get chatPageNotifyTitle => '我的邮件通知';

  @override
  String get chatPageNotifyHint => '你长时间不在线时，如果有新消息，你的邮箱会收到一封提醒。';

  @override
  String get chatPageNotifyEmailLabel => '邮箱';

  @override
  String get chatPageNotifyEmptyError => '先填一个邮箱地址';

  @override
  String get chatPageNotifyInvalidError => '邮箱地址格式不对';

  @override
  String get chatPageNotifyOnValue => '已开启';

  @override
  String get chatPageNotifyPendingValue => '待确认';

  @override
  String get chatPageNotifyOffValue => '已关闭';

  @override
  String get chatPageNotifyStatePending => '一封确认邮件已发往您的邮箱，点击邮件里的链接即可生效。';

  @override
  String chatPageNotifySent(String email) {
    return '确认邮件已发往 $email，点邮件里的链接就生效了。';
  }

  @override
  String chatPageNotifyDone(String email) {
    return '已开启：有新消息又长时间不在线时，会往 $email 发提醒。';
  }

  @override
  String get chatPageNotifyRemoved => '已停止邮件提醒。';

  @override
  String get chatPageNotifyStop => '停用';

  @override
  String chatPageNotifyFailed(String error) {
    return '设置失败：$error';
  }

  @override
  String get chatPageBurnHeading => '阅后即焚';

  @override
  String get chatPageBurnNote => '倒计时自动删除已阅读的新消息';

  @override
  String get chatPageTombstoneHeading => '消息留痕';

  @override
  String get chatPageTombstoneNote => '已删除/已焚毁/已撤回的消息是否显示？';

  @override
  String get chatPageTombstoneKeep => '占位留痕';

  @override
  String get chatPageTombstoneKeepDesc => '显示为时间和状态条，正文隐藏，不打破消息流水';

  @override
  String get chatPageTombstoneHide => '彻底消失';

  @override
  String get chatPageTombstoneHideDesc => '完全不再显示，从消息流中彻底消失';

  @override
  String get chatPageTombstoneSubmit => '启用';

  @override
  String get chatPageBurnOff => '已对这一个消息取消了阅后即焚';

  @override
  String get chatPageBurnFailed => '设置阅后即焚失败';

  @override
  String chatPageBurnWillDelete(String duration) {
    return '新的消息将在 $duration 后自动删除';
  }

  @override
  String get chatPageActionDelete => '立刻删除';

  @override
  String get chatPageActionRecall => '撤回';

  @override
  String get chatPageRecallConfirmTitle => '撤回消息？';

  @override
  String get chatPageRecallConfirmBody => '一旦撤回，对方就不会收到这条消息。确定撤回这条消息吗？';

  @override
  String get chatPageRecallConfirmOk => '撤回';

  @override
  String get chatPageRecallBlocked => '对方已接收，无法撤回';

  @override
  String get chatPageRecallFailed => '撤回失败，请稍后重试';

  @override
  String get chatPageQuotedTombMessage => '（该消息已不存在）';

  @override
  String get chatPageQuoteGoneNotice => '被引用消息已不存在';

  @override
  String get chatPageActionQuote => '引用';

  @override
  String get chatPageActionSave => '保存';

  @override
  String get chatPageAttachmentSaved => '已保存。';

  @override
  String chatPageFileSaveFailed(Object error) {
    return '保存失败: $error';
  }

  @override
  String get chatPageActionBurn => '阅后即焚';

  @override
  String get chatPageDeleteConfirmTitle => '删除消息？';

  @override
  String get chatPageDeleteConfirmMessage =>
      '删除仅在本机生效（你的和同伴的其他设备都不受影响），且无法恢复。确定删除这条消息吗？';

  @override
  String get chatPageDeleteCancel => '取消';

  @override
  String get chatPageDeleteConfirmOk => '删除';

  @override
  String get chatPagePasteSendImageTitle => '发送这张图片？';

  @override
  String chatPagePasteSendVideoTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '发送这 $count 个视频？',
      one: '发送这个视频？',
    );
    return '$_temp0';
  }

  @override
  String chatPagePasteSendAudioTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '发送这 $count 个音频？',
      one: '发送这个音频？',
    );
    return '$_temp0';
  }

  @override
  String chatPagePasteSendFilesTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '发送这 $count 个文件？',
      one: '发送这个文件？',
    );
    return '$_temp0';
  }

  @override
  String get chatPagePasteEmpty => '剪贴板是空的';

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
  String chatPageMsgsUnsent(int count) {
    return '等待同步中… $count 条消息待发送，网络恢复后自动重发';
  }

  @override
  String get chatPageEntranceUnrecognized =>
      '这条通道未被服务器识别（服务器数据可能已重置）· 仅可查看本地消息，联网功能暂停；本地数据保留。';

  @override
  String get chatPageMsgsSyncing => '等待同步中… 暂时无法收发，仅可查看本地消息';

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
  String get chatPageAttachPaste => '粘贴';

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
  String get chatPageAttachmentUnusable => '附件不可用';

  @override
  String get chatPageAttachmentRetry => '点按重试';

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
  String get chatPageVideoUnsupportedPlatform => '此设备不支持播放视频，点按保存到本地';

  @override
  String chatPageFileOpenFailed(String error) {
    return '打开文件失败: $error';
  }

  @override
  String get chatPageEntranceRevoked => '这条通道已被撤销，本地数据已清除，请重新配置';

  @override
  String get burnOptionOff => '不再自动焚毁';

  @override
  String get burnSubmit => '启用';

  @override
  String burnPreviewDelay(String duration) {
    return '$duration';
  }

  @override
  String burnUnitDays(int count) {
    return '$count 天';
  }

  @override
  String burnUnitHours(int count) {
    return '$count 小时';
  }

  @override
  String burnUnitMinutes(int count) {
    return '$count 分钟';
  }

  @override
  String burnUnitSeconds(int count) {
    return '$count 秒';
  }

  @override
  String get burnAxisOffLabel => '关闭';

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
      '秘境是你的私密聊天和共享空间，端到端加密，一切由你自由掌控，没有任何第三方（包括秘境自身）能够偷看内容，全力保障你的隐私安全。';

  @override
  String get aboutVersionLabel => '版本号';

  @override
  String get aboutDownloadLabel => '下载';

  @override
  String get aboutServerLabel => '服务器地址';

  @override
  String get aboutServerDevNote => '开发地址，仅供测试';

  @override
  String get aboutStatusLabel => '连接状态';

  @override
  String get aboutStatusChecking => '检测中…';

  @override
  String get aboutStatusConnected => '已连接';

  @override
  String get aboutStatusUnreachable => '无法连接';

  @override
  String get aboutDnsPoisonLabel => 'DNS 污染';

  @override
  String aboutDnsPoisonValue(String host, String ip) {
    return '$host 被劫持到 $ip';
  }

  @override
  String get aboutDnsPoisonUnknownIp => '未知';

  @override
  String get aboutDnsPoisonNote =>
      '当前网络在劫持该域名的解析（上面是它给出的假地址）；连接已由加密解析（DoH）自动修复，事件已上报服务器。真地址已保护不展示';

  @override
  String get advancedMenuTitle => '高级安全';

  @override
  String get advancedDestroyEntrance => '销毁本通道';

  @override
  String get advancedClearMessages => '删除所有消息';

  @override
  String get clearMessagesMessage =>
      '删除当前通道保存的所有消息和附件。本通道仍然可用，将继续收到新消息。其他通道不受影响。';

  @override
  String get clearMessagesConfirm => '删除';

  @override
  String get clearMessagesDone => '已删除全部消息。';

  @override
  String clearMessagesFailed(String error) {
    return '删除失败: $error';
  }

  @override
  String get leaveSpaceTitle => '销毁本通道？';

  @override
  String get leaveSpaceMessage =>
      '彻底删除当前通道保存的全部消息、附件和凭证，并回到秘境向导页。当前秘境本身仍然存在，其他通道也不受影响。此操作无法撤销！';

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
      '⚠️ 本地数据已清除，但服务端退役未完成，同伴的通道列表里可能仍留有这条通道';

  @override
  String get spaceListHint => '点击卡片切换当前秘境';

  @override
  String get spaceListTitle => '我的秘境';

  @override
  String get spaceListEmpty => '还没有加入任何秘境';

  @override
  String get spaceListAdd => '添加另一个秘境';

  @override
  String get spaceListSwitch => '我的秘境';

  @override
  String get promptLockCodeTitle => '输入锁屏码';

  @override
  String get promptLockCodeHint => '请先验证本机锁屏码';

  @override
  String get leaveSpaceConfirm => '销毁';

  @override
  String errorBackend(String message) {
    return '后台：$message';
  }

  @override
  String get memberPending => '待加入';

  @override
  String chatPageStatusOthersOnline(int online, int total) {
    return '$online/$total';
  }

  @override
  String get voiceCallMenuCall => '语音通话';

  @override
  String get voiceCallIncoming => '来电';

  @override
  String get voiceCallCalling => '正在呼叫…';

  @override
  String get voiceCallConnecting => '正在接通…';

  @override
  String get voiceCallAccept => '接听';

  @override
  String get voiceCallDecline => '拒绝';

  @override
  String get voiceCallCancel => '取消';

  @override
  String get voiceCallHangUp => '挂断';

  @override
  String get voiceCallMute => '静音';

  @override
  String get voiceCallUnmute => '取消静音';

  @override
  String get voiceCallSpeaker => '免提';

  @override
  String get voiceCallSpeakerOff => '关闭免提';

  @override
  String get voiceCallEnded => '通话结束';

  @override
  String get voiceCallEndedDeclined => '对方拒绝了通话';

  @override
  String get voiceCallEndedBusy => '对方忙线中';

  @override
  String get voiceCallEndedNoAnswer => '对方未接听';

  @override
  String get voiceCallEndedCanceled => '已取消通话';

  @override
  String get voiceCallEndedFailed => '通话连接失败';

  @override
  String get voiceCallForegroundOnly => '只有双方都打开 Einz 时才能接通';

  @override
  String voiceCallRecordDuration(String duration) {
    return '通话时长 $duration';
  }

  @override
  String get chatPageAvatarChange => '更换头像';

  @override
  String get chatPageDropHint => '松手发送';

  @override
  String get chatPageDropHintSub => '图片 / 视频 / 音频 / 文件';

  @override
  String chatPageAttachmentTooLarge(String limit) {
    return '文件太大，服务器上限为 $limit';
  }

  @override
  String get chatPageAttachmentTooLargeUnknown => '文件太大，服务器拒收了';
}
