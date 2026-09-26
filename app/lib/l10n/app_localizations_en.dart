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
  String get skip => 'Skip';

  @override
  String get close => 'Close';

  @override
  String get setupPageEnvelopeKeyHint =>
      'A key envelope is an asymmetrically encrypted text handed over in person. Ask your partner for it.';

  @override
  String get setupPageNeedPassphrase => 'Enter a shared passphrase';

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
  String get wizardNameHint => 'Name (can be changed later)';

  @override
  String get wizardPeerNameHint => 'Partner\'s name (can be changed later)';

  @override
  String get wizardPeerNameHintInput => 'Partner\'s name';

  @override
  String get wizardNameRequired => 'Enter your name';

  @override
  String get wizardPeerNameRequired => 'Enter your partner\'s name';

  @override
  String get wizardPeerNameSameName => 'The two names must be different';

  @override
  String get wizardNameInvalidError =>
      'Only Chinese/English letters, digits, _ , - and emoji are allowed.';

  @override
  String wizardNameTooLongError(int max) {
    return 'At most $max characters';
  }

  @override
  String get wizardNameHintInput => 'Name';

  @override
  String get wizardMyGenderLabel => 'Gender';

  @override
  String get wizardPeerGenderLabel => 'Partner\'s gender';

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
  String get wizardAppBarOffline => 'Import key envelope';

  @override
  String get wizardNext => 'Next';

  @override
  String get wizardBack => 'Back';

  @override
  String get wizardDone => 'Done';

  @override
  String get wizardTitleName => 'About me';

  @override
  String get wizardTitlePeerName => 'About partner';

  @override
  String get wizardTitleJoinIdentity => 'Choose your identity';

  @override
  String get wizardJoinIdentityHint =>
      'One space has exactly two partners. Which one is you?';

  @override
  String get wizardJoinNoSlots => 'No preset members — cannot join';

  @override
  String get wizardSlotRequired => 'Pick an identity';

  @override
  String get wizardSpaceLimit =>
      'Space limit reached (server maxSpaces), cannot create';

  @override
  String get wizardTitlePassphrase => 'Set passphrase';

  @override
  String get wizardJoinPassphraseTitle => 'Verify passphrase';

  @override
  String get wizardTitlePin => 'Set PIN';

  @override
  String get wizardTitleEnvelope => 'Key envelope';

  @override
  String get wizardEnrollExists =>
      'This server already has a space (created by another entrance). Use the Join flow with your partner\'s one-time token.';

  @override
  String get wizardEnrollGoJoin => 'Use Join flow';

  @override
  String wizardEnrollFailed(String error) {
    return '❌ Enrollment failed: $error';
  }

  @override
  String get wizardPassphraseHint =>
      'The passphrase is shared by you and your partner to protect private messages. Memorize it and never leak it; share it only with your partner.';

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
  String get wizardJoinPassphraseHint =>
      'The passphrase is shared by you and your partner to protect private messages. Don\'t know it? Ask your partner.';

  @override
  String get wizardJoinPassphraseWrong =>
      'Wrong passphrase: use the one set on the first entrance';

  @override
  String get wizardSwitchToEnvelope => 'Use key envelope instead (offline)';

  @override
  String get wizardSwitchToPassphrase => 'Use a shared passphrase instead';

  @override
  String get wizardPinHint =>
      'Device-specific lock PIN. Enter it each time you launch.';

  @override
  String get welcomeDialogTitleCreate => 'All set!';

  @override
  String get welcomeDialogTitleJoin => 'All set!';

  @override
  String get welcomeDialogMessage =>
      'Just the two of you, end-to-end encrypted for total privacy. Enter now and start chatting!';

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
      'Einz is a secret space for two partners. You can create a new one, or join an existing one by invitation.';

  @override
  String get setupEntryCreate => 'Create';

  @override
  String get setupEntryJoin => 'Join';

  @override
  String get setupEntryLegacyServer =>
      'Server version too old — please upgrade';

  @override
  String setupTokenAppTooOld(String code) {
    return 'This app is too old for the server ($code). Please update the app and try again';
  }

  @override
  String setupTokenRateLimited(String seconds) {
    return 'Too many requests — retry in ${seconds}s (this is not a problem with the token)';
  }

  @override
  String get setupTokenRateLimitedNoWait =>
      'Too many requests — try again later (this is not a problem with the token)';

  @override
  String get setupTokenTitle => 'Verify token';

  @override
  String get setupTokenHint =>
      'Open the dedicated entrance from this device to the space. A token is valid for one-time use within 24 hours, generated from any verified entrance in the space.';

  @override
  String get setupTokenInputHint => 'Paste the token or invite link';

  @override
  String get setupTokenNeedInput => 'Enter the token';

  @override
  String get setupTokenInvalid => 'Invalid token';

  @override
  String get setupTokenExpired => 'Token expired';

  @override
  String get setupTokenUsed => 'Token already used';

  @override
  String get setupTokenSpaceAlreadyAdded =>
      'This space is already added (one device can hold only one entrance to a space)';

  @override
  String setupTokenOtherServer(String other, String current) {
    return 'the invite link is from $other but this app is connected to $current; they cannot work with each other.';
  }

  @override
  String get setupCreateShareTitle => 'Send the invite link to your partner:';

  @override
  String get setupCreateCopy => 'Copy invite link';

  @override
  String get setupCreateCopied => 'Copied';

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
  String get setupPagePasteEnvelope => '⚠️ Paste the key envelope (base64)';

  @override
  String get setupPageScanInvite => 'Scan token QR code';

  @override
  String get setupPageScannerHint => 'Point the camera at the token QR code';

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
  String get setPinDialogPinLabel => 'New PIN (at least 6 digits)';

  @override
  String get setPinDialogPinHint => 'At least 6 digits';

  @override
  String get setPinDialogConfirmLabel => 'Confirm new PIN';

  @override
  String get setPinDialogConfirmHint => 'Type it again to confirm';

  @override
  String get setPinDialogSetPin => 'Submit';

  @override
  String get setPinDialogPinTooShort => 'PIN must be at least 6 digits';

  @override
  String get setPinDialogPinDigitsOnly => 'Digits only';

  @override
  String get setPinDialogPinMismatch => 'PINs do not match';

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
  String get chatPageSetLockClearHint =>
      'Once set, you\'ll unlock every time you enter the space. You can also leave the new PIN blank to delete the current PIN.';

  @override
  String get chatPageSetLockHintNoPin =>
      'Once set, you\'ll unlock every time you enter the space.';

  @override
  String get chatPageSetLockOldLabel => 'Current PIN';

  @override
  String get chatPageSetLockOldRequired => 'Enter current PIN first';

  @override
  String get chatPageSetLockSameAsOld =>
      'New PIN is the same as the current one, nothing is changed.';

  @override
  String get chatPageSetLockNoPinNotice =>
      'No PIN set. Next launch goes straight into the space.';

  @override
  String get chatPageSetLockDone =>
      'PIN set. You must enter PIN to unlock the space at next launch.';

  @override
  String get chatPageSetLockCleared =>
      'PIN deleted. You can enter the space directly at next launch.';

  @override
  String get chatPageClearLockTitle => 'Delete PIN?';

  @override
  String get chatPageClearLockMessage =>
      'Delete the PIN? After deletion, next app launch will go straight into chat.';

  @override
  String get chatPageInviteDialogTitle => 'Token created';

  @override
  String get chatPageInviteJoinLink => 'Invite';

  @override
  String get chatPageInviteRegenerate => 'Regenerate';

  @override
  String get chatPageInviteDialogHint =>
      'Send it to your partner — or another device of your own — to setup a new entrance into this space. One-time use, valid for 24 hours.';

  @override
  String get chatPageInviteCopyLinkTooltip => 'Copy invite link';

  @override
  String get chatPageInviteCopyCodeTooltip => 'Copy token';

  @override
  String get chatPageInviteLinkCopied => 'Invite link copied';

  @override
  String get chatPageInviteCodeCopied => 'Token copied';

  @override
  String chatPageInviteFailed(String error) {
    return 'Failed to create the token: $error';
  }

  @override
  String get chatPageTitleBrand => 'My Einz';

  @override
  String get chatPageMenuChangePassphrase => 'Change shared passphrase';

  @override
  String get chatPageMenuAvatar => 'My avatar';

  @override
  String get chatPageAvatarUploaded => '✅ Avatar updated';

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
  String get chatPageMenuMore => 'Menu';

  @override
  String get chatPageRenameNameTitle => 'My identity';

  @override
  String get chatPageRenameNameLabel => 'Name';

  @override
  String get chatPageGenderLabel => 'Gender';

  @override
  String get chatPageRenameEntranceTitle => 'Current entrance';

  @override
  String get chatPageRenameEntranceLabel => 'Entrance name';

  @override
  String get chatPageEntranceScopeHint =>
      'An entrance is the dedicated line between a device and a space. Settings here apply only to this entrance.';

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
      'Can\'t match your partner\'s name — pick another';

  @override
  String get chatPageCopy => 'Copy';

  @override
  String get chatPagePublicKeyCopied => 'Public key copied';

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
  String get save => 'Save';

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
  String get chatPageChangePassphraseDone =>
      '✅ Shared passphrase updated — tell your partner; new entrances must use the new one';

  @override
  String chatPageChangePassphraseFailed(String error) {
    return 'Failed to change passphrase: $error';
  }

  @override
  String get chatPageEscrowRotatedNotice =>
      'Your partner reset the shared passphrase — use the new one to create tokens or change it';

  @override
  String get chatPageMenuLocaleLabel => 'Language';

  @override
  String get chatPageMenuAttachmentStorage => 'Attachment storage';

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
  String get chatPageAttachmentStorageSubmit => 'Submit';

  @override
  String get chatPageAttachmentStorageWarnClear =>
      'Switching to \"Remote only\" immediately deletes locally stored attachments';

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
  String get chatPageMenuMyNameLabel => 'My identity';

  @override
  String get chatPageMenuEntranceNameLabel => 'Current entrance';

  @override
  String get chatPageMenuEntranceList => 'More entrances';

  @override
  String get chatPageEntranceListFailed =>
      'Could not load other entrances (offline?)';

  @override
  String get chatPageEntranceListNew => 'Generate entrance token';

  @override
  String get chatPageEntranceListRefresh => 'Refresh';

  @override
  String get chatPagePinLabel => 'PIN';

  @override
  String get chatPageLockNow => 'Lock now';

  @override
  String get chatPagePinSetValue => 'Set';

  @override
  String get chatPageBurnHeading => 'Burn-after-read';

  @override
  String get chatPageBurnNote =>
      'New messages are deleted on a countdown once read';

  @override
  String get chatPageBurnOff =>
      'Burn-after-read is off (this message will be kept)';

  @override
  String get chatPageBurnFailed => 'Failed to set burn-after-read';

  @override
  String chatPageBurnWillDelete(String duration) {
    return 'New messages auto-delete after $duration';
  }

  @override
  String get chatPageActionDelete => 'Delete now';

  @override
  String get chatPageActionQuote => 'Quote';

  @override
  String get chatPageActionBurn => 'Burn after reading';

  @override
  String get chatPageDeleteConfirmTitle => 'Delete message';

  @override
  String get chatPageDeleteConfirmMessage =>
      'Removed only on this device; the other side is unaffected and it can\'t be undone. Delete?';

  @override
  String get chatPageDeleteCancel => 'Cancel';

  @override
  String get chatPageDeleteConfirmOk => 'Delete';

  @override
  String chatPageSendFailed(String error) {
    return 'Send failed: $error';
  }

  @override
  String get chatPageMsgSent => 'Sent';

  @override
  String get chatPageMsgSendingTap => 'Sending… tap to verify and resend';

  @override
  String get chatPageMsgDelivered => 'Delivered';

  @override
  String get chatPageMsgFailed => 'Send failed, tap to retry';

  @override
  String get chatPageMsgFailedTap => 'Tap to resend';

  @override
  String chatPageOfflineUnsent(int count) {
    return 'Offline · $count unsent';
  }

  @override
  String get chatPageEntranceUnrecognized =>
      'This entrance is not recognized by the server (its data may have been reset) · local messages only, no sync; your local data is NOT cleared';

  @override
  String get chatPageOfflineLocalOnly =>
      'Offline · local messages only, cannot send or receive';

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
  String get chatPageEmojiKeyboard => 'Keyboard';

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
  String get chatPagePlaying => 'Playing…';

  @override
  String get chatPageVoiceLabel => 'Voice';

  @override
  String get chatPageAttachmentMetaMissing => 'Attachment metadata missing';

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
  String chatPageFileOpenFailed(String error) {
    return 'Could not open file: $error';
  }

  @override
  String get chatPageEntranceRevoked =>
      'Entrance revoked — local data cleared, please set up again';

  @override
  String get chatPageEntrancePublicKeyLabel => 'Public key of this entrance';

  @override
  String get chatPageEntrancePublicKeyFailed => 'Not recorded';

  @override
  String get burnOptionOff => 'Off (Do not burn anymore)';

  @override
  String get burnOption1Minute => '1 minute';

  @override
  String get burnOption5Minutes => '5 minutes';

  @override
  String get burnOption1Hour => '1 hour';

  @override
  String get burnOption1Day => '1 day';

  @override
  String get burnOption7Days => '7 days';

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
  String get chatPageMenuAbout => 'About Einz';

  @override
  String get aboutPageTitle => 'About Einz';

  @override
  String get aboutIntro =>
      'Einz is a secret space for just two partners: all messages and attachments are end-to-end encrypted, and no third party — including Einz itself — can read them, strictly safeguarding your privacy.';

  @override
  String get aboutVersionLabel => 'Version';

  @override
  String get aboutServerLabel => 'Server';

  @override
  String get aboutServerDevNote => 'Development address for debugging only';

  @override
  String get advancedMenuTitle => 'Advanced security';

  @override
  String get advancedDestroyEntrance => 'Destroy this entrance';

  @override
  String get leaveSpaceTitle => 'Destroy this entrance?';

  @override
  String get leaveSpaceMessage =>
      'Permanently erases all messages, attachments and credentials of the current space from this device, then takes you back to the space wizard. The space itself and its data are kept; other entrances are unaffected. This cannot be undone!';

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
      '⚠️ Local data erased, but retiring it on the server failed; this entrance may still show up in your partner\'s entrance list';

  @override
  String get spaceListTitle => 'Switch my space';

  @override
  String get spaceListEmpty => 'No spaces joined yet';

  @override
  String get spaceListAdd => 'Add a space';

  @override
  String get spaceListSwitch => 'Switch my space';

  @override
  String get promptLockCodeTitle => 'Enter your PIN';

  @override
  String get promptLockCodeHint =>
      'Verify this device\'s lock screen code first';

  @override
  String get leaveSpaceConfirm => 'Destroy';

  @override
  String get setupPinReuseNotice => 'This space will share the current PIN.';

  @override
  String errorBackend(String message) {
    return 'Server: $message';
  }

  @override
  String get spaceListPeerPending => 'Not joined yet';

  @override
  String get voiceCallMenuCall => 'Voice call';

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
}
