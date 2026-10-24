// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get cancel => 'Cancel';

  @override
  String get ok => 'OK';

  @override
  String get send => 'Send';

  @override
  String get confirm => 'Confirm';

  @override
  String get delete => 'Delete';

  @override
  String get settings => 'Settings';

  @override
  String get settingsScopeAll => 'Apply to all spaces on this device';

  @override
  String get settingsScopeAllDone => 'Applied to all spaces on this device';

  @override
  String get close => 'Close';

  @override
  String get setupPageNeedPassphrase => 'Enter a shared passphrase';

  @override
  String get upgradeFrozenTitle => 'Update required';

  @override
  String upgradeFrozenBody(String min, String current) {
    return 'Your app version $current is no longer supported, you need at least $min. Please update to continue.';
  }

  @override
  String get upgradeFrozenDownload => 'Download update';

  @override
  String get upgradeCoolingTitle => 'Update available';

  @override
  String upgradeCoolingBody(String latest) {
    return 'Your app version is old, the newest version $latest is available for download. Please update at your convenient time.';
  }

  @override
  String get upgradeCoolingDownload => 'Download update';

  @override
  String get upgradeCoolingLater => 'Later';

  @override
  String get wizardJoinPassphraseRequired => 'Enter the shared passphrase';

  @override
  String get wizardStartTitle => 'Einz';

  @override
  String get wizardDetectTitle => 'Checking server status…';

  @override
  String get wizardDetectHint => 'Auto-detects if this is the first entrance';

  @override
  String get wizardDetectFailed => 'Cannot reach server — retrying…';

  @override
  String wizardProbeConnecting(String server) {
    return 'Connecting to $server…';
  }

  @override
  String get wizardMyNameLabel => 'Name';

  @override
  String get wizardNameRequired => 'Enter your name';

  @override
  String get wizardNameInvalidError =>
      'Only Chinese/English letters, digits, _ , - and emoji are allowed.';

  @override
  String wizardNameTooLongError(int max) {
    return 'At most $max characters';
  }

  @override
  String get wizardMyGenderLabel => 'Gender';

  @override
  String get wizardGenderMale => 'Male';

  @override
  String get wizardGenderFemale => 'Female';

  @override
  String get wizardGenderRequired => 'Select a gender';

  @override
  String get wizardAppBarCreate => 'Create a space';

  @override
  String get wizardAppBarJoin => 'Join a space';

  @override
  String get wizardNext => 'Next';

  @override
  String get wizardBack => 'Back';

  @override
  String get wizardDone => 'Done';

  @override
  String get wizardTitleName => 'About me';

  @override
  String get wizardTitleSpaceKind => 'Space type';

  @override
  String get wizardSpaceKindHint => 'How many people will this space have?';

  @override
  String get wizardSpaceKindDuo => 'Duo space';

  @override
  String get wizardSpaceKindDuoDesc =>
      'For just the two of you, no one else can be added later.';

  @override
  String get wizardSpaceKindGroup => 'Group space';

  @override
  String get wizardSpaceKindGroupDesc =>
      'For multiple persons, every member can invite new ones.';

  @override
  String get wizardSpaceKindRequired => 'Please choose a space type';

  @override
  String get wizardSpaceLimit =>
      'Space limit reached (server maxSpaces), cannot create';

  @override
  String get wizardTitlePassphrase => 'Set passphrase';

  @override
  String get wizardJoinPassphraseTitle => 'Verify passphrase';

  @override
  String get wizardEnrollExists =>
      'This server already has a space (created by another entrance). Use the Join flow with a one-time entrance token from the other person.';

  @override
  String get wizardEnrollGoJoin => 'Use Join flow';

  @override
  String wizardEnrollFailed(String error) {
    return '❌ Enrollment failed: $error';
  }

  @override
  String wizardPassphraseHint(String mode) {
    String _temp0 = intl.Intl.selectLogic(mode, {
      'duo': 'your companion',
      'other': 'your companions',
    });
    return 'The passphrase is the secret key to access the space, shared by you and $_temp0. Memorize it and never leak it!';
  }

  @override
  String get wizardPassphraseMinLengthHint => 'At least 8 characters';

  @override
  String get wizardPassphraseTooShort =>
      'Passphrase must be at least 8 characters';

  @override
  String get wizardPassphraseConfirmHint => 'Re-enter passphrase';

  @override
  String get wizardPassphraseMismatch => 'Passphrases do not match';

  @override
  String wizardJoinPassphraseHint(String mode) {
    String _temp0 = intl.Intl.selectLogic(mode, {
      'duo': 'your companion',
      'other': 'your companions',
    });
    String _temp1 = intl.Intl.selectLogic(mode, {
      'duo': 'your companion',
      'other': 'your companions',
    });
    return 'The passphrase is the secret key to access the space, shared by you and $_temp0. Don\'t know it? Ask $_temp1.';
  }

  @override
  String get wizardJoinPassphraseWrong => 'Wrong passphrase.';

  @override
  String get welcomeDialogTitleCreate => 'All set!';

  @override
  String get welcomeDialogTitleJoin => 'All set!';

  @override
  String get welcomeDialogMessage =>
      'Your space is ready, end-to-end encrypted for total privacy. Enter now and start chatting!';

  @override
  String get welcomeDialogStart => 'Enter Einz';

  @override
  String setupPageKeyGenFailed(String error) {
    return '❌ Key generation failed: $error';
  }

  @override
  String get setupEntryTitle => 'Einz wizard';

  @override
  String get setupEntryHint =>
      'Einz is the secret realm where you and your selected companions chat and share in your own spaces, away from the world. You can create a new one from the ground up, or join an existing one by invitation.';

  @override
  String get setupEntryCreate => 'Create';

  @override
  String get setupEntryJoin => 'Join';

  @override
  String get setupEntryDemo => 'Take a look around first';

  @override
  String get setupEntryLegacyServer =>
      'Server version too old — please upgrade';

  @override
  String setupTokenAppTooOld(String code) {
    return 'This app is too old for the server ($code). Please update the app and try again';
  }

  @override
  String setupTokenRateLimited(String seconds) {
    return 'Too many requests — retry in ${seconds}s';
  }

  @override
  String get setupTokenRateLimitedNoWait =>
      'Too many requests — try again later (this is not a problem with the entrance token)';

  @override
  String get setupTokenTitle => 'Verify entrance token';

  @override
  String get setupTokenHint =>
      'Connect this device to the space. Valid for one-time use within 24 hours; generate it from any verified entrance in the space.';

  @override
  String get setupTokenInputHint => 'Entrance token';

  @override
  String get setupTokenNeedInput => 'Enter the entrance token';

  @override
  String get setupTokenInvalid => 'Invalid entrance token';

  @override
  String get setupTokenExpired => 'Entrance token expired';

  @override
  String get setupTokenUsed => 'Entrance token already used';

  @override
  String get setupTokenSpaceAlreadyAdded =>
      'This device has already an entrance to this space (one device can hold only one entrance to a space)';

  @override
  String setupTokenOtherServer(String other, String current) {
    return 'the invite link is from $other but this app is connected to $current; they cannot work with each other.';
  }

  @override
  String get setupPageInitFailed => 'Initialization failed, retrying…';

  @override
  String get startupInitFailed =>
      'Startup failed — your data is safe, please retry';

  @override
  String get startupInitRetry => 'Retry';

  @override
  String get startupInitClearData => 'Clear local data & start over';

  @override
  String get startupInitClearDataTitle => 'Clear local data?';

  @override
  String get startupInitClearDataMessage =>
      'Erases everything stored on this device — secret spaces, messages, attachments, lock screen code and keys — and returns to setup. Use only when retry keeps failing; this cannot be undone.';

  @override
  String get startupInitClearedRestart =>
      'Local data cleared. Fully quit and reopen the app.';

  @override
  String get setupPageScanInvite => 'Scan entrance token QR code';

  @override
  String get setupPageScannerHint =>
      'Point the camera at the entrance token QR code';

  @override
  String get setupPageNoEscrow =>
      '❌ No escrow package for the shared passphrase on the server — set it on the first entrance first';

  @override
  String setupPageEscrowFailed(String error) {
    return '❌ Shared passphrase join failed: $error';
  }

  @override
  String get setupJoinEntranceLimitReached =>
      'This space has reached the server\'s entrance limit — no new entrance can be opened.';

  @override
  String get setPinDialogSetPin => 'Apply';

  @override
  String get setPinDialogPinTooShort => 'PIN must be at least 6 digits';

  @override
  String get setPinDialogPinDigitsOnly => 'Digits only';

  @override
  String get setPinDialogOldWrong => 'Wrong current PIN';

  @override
  String get verifyPinRequired => 'Enter your PIN to verify';

  @override
  String get verifyPinWrong => 'Wrong PIN';

  @override
  String setPinDialogSetupFailed(String error) {
    return 'Setup failed: $error';
  }

  @override
  String chatPageLocaleSwitched(String label) {
    return 'Switched to $label';
  }

  @override
  String get chatPageSetLockTitle => 'Set PIN';

  @override
  String get chatPageSetLockHintNoPin =>
      'Once set, Einz will lock itself everytime after keeping inactive for a while, then you must unlock to enter your space again.';

  @override
  String get chatPageSetLockRowVerify => 'Verify';

  @override
  String get chatPageSetLockRowSet => 'Set';

  @override
  String get chatPageSetLockNewPinLabel => 'New PIN or leave blank';

  @override
  String get chatPageSetLockNewPinLabelNoPin => 'New PIN (at least 6 digits)';

  @override
  String get chatPageSetLockSubmitChange => 'Change';

  @override
  String get chatPageSetLockDurationLabel => 'Auto-lock after inactivity';

  @override
  String get chatPageSetLockTabChange => 'Change PIN';

  @override
  String get chatPageSetLockClearButton => 'Clear PIN';

  @override
  String lockDurationSecs(int n) {
    return '$n sec';
  }

  @override
  String lockDurationMin(int n) {
    return '$n min';
  }

  @override
  String get chatPageSetLockOldLabel => 'Current PIN';

  @override
  String get chatPageSetLockOldRequired => 'Enter current PIN to verify';

  @override
  String get chatPageSetLockSameAsOld =>
      'New PIN must be different than the current one.';

  @override
  String get chatPageSetLockPinRequired => 'Enter a new PIN';

  @override
  String get chatPageSetLockNothingChanged => 'You haven\'t changed anything';

  @override
  String chatPageSetLockDone(String duration) {
    return 'PIN set. Einz will lock itself everytime after inactivity of $duration.';
  }

  @override
  String get chatPageSetLockCleared =>
      'PIN cleared. Anyone who has access to this device can visit your space.';

  @override
  String get chatPageLockClearConfirm => 'Clear';

  @override
  String get chatPageInviteDialogTitleInvite => 'Invite';

  @override
  String get chatPageInviteDialogTitleAttachSelf => 'Add my new entrance';

  @override
  String get chatPageInviteDialogTitleReinvite => 'Re-invite';

  @override
  String get chatPageInviteJoinLink => 'Invite';

  @override
  String get chatPageInviteRegenerate => 'Regenerate';

  @override
  String get chatPageInviteDialogHintInvite =>
      'Send the dedicated entrance token below to whoever you\'re inviting to join this space. One-time use, valid for 24 hours.';

  @override
  String get chatPageInviteDialogHintAttachSelf =>
      'Use the dedicated entrance token below on my another device to connect to this space. One-time use, valid for 24 hours.';

  @override
  String chatPageInviteDialogHintReinvite(String name) {
    return 'If “$name” loses all entrances into this space, send the dedicated entrance token below to “$name” to join again. One-time use, valid for 24 hours.';
  }

  @override
  String get chatPageInviteDialogReinviteFallbackName => 'them';

  @override
  String get chatPageInviteLinkCopied => 'Invite link copied';

  @override
  String get chatPageInviteCodeCopied => 'Entrance token copied';

  @override
  String chatPageInviteFailed(String error) {
    return 'Failed to create the entrance token: $error';
  }

  @override
  String get chatPageTitleBrand => 'My Einz';

  @override
  String get chatPageMenuChangePassphrase => 'Change shared passphrase';

  @override
  String get chatPageMenuMyProfile => 'My profile';

  @override
  String get chatPageAvatarUploaded => '✅ My avatar updated';

  @override
  String get chatPageAvatarTooLarge => 'Image too large (max 2MB)';

  @override
  String chatPageAvatarFailed(String error) {
    return 'Avatar upload failed: $error';
  }

  @override
  String get chatPageNameUnset => 'Unset';

  @override
  String get chatPageMenuExit => 'Quit app';

  @override
  String get chatPageMenuMore => 'Main menu';

  @override
  String get chatPageMsgMoreActions => 'More actions';

  @override
  String get chatPageRenameNameTitle => 'My name';

  @override
  String get chatPageRenameNameLabel => 'Name';

  @override
  String get chatPageGroupNameTitle => 'Group name';

  @override
  String get chatPageGroupNameLabel => 'Name';

  @override
  String get chatPageGenderLabel => 'Gender';

  @override
  String get chatPageRenameEntranceTitle => 'Current entrance';

  @override
  String get chatPageRenameEntranceHint =>
      'Rename the current entrance, up to 32 characters';

  @override
  String get chatPageRenameEntranceEmptyError => 'Enter the entrance name';

  @override
  String get chatPageRenameEntranceInvalidError =>
      'Only Chinese/English letters, digits, _ and - are allowed';

  @override
  String chatPageRenameEntranceTooLongError(int max) {
    return 'At most $max characters';
  }

  @override
  String get chatPageRenameMyselfEmptyError => 'Enter your name';

  @override
  String get chatPageRenameNameInvalidError =>
      'Only Chinese/English letters, digits, _ , - and emoji are allowed';

  @override
  String chatPageRenameNameTooLongError(int max) {
    return 'At most $max characters';
  }

  @override
  String get chatPageRenameSameAsPeerError =>
      'Can\'t use the same name as someone else — pick another';

  @override
  String get chatPageCopy => 'Copy';

  @override
  String chatPageCopiedText(String text) {
    return 'Copied: $text';
  }

  @override
  String get chatPageEdit => 'Edit';

  @override
  String chatPageRenameFailed(String error) {
    return 'Rename failed: $error';
  }

  @override
  String get chatPageExitTitle => 'Quit app?';

  @override
  String get chatPageExitMessage => 'Exits Einz on this device.';

  @override
  String get chatPageEmailSubmit => 'Submit';

  @override
  String get chatPageRenamingSubmit => 'Save';

  @override
  String get chatPageChangePassphraseTitle => 'Change passphrase';

  @override
  String get chatPageChangePassphraseSubmit => 'Change';

  @override
  String get chatPageChangePassphraseOldLabel => 'Current passphrase';

  @override
  String get chatPageChangePassphraseNewLabel => 'New passphrase';

  @override
  String get chatPageChangePassphraseConfirmLabel => 'Confirm new passphrase';

  @override
  String get chatPagePassphraseRevealTip =>
      'Show plain text (auto-hides after 3s)';

  @override
  String get chatPageChangePassphraseMismatch => 'New passphrases do not match';

  @override
  String get chatPageChangePassphraseSame =>
      'New passphrase cannot be the same as the current one';

  @override
  String get chatPageChangePassphraseOldRequired =>
      'Enter your current passphrase first';

  @override
  String get chatPageChangePassphraseOldWrong => 'Wrong current passphrase';

  @override
  String chatPageChangePassphraseDone(String mode) {
    String _temp0 = intl.Intl.selectLogic(mode, {
      'duo': 'your companion',
      'other': 'your companions',
    });
    return '✅ Shared passphrase updated — tell $_temp0; new entrances must use the new one';
  }

  @override
  String chatPageChangePassphraseFailed(String error) {
    return 'Failed to change passphrase: $error';
  }

  @override
  String chatPageEscrowRotatedNotice(String mode) {
    String _temp0 = intl.Intl.selectLogic(mode, {
      'duo': 'Your companion',
      'other': 'Your companions',
    });
    return '$_temp0 reset the shared passphrase — use the new one to create entrance tokens or change it';
  }

  @override
  String get chatPageMenuLocaleLabel => 'Language';

  @override
  String get chatPageMenuAttachmentStorage => 'Attachment storage';

  @override
  String get chatPageMenuMoreSettings => 'More settings';

  @override
  String get chatPageMoreSettingsTitle => 'More settings';

  @override
  String get chatPageMoreSettingsStorage => 'Attachment storage';

  @override
  String get chatPageMoreSettingsTombstone => 'Vanished messages';

  @override
  String get chatPageAttachmentStorageNote =>
      'Where are attachments — images, videos, audio, files — stored?';

  @override
  String get chatPageAttachmentStorageSecured => 'Remote only';

  @override
  String get chatPageAttachmentStorageSecuredDesc =>
      'Downloads and decrypts every time it is opened; no plaintext copy is kept on this device. More private.';

  @override
  String get chatPageAttachmentStorageStored => 'Keep locally';

  @override
  String get chatPageAttachmentStorageStoredDesc =>
      'Keeps a plaintext copy after the first download, so you can open it directly on this device. More convenient.';

  @override
  String get chatPageAttachmentStorageSubmit => 'Apply';

  @override
  String get chatPageAttachmentStorageWarnClear =>
      'Switching to “Remote only” immediately deletes locally stored attachments';

  @override
  String get chatPageMenuStyleLabel => 'Theme';

  @override
  String get chatPageUiStylePlain => 'Plain';

  @override
  String get chatPageUiStylePlainDesc =>
      'Light pink solid background, clean and calm';

  @override
  String get chatPageUiStyleGradient => 'Gradient';

  @override
  String get chatPageUiStyleGradientDesc =>
      'Pink-blue gradient in the brand colors';

  @override
  String get chatPageMenuBurnLabel => 'Burn-after-read';

  @override
  String get chatPageMenuEntranceList => 'My entrances';

  @override
  String wizardJoinInviteHint(String name, int count) {
    return 'Invited by “$name”';
  }

  @override
  String wizardJoinInviteHintNoName(int count) {
    return 'Invited to join a space';
  }

  @override
  String wizardJoinAttachHint(String name) {
    return 'Add a new entrance of “$name”';
  }

  @override
  String wizardJoinReinviteHint(String name, String target) {
    return 'Invited by “$name” to add a new entrance of “$target”';
  }

  @override
  String wizardJoinReinviteHintNoName(String target) {
    return 'Invited to add a new entrance of “$target”';
  }

  @override
  String chatPageMembersTitle(String mode) {
    String _temp0 = intl.Intl.selectLogic(mode, {
      'duo': 'My companion',
      'group': 'My group',
      'other': 'My space',
    });
    return '$_temp0';
  }

  @override
  String get chatPageMembersUnnamed => 'Unnamed';

  @override
  String get chatPageMembersInvite => 'Invite';

  @override
  String get chatPageMembersReinvite => 'Re-invite';

  @override
  String get chatPageMemberProfileTitle => 'Group companion';

  @override
  String get chatPageReinvitePassphraseTitle => 'Verify passphrase';

  @override
  String chatPageReinvitePassphraseHint(String name) {
    return 'After verification you can re-invite “$name”';
  }

  @override
  String get chatPagePassphraseFieldHint => 'Shared passphrase';

  @override
  String get chatPagePassphraseVerify => 'Verify';

  @override
  String get chatPagePassphraseWrong => 'Incorrect passphrase';

  @override
  String get chatPagePassphraseEmpty => 'Enter the shared passphrase';

  @override
  String get chatPagePassphraseVerifyFailed =>
      'Verification failed, please try again';

  @override
  String get chatPageMembersInviteNew => 'Invite a new companion';

  @override
  String chatPageMembersFullWithMax(int current, int max) {
    return 'Space is full ($current/$max)';
  }

  @override
  String get chatPageEntranceListFailed =>
      'Could not load other entrances (offline?)';

  @override
  String get chatPageEntranceScopeHint =>
      'An entrance connects a device to a space. Below are all your authorized entrances to this space.';

  @override
  String get chatPageEntranceListThisDevice => 'Current entrance name';

  @override
  String get chatPageEntranceListNew => 'Add my new entrance';

  @override
  String get chatPagePinLabel => 'PIN';

  @override
  String chatPagePinMenuValue(String duration) {
    return '$duration';
  }

  @override
  String get chatPageNotifyLabel => 'My email alerts';

  @override
  String get chatPageNotifyTitle => 'My email alerts';

  @override
  String get chatPageNotifyHint =>
      'If you have new messages and haven\'t been online for a while, a notification will be sent to your email address.';

  @override
  String get chatPageNotifyEmailLabel => 'Email';

  @override
  String get chatPageNotifyEmptyError => 'Enter an email address first';

  @override
  String get chatPageNotifyInvalidError =>
      'That doesn\'t look like an email address';

  @override
  String get chatPageNotifyOnValue => 'On';

  @override
  String get chatPageNotifyPendingValue => 'Waiting confirm';

  @override
  String get chatPageNotifyOffValue => 'Off';

  @override
  String get chatPageNotifyStatePending =>
      'A confirmation email is on its way. Please check your email and open the link in it to allowzba email alerts.';

  @override
  String chatPageNotifySent(String email) {
    return 'Confirmation sent to $email. Open the link in it to turn alerts on.';
  }

  @override
  String chatPageNotifyDone(String email) {
    return 'On. We\'ll email $email when you have new messages and haven\'t been online for a while.';
  }

  @override
  String get chatPageNotifyRemoved => 'Email alerts turned off.';

  @override
  String get chatPageNotifyStop => 'Turn off';

  @override
  String chatPageNotifyFailed(String error) {
    return 'Could not save: $error';
  }

  @override
  String get chatPageBurnHeading => 'Burn-after-read';

  @override
  String get chatPageBurnNote =>
      'Delete new messages automatically once read on a countdown';

  @override
  String get chatPageTombstoneHeading => 'Vanished messages';

  @override
  String get chatPageTombstoneNote =>
      'How deleted/burned/recalled messages appear?';

  @override
  String get chatPageTombstoneKeep => 'Show metadata';

  @override
  String get chatPageTombstoneKeepDesc =>
      'Show a time and status bar without content, message flow unbroken';

  @override
  String get chatPageTombstoneHide => 'Hide completely';

  @override
  String get chatPageTombstoneHideDesc =>
      'Disappear from the message flow entirely, leave no trace';

  @override
  String get chatPageTombstoneSubmit => 'Apply';

  @override
  String get chatPageBurnOff => 'Burn-after-read is disabled on this message';

  @override
  String get chatPageBurnFailed => 'Failed to set burn-after-read';

  @override
  String chatPageBurnWillDelete(String duration) {
    return 'New messages auto-delete after $duration';
  }

  @override
  String get chatPageActionDelete => 'Delete now';

  @override
  String get chatPageActionRecall => 'Recall';

  @override
  String get chatPageRecallConfirmTitle => 'Recall message?';

  @override
  String get chatPageRecallConfirmBody =>
      'Once recalled, your companion will never receive it. This cannot be undone.';

  @override
  String get chatPageRecallConfirmOk => 'Recall';

  @override
  String get chatPageRecallBlocked => 'Already delivered, can\'t recall';

  @override
  String get chatPageRecallFailed => 'Recall failed, try again later';

  @override
  String get chatPageQuoteGoneNotice =>
      'The quoted message is no longer available';

  @override
  String get chatPageActionQuote => 'Quote';

  @override
  String get chatPageActionSave => 'Save';

  @override
  String get chatPageAttachmentSaved => 'Saved.';

  @override
  String chatPageFileSaveFailed(Object error) {
    return 'Save failed: $error';
  }

  @override
  String get chatPageActionBurn => 'Burn after reading';

  @override
  String get chatPageDeleteConfirmTitle => 'Delete message?';

  @override
  String get chatPageDeleteConfirmMessage =>
      'Removed only on this device (the others aren\'t affected), and it can\'t be undone. Delete?';

  @override
  String get chatPageDeleteCancel => 'Cancel';

  @override
  String get chatPageDeleteConfirmOk => 'Delete';

  @override
  String get chatPagePasteSendImageTitle => 'Send this image?';

  @override
  String chatPagePasteSendVideoTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Send these $count videos?',
      one: 'Send this video?',
    );
    return '$_temp0';
  }

  @override
  String chatPagePasteSendAudioTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Send these $count audio files?',
      one: 'Send this audio?',
    );
    return '$_temp0';
  }

  @override
  String chatPagePasteSendFilesTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Send these $count files?',
      one: 'Send this file?',
    );
    return '$_temp0';
  }

  @override
  String get chatPagePasteEmpty => 'Clipboard is empty';

  @override
  String chatPageSendFailed(String error) {
    return 'Send failed: $error';
  }

  @override
  String get chatPageMsgFailedTap => 'Tap to resend';

  @override
  String chatPageMsgsUnsent(int count) {
    return 'Waiting to sync… $count unsent, will retry when back online';
  }

  @override
  String get chatPageEntranceUnrecognized =>
      'This entrance is not recognized by the server (its data may have been reset) · local messages only, no sync; your local data remains.';

  @override
  String get chatPageMsgsSyncing =>
      'Waiting to sync… Send/receive temporarily unavailable, local messages only';

  @override
  String get chatPageMsgResending => 'Resending…';

  @override
  String get chatPageMsgSpeedingUp => 'Speeding up…';

  @override
  String chatPageVoiceStartFailed(String error) {
    return 'Recording start failed: $error';
  }

  @override
  String chatPageVoiceFailed(String error) {
    return 'Recording failed: $error';
  }

  @override
  String get chatPageVoicePermissionDenied =>
      'Microphone permission denied. Please enable it in system settings.';

  @override
  String get chatPageVoiceEmpty => 'Recording was empty and was discarded.';

  @override
  String get chatPageLongPressToRecord => 'Long press to record';

  @override
  String get chatPageInputHint => 'Type a message…';

  @override
  String get chatPageAudioMetaMissing => 'Audio metadata missing';

  @override
  String chatPageAudioPlayFailed(String error) {
    return 'Audio playback failed: $error';
  }

  @override
  String get chatPageAttachEmoji => 'Emoji';

  @override
  String get chatPageAttachPaste => 'Paste';

  @override
  String get chatPageAttachPhoto => 'Take photo';

  @override
  String get chatPageAttachGalleryImage => 'Gallery image';

  @override
  String get chatPageAttachVideoCamera => 'Record video';

  @override
  String get chatPageAttachVideoGallery => 'Gallery video';

  @override
  String get chatPageAttachAudioFile => 'Audio file';

  @override
  String get chatPageAttachAnyFile => 'Any file';

  @override
  String get chatPageVoiceLabel => 'Voice';

  @override
  String get voiceTranscribing => 'Transcribing…';

  @override
  String get voiceTranscriptRetry => 'Transcription failed, tap to retry';

  @override
  String get voiceTranscriptStale => 'Re-transcribe available';

  @override
  String get voiceTranscriptManual => 'Tap to transcribe';

  @override
  String get voiceTranscriptLegacyAudio =>
      'Legacy voice messages (m4a) can\'t be transcribed — only new recordings can';

  @override
  String get chatPageMenuVoiceTranscriptAuth => 'Voice transcription';

  @override
  String get voiceTranscriptAuthNote =>
      'Choose how voice messages are transcribed.';

  @override
  String get voiceTranscriptAuthLocal => 'Local';

  @override
  String get voiceTranscriptAuthLocalDesc =>
      'Transcription happens on this device (requires a model download at the first use).';

  @override
  String get voiceTranscriptAuthServer => 'Remote';

  @override
  String get voiceTranscriptAuthServerDesc =>
      'Voice messages are sent to our cloud server, and deleted immediately after transcribing.';

  @override
  String voiceTranscriptServerFailed(String error) {
    return 'Server transcription failed: $error';
  }

  @override
  String get voiceTranscriptServerDisabled =>
      'Server transcription isn\'t enabled — used the local model instead';

  @override
  String get voiceTranscriptGroupEngine => 'Where to transcribe';

  @override
  String get voiceTranscriptTimingLabel => 'When to transcribe';

  @override
  String get voiceTranscriptEngineLocalShort => 'Local';

  @override
  String get voiceTranscriptEngineServerShort => 'Remote';

  @override
  String get voiceTranscriptAutoOn => 'Auto';

  @override
  String get voiceTranscriptAutoOff => 'Manual';

  @override
  String get voiceTranscriptAutoModeDesc =>
      'Transcribe automatically when it arrives';

  @override
  String get voiceTranscriptManualModeDesc =>
      'Transcribe on-demand when you ask it to';

  @override
  String get voiceTranscriptMenuTranscribe => 'Transcribe';

  @override
  String get voiceTranscriptPreparing => 'Preparing transcription model…';

  @override
  String voiceTranscriptPrepareFailed(String error) {
    return 'Failed to prepare transcription model: $error';
  }

  @override
  String get chatPageAttachmentMetaMissing => 'Attachment metadata missing';

  @override
  String get chatPageAttachmentUnusable => 'Attachment unavailable';

  @override
  String get chatPageAttachmentRetry => 'Tap to retry';

  @override
  String chatPageSaved(String path) {
    return 'Saved: $path';
  }

  @override
  String chatPageDownloadFailed(String error) {
    return 'Download failed: $error';
  }

  @override
  String get chatPageAttachmentTapToDownload =>
      'Not on this device — tap to download again';

  @override
  String get chatPageVideoLoadFailed => 'Video failed to load — tap to retry';

  @override
  String get chatPageVideoUnsupportedPlatform =>
      'This device can\'t play video — tap to save it';

  @override
  String chatPageFileOpenFailed(String error) {
    return 'Could not open file: $error';
  }

  @override
  String get chatPageEntranceRevoked =>
      'Entrance revoked — local data cleared, please set up again';

  @override
  String get burnOptionOff => 'Do not auto-burn';

  @override
  String get burnSubmit => 'Apply';

  @override
  String burnPreviewDelay(String duration) {
    return '$duration';
  }

  @override
  String burnUnitDays(int count) {
    return '${count}d';
  }

  @override
  String burnUnitHours(int count) {
    return '${count}h';
  }

  @override
  String burnUnitMinutes(int count) {
    return '${count}m';
  }

  @override
  String burnUnitSeconds(int count) {
    return '${count}s';
  }

  @override
  String get burnAxisOffLabel => 'Off';

  @override
  String get lockPageTitle => 'My Einz';

  @override
  String get lockPagePinPrompt => 'Enter PIN to unlock';

  @override
  String lockPageLockedSeconds(int seconds) {
    return 'Locked for ${seconds}s';
  }

  @override
  String get lockPageNoPinSet =>
      'No PIN set (lock screen activates only with a PIN)';

  @override
  String get lockPageUnlock => 'Unlock';

  @override
  String lockPageTooManyAttempts(int seconds) {
    return 'Too many attempts, try again in ${seconds}s';
  }

  @override
  String lockPageUnlockFailed(String error) {
    return 'Unlock failed: $error';
  }

  @override
  String get lockPageForgotPinHint =>
      'Forgot your PIN? You can uninstall and reinstall the app, then rejoin your spaces with an invite code and the shared passphrase.';

  @override
  String get chatPageMenuAbout => 'About Einz';

  @override
  String get aboutPageTitle => 'About Einz';

  @override
  String get aboutIntro =>
      'Einz is the secret realm where you and your selected companions chat and share in your own spaces, away from the world. Everything stays under your control, on your own device — no account, no trace. No third party, including Einz itself, can peek at the content, fully safeguarding your privacy.';

  @override
  String get aboutVersionLabel => 'Version';

  @override
  String get aboutDownloadLabel => 'Download';

  @override
  String get aboutServerLabel => 'Server';

  @override
  String get aboutServerDevNote => 'Development address for debugging only';

  @override
  String get aboutStatusLabel => 'Connection';

  @override
  String get aboutStatusChecking => 'Checking…';

  @override
  String get aboutStatusConnected => 'Connected';

  @override
  String get aboutStatusUnreachable => 'Unreachable';

  @override
  String get aboutDnsPoisonLabel => 'DNS poisoning';

  @override
  String aboutDnsPoisonValue(String host, String ip) {
    return '$host hijacked to $ip';
  }

  @override
  String get aboutDnsPoisonUnknownIp => 'unknown';

  @override
  String get aboutDnsPoisonNote =>
      'Your network is hijacking DNS resolution for this domain (the fake address is shown above); the connection was automatically repaired via encrypted DNS (DoH) and the incident was reported to the server. The real address is protected and not shown';

  @override
  String get advancedMenuTitle => 'Advanced security';

  @override
  String get advancedDestroyEntrance => 'Destroy this entrance';

  @override
  String get advancedClearMessages => 'Delete all messages';

  @override
  String get clearMessagesMessage =>
      'Deletes all messages and attachments saved in the current entrance. The entrance stays usable and will keep receiving new messages. Other entrances are unaffected.';

  @override
  String get clearMessagesConfirm => 'Delete';

  @override
  String get clearMessagesDone => 'All messages deleted.';

  @override
  String clearMessagesFailed(String error) {
    return 'Delete failed: $error';
  }

  @override
  String get leaveSpaceTitle => 'Destroy this entrance?';

  @override
  String get leaveSpaceMessage =>
      'Permanently erases all messages, attachments and credentials of the current entrance, then takes you back to the setup wizard. The space itself and its data are kept; other entrances are unaffected. This cannot be undone!';

  @override
  String resetEntranceNameLabel(String name) {
    return '$name';
  }

  @override
  String resetEntranceNameHint(String name) {
    return 'Type the current entrance name “$name”';
  }

  @override
  String get resetEntranceNameMismatch =>
      'Enter the correct entrance name to confirm';

  @override
  String get resetEntranceConfirmWord => 'RESET';

  @override
  String get resetEntrancePinLabel => 'PIN';

  @override
  String get resetEntrancePinHint => 'Enter this device\'s PIN';

  @override
  String get resetEntranceServerResidualHint =>
      '⚠️ Local data erased, but retiring it on the server failed; the others may still see this entrance';

  @override
  String get spaceListHint => 'Tap another space to switch to it';

  @override
  String get spaceListTitle => 'My Einz spaces';

  @override
  String get spaceListEmpty => 'No spaces joined yet';

  @override
  String get spaceListAdd => 'Add another space';

  @override
  String get spaceListSwitch => 'My Einz spaces';

  @override
  String get promptLockCodeTitle => 'Enter your PIN';

  @override
  String get promptLockCodeHint =>
      'Verify this device\'s lock screen code first';

  @override
  String get leaveSpaceConfirm => 'Destroy';

  @override
  String get exitGroupTitle => 'Leave group?';

  @override
  String get exitGroupMessage =>
      'Leaving removes this group from all your devices and erases local data immediately. This cannot be undone!';

  @override
  String get exitGroupConfirm => 'Leave';

  @override
  String exitGroupNameHint(String name) {
    return 'Type the group name “$name”';
  }

  @override
  String exitGroupNameLabel(String name) {
    return '$name';
  }

  @override
  String get exitGroupNameMismatch => 'Enter the correct group name to confirm';

  @override
  String exitGroupConfirmWordHint(String word) {
    return 'This group has no name yet. Type “$word” to confirm';
  }

  @override
  String get exitGroupConfirmWordMismatch =>
      'Enter the correct confirmation word';

  @override
  String get exitGroupFailed =>
      'Couldn\'t leave the group — you\'re still in it';

  @override
  String get exitGroupMenuItem => 'Leave group';

  @override
  String chatPageMemberLeftNotice(String name) {
    return '$name left the group';
  }

  @override
  String errorBackend(String message) {
    return 'Server: $message';
  }

  @override
  String get memberPending => 'Waiting';

  @override
  String get voiceCallIncoming => 'Incoming call';

  @override
  String get voiceCallCalling => 'Calling…';

  @override
  String get voiceCallConnecting => 'Connecting…';

  @override
  String get voiceCallAccept => 'Accept';

  @override
  String get voiceCallDecline => 'Decline';

  @override
  String get voiceCallCancel => 'Cancel';

  @override
  String get voiceCallHangUp => 'Hang up';

  @override
  String get voiceCallMute => 'Mute';

  @override
  String get voiceCallUnmute => 'Unmute';

  @override
  String get voiceCallSpeaker => 'Speaker';

  @override
  String get voiceCallSpeakerOff => 'Speaker off';

  @override
  String get voiceCallEnded => 'Call ended';

  @override
  String get voiceCallEndedDeclined => 'Call declined';

  @override
  String get voiceCallEndedBusy => 'Busy';

  @override
  String get voiceCallEndedNoAnswer => 'No answer';

  @override
  String get voiceCallEndedCanceled => 'Call canceled';

  @override
  String get voiceCallEndedFailed => 'Call failed';

  @override
  String get voiceCallForegroundOnly =>
      'Calls connect only while both sides have Einz open';

  @override
  String voiceCallRecordDuration(String duration) {
    return 'Call duration $duration';
  }

  @override
  String get chatPageAvatarChange => 'Change avatar';

  @override
  String get chatPageDropHint => 'Drop to send';

  @override
  String get chatPageDropHintSub => 'Images, videos, audio, files';

  @override
  String chatPageAttachmentTooLarge(String limit) {
    return 'This file is too large; the server limit is $limit';
  }

  @override
  String get chatPageAttachmentTooLargeUnknown =>
      'The file is too large and was rejected by the server';
}
