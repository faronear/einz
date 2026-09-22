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
      'Offline handover text (asymmetric encryption). Get it from your partner.';

  @override
  String get setupPageNeedPassphrase => '❗️ Set a shared passphrase first';

  @override
  String get wizardJoinPassphraseRequired =>
      '❗️ Enter the shared passphrase to verify';

  @override
  String get setupEnrollBoundNotice => '🎉 New entrance opened';

  @override
  String get wizardStartTitle => 'Setup wizard';

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
  String get wizardNameHint => 'Your name (you can change it later)';

  @override
  String get wizardPeerNameHint =>
      'Your partner\'s name (you can change it later)';

  @override
  String get wizardPeerNameHintInput => 'Partner\'s name';

  @override
  String get wizardNameRequired => 'Enter your name';

  @override
  String get wizardPeerNameRequired => 'Enter your partner\'s name';

  @override
  String get wizardNameInvalidError =>
      'Only Chinese/English letters, digits, _ , - and emoji are allowed';

  @override
  String wizardNameTooLongError(int max) {
    return 'At most $max characters';
  }

  @override
  String get wizardNameHintInput => 'Your name';

  @override
  String get wizardMyGenderLabel => 'Your gender';

  @override
  String get wizardPeerGenderLabel => 'Partner\'s gender';

  @override
  String get wizardGenderMale => 'Male';

  @override
  String get wizardGenderFemale => 'Female';

  @override
  String get wizardGenderRequired => 'Select a gender';

  @override
  String get wizardIdentityHint => 'Limited to two people — choose your role';

  @override
  String get wizardIdentityCreator => 'Creator';

  @override
  String get wizardIdentityPartner => 'Partner';

  @override
  String get wizardIdentityFirst => '⚠️ Pick your role first';

  @override
  String get wizardInviteHint =>
      'Any existing entrance can create a token (one-time, valid for 24 hours).';

  @override
  String get wizardRoleOffline => 'Import key envelope (offline)';

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
      'One space for two partners. Which one is you?';

  @override
  String get wizardJoinNoSlots => 'No preset members — cannot join';

  @override
  String get wizardSlotOnline => 'online';

  @override
  String get wizardSlotRequired => 'Pick an identity';

  @override
  String get wizardSpaceLimit =>
      'Space limit reached (server maxSpaces) — cannot create';

  @override
  String get wizardTitleInvite => 'Verify token';

  @override
  String get wizardTitlePassphrase => 'Set shared passphrase';

  @override
  String get wizardJoinPassphraseTitle => 'Verify shared passphrase';

  @override
  String get wizardTitlePin => 'Set PIN';

  @override
  String get wizardTitleEnvelope => 'Key envelope';

  @override
  String get wizardTitleIdentity => 'I am';

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
      'The shared passphrase is held by you and your partner, and encrypts every message. Memorize it; tell no one but your partner.';

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
      'The shared passphrase is held by you and your partner to protect messages. Don\'t know it? Ask your partner.';

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
      'Just the two of you, end-to-end encrypted for total privacy. Enter Einz and start chatting.';

  @override
  String get welcomeDialogStart => 'Enter Einz';

  @override
  String setupPageKeyGenFailed(String error) {
    return '❌ Key generation failed: $error';
  }

  @override
  String get setupEntryTitle => 'Choose a space';

  @override
  String get setupEntryHint =>
      'Create a secret space for two, or join an existing space with a one-time token.';

  @override
  String get setupEntryCreate => 'Create';

  @override
  String get setupEntryJoin => 'Join';

  @override
  String get setupEntryLegacyServer =>
      'Server version too old — please upgrade';

  @override
  String setupTokenAppTooOld(String code) {
    return 'This app is too old for the server ($code) — please update the app and try again';
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
      'A token is valid for one-time use within 24 hours.';

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
  String get setupTokenSpaceFull => 'Space is full';

  @override
  String setupTokenOtherServer(String other, String current) {
    return 'the invite link is from $other but this app is connected to $current; they cannot work with each other.';
  }

  @override
  String setupTokenSpaceInfo(String name) {
    return 'Join $name\'s space';
  }

  @override
  String get setupTokenSpacePrivate =>
      'Join a private space (waiting for the second member)';

  @override
  String get setupCreateShareTitle =>
      'Send the token to your partner — or use it on another device of your own (valid for 24 hours)';

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
  String get setupPagePasteEnvelope => '⚠️ Paste the key envelope (base64)';

  @override
  String get wizardEnvelopeWrong =>
      'Invalid key envelope: paste the full sealed copy from another entrance';

  @override
  String get setupPageInviteHint => 'Paste or type the token';

  @override
  String get setupPageNeedInvite => '⚠️ Enter the one-time token';

  @override
  String get setupPageScanInvite => 'Scan token QR code';

  @override
  String get setupPageScannerHint => 'Point the camera at the token QR code';

  @override
  String get wizardInviteWrong =>
      'Invalid token: use a one-time token from an existing entrance';

  @override
  String get setupPageNoEscrow =>
      '❌ No escrow package for the shared passphrase on the server — set it on the first entrance first';

  @override
  String setupPageEscrowFailed(String error) {
    return '❌ Shared passphrase join failed: $error';
  }

  @override
  String get setPinDialogPinLabel => 'PIN (at least 6 digits)';

  @override
  String get setPinDialogPinHint => 'At least 6 digits';

  @override
  String get setPinDialogConfirmLabel => 'Confirm PIN';

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
  String setPinDialogSetupFailed(String error) {
    return 'Setup failed: $error';
  }

  @override
  String chatPageLocaleSwitched(String label) {
    return 'Switched to $label';
  }

  @override
  String get chatPageSetLockTitle => 'Set app lock';

  @override
  String get chatPageSetLockClearHint =>
      'Once set, you\'ll unlock every time you enter the space — safer. You can also leave the new PIN blank to clear it.';

  @override
  String get chatPageSetLockHintNoPin =>
      'Once set, you\'ll unlock every time you enter the space — safer.';

  @override
  String get chatPageSetLockOldLabel => 'Current PIN';

  @override
  String get chatPageSetLockOldRequired => 'Enter your current PIN first';

  @override
  String get chatPageSetLockSameAsOld =>
      'New PIN is the same as the current one — nothing changed';

  @override
  String get chatPageSetLockNoPinNotice =>
      'No PIN set — next launch goes straight into the space';

  @override
  String get chatPageSetLockDone =>
      'App lock set — PIN required at next launch';

  @override
  String get chatPageSetLockCleared =>
      'App lock cleared (enter directly next time)';

  @override
  String get chatPageClearLockTitle => 'Clear app lock?';

  @override
  String get chatPageClearLockMessage =>
      'A blank new PIN clears the app lock — clear it? Next launch will go straight into chat.';

  @override
  String get chatPageMenuInvite => 'New entrance token';

  @override
  String get chatPageInviteDialogTitle => 'Token created';

  @override
  String get chatPageInviteDialogHint =>
      'Invite your partner — or another device of your own — to open a new entrance to this space. One-time use, valid for 24 hours.';

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
  String get chatPageMenuAvatar => 'Avatar';

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
  String get chatPageRenameNameTitle => 'My profile';

  @override
  String get chatPageRenameNameLabel => 'My name';

  @override
  String get chatPageGenderLabel => 'Gender';

  @override
  String get chatPageRenameDeviceTitle => 'This entrance in this space';

  @override
  String get chatPageRenameDeviceLabel => 'Name of this entrance';

  @override
  String get chatPageDeviceScopeHint =>
      'They belong to this entrance only — the same phone or computer has its own set in every space.';

  @override
  String get chatPageRenameDeviceEmptyError => 'Name cannot be empty';

  @override
  String get chatPageRenameDeviceInvalidError =>
      'Only Chinese/English letters, digits, _ and - are allowed';

  @override
  String chatPageRenameDeviceTooLongError(int max) {
    return 'At most $max characters';
  }

  @override
  String get chatPageRenameMyselfEmptyError => 'Name cannot be empty';

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
  String get chatPageChangePassphraseTitle => 'Change shared passphrase';

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
      'New passphrase is the same as the current one — nothing changed';

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
      'Downloads and decrypts the attachment every time it is opened; no plaintext copy is kept';

  @override
  String get chatPageAttachmentStorageStored => 'Keep locally';

  @override
  String get chatPageAttachmentStorageStoredDesc =>
      'Keeps a decrypted copy after the first download, so opening it again is instant';

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
  String get chatPageMenuMyNameLabel => 'My name';

  @override
  String get chatPageMenuDeviceNameLabel => 'Entrance name';

  @override
  String get chatPagePinLabel => 'PIN';

  @override
  String get chatPageLockNow => 'Lock now';

  @override
  String get chatPagePinSetValue => 'Set';

  @override
  String get chatPagePinUnsetValue => 'Not set';

  @override
  String get chatPageBurnHeading => 'Burn-after-read (this device only)';

  @override
  String get chatPageBurnOff => 'Burn-after-read off (messages kept forever)';

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
  String get chatPageMsgSending => 'Sending…';

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
  String get chatPageDeviceUnrecognized =>
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
  String get chatPageVideoMetaMissing => 'Video metadata missing';

  @override
  String chatPageVideoPlayFailed(String error) {
    return 'Video playback failed: $error';
  }

  @override
  String chatPageImageLoadFailed(String plaintext) {
    return '$plaintext\n(failed to load)';
  }

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
  String get chatPageDeviceRevoked =>
      'Entrance revoked — local data cleared, please set up again';

  @override
  String get chatPageDevicePublicKeyLabel => 'Public key of this entrance';

  @override
  String get chatPageDevicePublicKeyFailed => 'Not recorded';

  @override
  String get burnOptionKeepIndefinitely => 'Keep indefinitely';

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
  String get lockPagePinLabel => 'PIN';

  @override
  String get lockPageNoPinSet =>
      'No app lock set (lock screen activates only with a PIN)';

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
      'Einz is a private chat and shared space for two: all messages and attachments are end-to-end encrypted, and no third party — including Einz itself — can read them, strictly safeguarding your privacy.';

  @override
  String get aboutVersionLabel => 'Version';

  @override
  String get aboutServerLabel => 'Server';

  @override
  String get aboutServerDevNote =>
      'Development address (not production), for debugging only';

  @override
  String get advancedMenuTitle => 'Advanced';

  @override
  String get advancedLeaveSpace => 'Destroy this entrance';

  @override
  String get leaveSpaceTitle => 'Destroy this entrance?';

  @override
  String get leaveSpaceMessage =>
      'Erases this space\'s messages, attachments and secrets from this device, then takes you back to the space setup wizard.\n\nThe space itself and its server-side data are kept, and your other entrances are untouched. You can join again later with a new token.\n\nThis cannot be undone!';

  @override
  String resetDeviceNameLabel(String name) {
    return 'Type \"$name\" to confirm';
  }

  @override
  String get resetDeviceNameMismatch => 'That does not match — try again';

  @override
  String get resetDeviceConfirmWord => 'RESET';

  @override
  String get resetDevicePinLabel => 'This device\'s PIN';

  @override
  String get resetDeviceServerResidualHint =>
      '⚠️ Local data erased, but retiring it on the server failed — this entrance may still show up in your partner\'s entrance list';

  @override
  String get spaceListTitle => 'Choose a space';

  @override
  String get spaceListEmpty => 'No spaces joined yet';

  @override
  String get spaceListAdd => 'Create or join a space';

  @override
  String get spaceListSwitch => 'Switch space';

  @override
  String get promptLockCodeTitle => 'Enter your lock code';

  @override
  String get promptLockCodeHint =>
      'Adding a space rewrites the encrypted vault — confirm with your lock code first';

  @override
  String get spaceListDeleteConfirm => 'Remove';

  @override
  String spaceListMe(String name) {
    return 'Me: $name';
  }

  @override
  String get setupPinReuseNotice =>
      'This space will use your current lock screen code.';
}
