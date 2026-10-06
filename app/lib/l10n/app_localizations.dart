import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @ok.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get ok;

  /// No description provided for @send.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get send;

  /// No description provided for @confirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get confirm;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @skip.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get skip;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @setupPageEnvelopeKeyHint.
  ///
  /// In en, this message translates to:
  /// **'A key envelope is an asymmetrically encrypted text handed over in person. Ask {mode, select, duo{your companion} other{your companions}} for it.'**
  String setupPageEnvelopeKeyHint(String mode);

  /// No description provided for @setupPageNeedPassphrase.
  ///
  /// In en, this message translates to:
  /// **'Enter a shared passphrase'**
  String get setupPageNeedPassphrase;

  /// No description provided for @upgradeRequiredTitle.
  ///
  /// In en, this message translates to:
  /// **'Update required'**
  String get upgradeRequiredTitle;

  /// No description provided for @upgradeRequiredBody.
  ///
  /// In en, this message translates to:
  /// **'This version is no longer supported by the server (needs at least {min}). Please update to continue.'**
  String upgradeRequiredBody(String min);

  /// No description provided for @upgradeRequiredCurrent.
  ///
  /// In en, this message translates to:
  /// **'Current version: {current}'**
  String upgradeRequiredCurrent(String current);

  /// No description provided for @upgradeRequiredDownload.
  ///
  /// In en, this message translates to:
  /// **'Download update'**
  String get upgradeRequiredDownload;

  /// No description provided for @upgradeRequiredRecheck.
  ///
  /// In en, this message translates to:
  /// **'Check again'**
  String get upgradeRequiredRecheck;

  /// No description provided for @wizardJoinPassphraseRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter the shared passphrase'**
  String get wizardJoinPassphraseRequired;

  /// No description provided for @wizardStartTitle.
  ///
  /// In en, this message translates to:
  /// **'Einz'**
  String get wizardStartTitle;

  /// No description provided for @wizardDetectTitle.
  ///
  /// In en, this message translates to:
  /// **'Checking server status…'**
  String get wizardDetectTitle;

  /// No description provided for @wizardDetectHint.
  ///
  /// In en, this message translates to:
  /// **'Auto-detects if this is the first entrance'**
  String get wizardDetectHint;

  /// No description provided for @wizardDetectFailed.
  ///
  /// In en, this message translates to:
  /// **'Cannot reach server — retrying…'**
  String get wizardDetectFailed;

  /// No description provided for @wizardProbeConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting to {server}…'**
  String wizardProbeConnecting(String server);

  /// No description provided for @wizardMyNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get wizardMyNameLabel;

  /// No description provided for @wizardNameRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter your name'**
  String get wizardNameRequired;

  /// No description provided for @wizardNameInvalidError.
  ///
  /// In en, this message translates to:
  /// **'Only Chinese/English letters, digits, _ , - and emoji are allowed.'**
  String get wizardNameInvalidError;

  /// No description provided for @wizardNameTooLongError.
  ///
  /// In en, this message translates to:
  /// **'At most {max} characters'**
  String wizardNameTooLongError(int max);

  /// No description provided for @wizardMyGenderLabel.
  ///
  /// In en, this message translates to:
  /// **'Gender'**
  String get wizardMyGenderLabel;

  /// No description provided for @wizardGenderMale.
  ///
  /// In en, this message translates to:
  /// **'Male'**
  String get wizardGenderMale;

  /// No description provided for @wizardGenderFemale.
  ///
  /// In en, this message translates to:
  /// **'Female'**
  String get wizardGenderFemale;

  /// No description provided for @wizardGenderRequired.
  ///
  /// In en, this message translates to:
  /// **'Select a gender'**
  String get wizardGenderRequired;

  /// No description provided for @wizardAppBarCreate.
  ///
  /// In en, this message translates to:
  /// **'Create a space'**
  String get wizardAppBarCreate;

  /// No description provided for @wizardAppBarJoin.
  ///
  /// In en, this message translates to:
  /// **'Join a space'**
  String get wizardAppBarJoin;

  /// No description provided for @wizardAppBarOffline.
  ///
  /// In en, this message translates to:
  /// **'Import key envelope'**
  String get wizardAppBarOffline;

  /// No description provided for @wizardNext.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get wizardNext;

  /// No description provided for @wizardBack.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get wizardBack;

  /// No description provided for @wizardDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get wizardDone;

  /// No description provided for @wizardTitleName.
  ///
  /// In en, this message translates to:
  /// **'About me'**
  String get wizardTitleName;

  /// No description provided for @wizardTitleSpaceKind.
  ///
  /// In en, this message translates to:
  /// **'Space type'**
  String get wizardTitleSpaceKind;

  /// No description provided for @wizardSpaceKindHint.
  ///
  /// In en, this message translates to:
  /// **'How many people will this space have?'**
  String get wizardSpaceKindHint;

  /// No description provided for @wizardSpaceKindDuo.
  ///
  /// In en, this message translates to:
  /// **'Duo space'**
  String get wizardSpaceKindDuo;

  /// No description provided for @wizardSpaceKindDuoDesc.
  ///
  /// In en, this message translates to:
  /// **'For just the two of you, no one else can be added later.'**
  String get wizardSpaceKindDuoDesc;

  /// No description provided for @wizardSpaceKindGroup.
  ///
  /// In en, this message translates to:
  /// **'Group space'**
  String get wizardSpaceKindGroup;

  /// No description provided for @wizardSpaceKindGroupDesc.
  ///
  /// In en, this message translates to:
  /// **'For multiple persons, every member can invite new ones.'**
  String get wizardSpaceKindGroupDesc;

  /// No description provided for @wizardSpaceKindRequired.
  ///
  /// In en, this message translates to:
  /// **'Please choose a space type'**
  String get wizardSpaceKindRequired;

  /// No description provided for @wizardSpaceLimit.
  ///
  /// In en, this message translates to:
  /// **'Space limit reached (server maxSpaces), cannot create'**
  String get wizardSpaceLimit;

  /// No description provided for @wizardTitlePassphrase.
  ///
  /// In en, this message translates to:
  /// **'Set passphrase'**
  String get wizardTitlePassphrase;

  /// No description provided for @wizardJoinPassphraseTitle.
  ///
  /// In en, this message translates to:
  /// **'Verify passphrase'**
  String get wizardJoinPassphraseTitle;

  /// No description provided for @wizardTitlePin.
  ///
  /// In en, this message translates to:
  /// **'Set PIN'**
  String get wizardTitlePin;

  /// No description provided for @wizardTitleEnvelope.
  ///
  /// In en, this message translates to:
  /// **'Key envelope'**
  String get wizardTitleEnvelope;

  /// No description provided for @wizardEnrollExists.
  ///
  /// In en, this message translates to:
  /// **'This server already has a space (created by another entrance). Use the Join flow with a one-time entrance token from the other person.'**
  String get wizardEnrollExists;

  /// No description provided for @wizardEnrollGoJoin.
  ///
  /// In en, this message translates to:
  /// **'Use Join flow'**
  String get wizardEnrollGoJoin;

  /// No description provided for @wizardEnrollFailed.
  ///
  /// In en, this message translates to:
  /// **'❌ Enrollment failed: {error}'**
  String wizardEnrollFailed(String error);

  /// No description provided for @wizardPassphraseHint.
  ///
  /// In en, this message translates to:
  /// **'The passphrase is the secret key to access the space, shared by you and {mode, select, duo{your companion} other{your companions}}. Memorize it and never leak it!'**
  String wizardPassphraseHint(String mode);

  /// No description provided for @wizardPassphraseMinLengthHint.
  ///
  /// In en, this message translates to:
  /// **'At least 8 characters'**
  String get wizardPassphraseMinLengthHint;

  /// No description provided for @wizardPassphraseTooShort.
  ///
  /// In en, this message translates to:
  /// **'Passphrase must be at least 8 characters'**
  String get wizardPassphraseTooShort;

  /// No description provided for @wizardPassphraseConfirmHint.
  ///
  /// In en, this message translates to:
  /// **'Re-enter passphrase'**
  String get wizardPassphraseConfirmHint;

  /// No description provided for @wizardPassphraseMismatch.
  ///
  /// In en, this message translates to:
  /// **'Passphrases do not match'**
  String get wizardPassphraseMismatch;

  /// No description provided for @wizardJoinPassphraseHint.
  ///
  /// In en, this message translates to:
  /// **'The passphrase is the secret key to access the space, shared by you and {mode, select, duo{your companion} other{your companions}}. Don\'t know it? Ask {mode, select, duo{your companion} other{your companions}}.'**
  String wizardJoinPassphraseHint(String mode);

  /// No description provided for @wizardJoinPassphraseWrong.
  ///
  /// In en, this message translates to:
  /// **'Wrong passphrase.'**
  String get wizardJoinPassphraseWrong;

  /// No description provided for @wizardSwitchToEnvelope.
  ///
  /// In en, this message translates to:
  /// **'Use key envelope instead (offline)'**
  String get wizardSwitchToEnvelope;

  /// No description provided for @wizardSwitchToPassphrase.
  ///
  /// In en, this message translates to:
  /// **'Use a shared passphrase instead'**
  String get wizardSwitchToPassphrase;

  /// No description provided for @wizardPinHint.
  ///
  /// In en, this message translates to:
  /// **'Lock your space with a device-specific PIN. Anyone who launches the app will be required to enter the PIN to unlock. You can also leave it blank for now, and set it later in the space.'**
  String get wizardPinHint;

  /// No description provided for @welcomeDialogTitleCreate.
  ///
  /// In en, this message translates to:
  /// **'All set!'**
  String get welcomeDialogTitleCreate;

  /// No description provided for @welcomeDialogTitleJoin.
  ///
  /// In en, this message translates to:
  /// **'All set!'**
  String get welcomeDialogTitleJoin;

  /// No description provided for @welcomeDialogMessage.
  ///
  /// In en, this message translates to:
  /// **'Your space is ready, end-to-end encrypted for total privacy. Enter now and start chatting!'**
  String get welcomeDialogMessage;

  /// No description provided for @welcomeDialogStart.
  ///
  /// In en, this message translates to:
  /// **'Enter Einz'**
  String get welcomeDialogStart;

  /// No description provided for @setupPageKeyGenFailed.
  ///
  /// In en, this message translates to:
  /// **'❌ Key generation failed: {error}'**
  String setupPageKeyGenFailed(String error);

  /// No description provided for @setupEntryTitle.
  ///
  /// In en, this message translates to:
  /// **'Einz wizard'**
  String get setupEntryTitle;

  /// No description provided for @setupEntryHint.
  ///
  /// In en, this message translates to:
  /// **'Einz is an end-to-end encrypted space for private chatting and sharing. You can create a new one, or join an existing one by invitation.'**
  String get setupEntryHint;

  /// No description provided for @setupEntryCreate.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get setupEntryCreate;

  /// No description provided for @setupEntryJoin.
  ///
  /// In en, this message translates to:
  /// **'Join'**
  String get setupEntryJoin;

  /// No description provided for @setupEntryLegacyServer.
  ///
  /// In en, this message translates to:
  /// **'Server version too old — please upgrade'**
  String get setupEntryLegacyServer;

  /// No description provided for @setupTokenAppTooOld.
  ///
  /// In en, this message translates to:
  /// **'This app is too old for the server ({code}). Please update the app and try again'**
  String setupTokenAppTooOld(String code);

  /// No description provided for @setupTokenRateLimited.
  ///
  /// In en, this message translates to:
  /// **'Too many requests — retry in {seconds}s (this is not a problem with the entrance token)'**
  String setupTokenRateLimited(String seconds);

  /// No description provided for @setupTokenRateLimitedNoWait.
  ///
  /// In en, this message translates to:
  /// **'Too many requests — try again later (this is not a problem with the entrance token)'**
  String get setupTokenRateLimitedNoWait;

  /// No description provided for @setupTokenTitle.
  ///
  /// In en, this message translates to:
  /// **'Verify entrance token'**
  String get setupTokenTitle;

  /// No description provided for @setupTokenHint.
  ///
  /// In en, this message translates to:
  /// **'Connect this device to the space. Valid for one-time use within 24 hours; generate it from any verified entrance in the space.'**
  String get setupTokenHint;

  /// No description provided for @setupTokenInputHint.
  ///
  /// In en, this message translates to:
  /// **'Entrance token'**
  String get setupTokenInputHint;

  /// No description provided for @setupTokenNeedInput.
  ///
  /// In en, this message translates to:
  /// **'Enter the entrance token'**
  String get setupTokenNeedInput;

  /// No description provided for @setupTokenInvalid.
  ///
  /// In en, this message translates to:
  /// **'Invalid entrance token'**
  String get setupTokenInvalid;

  /// No description provided for @setupTokenExpired.
  ///
  /// In en, this message translates to:
  /// **'Entrance token expired'**
  String get setupTokenExpired;

  /// No description provided for @setupTokenUsed.
  ///
  /// In en, this message translates to:
  /// **'Entrance token already used'**
  String get setupTokenUsed;

  /// No description provided for @setupTokenSpaceAlreadyAdded.
  ///
  /// In en, this message translates to:
  /// **'This device has already an entrance to this space (one device can hold only one entrance to a space)'**
  String get setupTokenSpaceAlreadyAdded;

  /// No description provided for @setupTokenOtherServer.
  ///
  /// In en, this message translates to:
  /// **'the invite link is from {other} but this app is connected to {current}; they cannot work with each other.'**
  String setupTokenOtherServer(String other, String current);

  /// No description provided for @setupCreateCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy invite link'**
  String get setupCreateCopy;

  /// No description provided for @setupCreateCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get setupCreateCopied;

  /// Friendly message when startup initialization (local database / server probe) fails — hides technical details (e.g. SqliteException), auto-retrying
  ///
  /// In en, this message translates to:
  /// **'Initialization failed, retrying…'**
  String get setupPageInitFailed;

  /// No description provided for @startupInitFailed.
  ///
  /// In en, this message translates to:
  /// **'Startup failed — your data is safe, please retry'**
  String get startupInitFailed;

  /// No description provided for @startupInitRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get startupInitRetry;

  /// Escape hatch on the startup-failure page: erase all local data and return to onboarding
  ///
  /// In en, this message translates to:
  /// **'Clear local data & start over'**
  String get startupInitClearData;

  /// No description provided for @startupInitClearDataTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear local data?'**
  String get startupInitClearDataTitle;

  /// No description provided for @startupInitClearDataMessage.
  ///
  /// In en, this message translates to:
  /// **'Erases everything stored on this device — secret spaces, messages, attachments, lock screen code and keys — and returns to setup. Use only when retry keeps failing; this cannot be undone.'**
  String get startupInitClearDataMessage;

  /// No description provided for @startupInitClearedRestart.
  ///
  /// In en, this message translates to:
  /// **'Local data cleared. Fully quit and reopen the app.'**
  String get startupInitClearedRestart;

  /// No description provided for @setupPagePasteEnvelope.
  ///
  /// In en, this message translates to:
  /// **'⚠️ Paste the key envelope (base64)'**
  String get setupPagePasteEnvelope;

  /// No description provided for @setupPageScanInvite.
  ///
  /// In en, this message translates to:
  /// **'Scan entrance token QR code'**
  String get setupPageScanInvite;

  /// No description provided for @setupPageScannerHint.
  ///
  /// In en, this message translates to:
  /// **'Point the camera at the entrance token QR code'**
  String get setupPageScannerHint;

  /// No description provided for @setupPageNoEscrow.
  ///
  /// In en, this message translates to:
  /// **'❌ No escrow package for the shared passphrase on the server — set it on the first entrance first'**
  String get setupPageNoEscrow;

  /// No description provided for @setupPageEscrowFailed.
  ///
  /// In en, this message translates to:
  /// **'❌ Shared passphrase join failed: {error}'**
  String setupPageEscrowFailed(String error);

  /// No description provided for @setupJoinEntranceLimitReached.
  ///
  /// In en, this message translates to:
  /// **'This space has reached the server\'s entrance limit — no new entrance can be opened.'**
  String get setupJoinEntranceLimitReached;

  /// No description provided for @setPinDialogPinLabel.
  ///
  /// In en, this message translates to:
  /// **'New PIN (at least 6 digits)'**
  String get setPinDialogPinLabel;

  /// No description provided for @setPinDialogPinHint.
  ///
  /// In en, this message translates to:
  /// **'At least 6 digits'**
  String get setPinDialogPinHint;

  /// No description provided for @setPinDialogConfirmLabel.
  ///
  /// In en, this message translates to:
  /// **'Confirm new PIN'**
  String get setPinDialogConfirmLabel;

  /// No description provided for @setPinDialogConfirmHint.
  ///
  /// In en, this message translates to:
  /// **'Type it again to confirm'**
  String get setPinDialogConfirmHint;

  /// No description provided for @setPinDialogSetPin.
  ///
  /// In en, this message translates to:
  /// **'Submit'**
  String get setPinDialogSetPin;

  /// No description provided for @setPinDialogPinTooShort.
  ///
  /// In en, this message translates to:
  /// **'PIN must be at least 6 digits'**
  String get setPinDialogPinTooShort;

  /// No description provided for @setPinDialogPinDigitsOnly.
  ///
  /// In en, this message translates to:
  /// **'Digits only'**
  String get setPinDialogPinDigitsOnly;

  /// No description provided for @setPinDialogPinMismatch.
  ///
  /// In en, this message translates to:
  /// **'PINs do not match'**
  String get setPinDialogPinMismatch;

  /// No description provided for @setPinDialogOldWrong.
  ///
  /// In en, this message translates to:
  /// **'Wrong current PIN'**
  String get setPinDialogOldWrong;

  /// No description provided for @verifyPinRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter your PIN to verify'**
  String get verifyPinRequired;

  /// No description provided for @verifyPinWrong.
  ///
  /// In en, this message translates to:
  /// **'Wrong PIN'**
  String get verifyPinWrong;

  /// No description provided for @setPinDialogSetupFailed.
  ///
  /// In en, this message translates to:
  /// **'Setup failed: {error}'**
  String setPinDialogSetupFailed(String error);

  /// No description provided for @chatPageLocaleSwitched.
  ///
  /// In en, this message translates to:
  /// **'Switched to {label}'**
  String chatPageLocaleSwitched(String label);

  /// No description provided for @chatPageSetLockTitle.
  ///
  /// In en, this message translates to:
  /// **'Set PIN'**
  String get chatPageSetLockTitle;

  /// No description provided for @chatPageSetLockClearHint.
  ///
  /// In en, this message translates to:
  /// **'Once set, you\'ll unlock every time you enter the space. You can also leave the new PIN blank to delete the current PIN.'**
  String get chatPageSetLockClearHint;

  /// No description provided for @chatPageSetLockHintNoPin.
  ///
  /// In en, this message translates to:
  /// **'Once set, you\'ll unlock every time you enter the space.'**
  String get chatPageSetLockHintNoPin;

  /// No description provided for @chatPageSetLockOldLabel.
  ///
  /// In en, this message translates to:
  /// **'Current PIN'**
  String get chatPageSetLockOldLabel;

  /// No description provided for @chatPageSetLockOldRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter current PIN first'**
  String get chatPageSetLockOldRequired;

  /// No description provided for @chatPageSetLockSameAsOld.
  ///
  /// In en, this message translates to:
  /// **'New PIN is the same as the current one, nothing is changed.'**
  String get chatPageSetLockSameAsOld;

  /// No description provided for @chatPageSetLockNoPinNotice.
  ///
  /// In en, this message translates to:
  /// **'No PIN set. Next launch goes straight into the space.'**
  String get chatPageSetLockNoPinNotice;

  /// No description provided for @chatPageSetLockDone.
  ///
  /// In en, this message translates to:
  /// **'PIN set. You must enter PIN to unlock the space at next launch.'**
  String get chatPageSetLockDone;

  /// No description provided for @chatPageSetLockCleared.
  ///
  /// In en, this message translates to:
  /// **'PIN deleted. You can enter the space directly at next launch.'**
  String get chatPageSetLockCleared;

  /// No description provided for @chatPageClearLockTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete PIN?'**
  String get chatPageClearLockTitle;

  /// No description provided for @chatPageClearLockMessage.
  ///
  /// In en, this message translates to:
  /// **'Delete the PIN? After deletion, next app launch will go straight into chat.'**
  String get chatPageClearLockMessage;

  /// No description provided for @chatPageInviteDialogTitleInvite.
  ///
  /// In en, this message translates to:
  /// **'Invite'**
  String get chatPageInviteDialogTitleInvite;

  /// No description provided for @chatPageInviteDialogTitleAttachSelf.
  ///
  /// In en, this message translates to:
  /// **'Add my new entrance'**
  String get chatPageInviteDialogTitleAttachSelf;

  /// No description provided for @chatPageInviteDialogTitleReinvite.
  ///
  /// In en, this message translates to:
  /// **'Re-invite'**
  String get chatPageInviteDialogTitleReinvite;

  /// No description provided for @chatPageInviteJoinLink.
  ///
  /// In en, this message translates to:
  /// **'Invite'**
  String get chatPageInviteJoinLink;

  /// No description provided for @chatPageInviteRegenerate.
  ///
  /// In en, this message translates to:
  /// **'Regenerate'**
  String get chatPageInviteRegenerate;

  /// No description provided for @chatPageInviteDialogHintInvite.
  ///
  /// In en, this message translates to:
  /// **'Send the dedicated entrance token below to whoever you\'re inviting to join this space. One-time use, valid for 24 hours.'**
  String get chatPageInviteDialogHintInvite;

  /// No description provided for @chatPageInviteDialogHintAttachSelf.
  ///
  /// In en, this message translates to:
  /// **'Use the dedicated entrance token below on my another device to connect to this space. One-time use, valid for 24 hours.'**
  String get chatPageInviteDialogHintAttachSelf;

  /// No description provided for @chatPageInviteDialogHintReinvite.
  ///
  /// In en, this message translates to:
  /// **'Send the dedicated entrance token below to “{name}” to join this space again. Existing entrances keep working. One-time use, valid for 24 hours.'**
  String chatPageInviteDialogHintReinvite(String name);

  /// No description provided for @chatPageInviteDialogReinviteFallbackName.
  ///
  /// In en, this message translates to:
  /// **'them'**
  String get chatPageInviteDialogReinviteFallbackName;

  /// No description provided for @chatPageInviteCopyLinkTooltip.
  ///
  /// In en, this message translates to:
  /// **'Copy invite link'**
  String get chatPageInviteCopyLinkTooltip;

  /// No description provided for @chatPageInviteCopyCodeTooltip.
  ///
  /// In en, this message translates to:
  /// **'Copy entrance token'**
  String get chatPageInviteCopyCodeTooltip;

  /// No description provided for @chatPageInviteLinkCopied.
  ///
  /// In en, this message translates to:
  /// **'Invite link copied'**
  String get chatPageInviteLinkCopied;

  /// No description provided for @chatPageInviteCodeCopied.
  ///
  /// In en, this message translates to:
  /// **'Entrance token copied'**
  String get chatPageInviteCodeCopied;

  /// No description provided for @chatPageInviteFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to create the entrance token: {error}'**
  String chatPageInviteFailed(String error);

  /// No description provided for @chatPageTitleBrand.
  ///
  /// In en, this message translates to:
  /// **'My Einz'**
  String get chatPageTitleBrand;

  /// No description provided for @chatPageMenuChangePassphrase.
  ///
  /// In en, this message translates to:
  /// **'Change shared passphrase'**
  String get chatPageMenuChangePassphrase;

  /// No description provided for @chatPageMenuAvatar.
  ///
  /// In en, this message translates to:
  /// **'My avatar'**
  String get chatPageMenuAvatar;

  /// No description provided for @chatPageAvatarUploaded.
  ///
  /// In en, this message translates to:
  /// **'✅ Avatar updated'**
  String get chatPageAvatarUploaded;

  /// No description provided for @chatPageAvatarTooLarge.
  ///
  /// In en, this message translates to:
  /// **'Image too large (max 2MB)'**
  String get chatPageAvatarTooLarge;

  /// No description provided for @chatPageAvatarFailed.
  ///
  /// In en, this message translates to:
  /// **'Avatar upload failed: {error}'**
  String chatPageAvatarFailed(String error);

  /// No description provided for @chatPageNameUnset.
  ///
  /// In en, this message translates to:
  /// **'Unset'**
  String get chatPageNameUnset;

  /// No description provided for @chatPageMenuExit.
  ///
  /// In en, this message translates to:
  /// **'Quit app'**
  String get chatPageMenuExit;

  /// No description provided for @chatPageMenuMore.
  ///
  /// In en, this message translates to:
  /// **'Menu'**
  String get chatPageMenuMore;

  /// No description provided for @chatPageRenameNameTitle.
  ///
  /// In en, this message translates to:
  /// **'My identity'**
  String get chatPageRenameNameTitle;

  /// No description provided for @chatPageRenameNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get chatPageRenameNameLabel;

  /// No description provided for @chatPageGenderLabel.
  ///
  /// In en, this message translates to:
  /// **'Gender'**
  String get chatPageGenderLabel;

  /// No description provided for @chatPageRenameEntranceTitle.
  ///
  /// In en, this message translates to:
  /// **'Current entrance'**
  String get chatPageRenameEntranceTitle;

  /// No description provided for @chatPageRenameEntranceHint.
  ///
  /// In en, this message translates to:
  /// **'Rename the current entrance, up to 32 characters'**
  String get chatPageRenameEntranceHint;

  /// No description provided for @chatPageRenameEntranceEmptyError.
  ///
  /// In en, this message translates to:
  /// **'Enter the entrance name'**
  String get chatPageRenameEntranceEmptyError;

  /// No description provided for @chatPageRenameEntranceInvalidError.
  ///
  /// In en, this message translates to:
  /// **'Only Chinese/English letters, digits, _ and - are allowed'**
  String get chatPageRenameEntranceInvalidError;

  /// No description provided for @chatPageRenameEntranceTooLongError.
  ///
  /// In en, this message translates to:
  /// **'At most {max} characters'**
  String chatPageRenameEntranceTooLongError(int max);

  /// No description provided for @chatPageRenameMyselfEmptyError.
  ///
  /// In en, this message translates to:
  /// **'Enter your name'**
  String get chatPageRenameMyselfEmptyError;

  /// No description provided for @chatPageRenameNameInvalidError.
  ///
  /// In en, this message translates to:
  /// **'Only Chinese/English letters, digits, _ , - and emoji are allowed'**
  String get chatPageRenameNameInvalidError;

  /// No description provided for @chatPageRenameNameTooLongError.
  ///
  /// In en, this message translates to:
  /// **'At most {max} characters'**
  String chatPageRenameNameTooLongError(int max);

  /// No description provided for @chatPageRenameSameAsPeerError.
  ///
  /// In en, this message translates to:
  /// **'Can\'t use the same name as someone else — pick another'**
  String get chatPageRenameSameAsPeerError;

  /// No description provided for @chatPageCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get chatPageCopy;

  /// No description provided for @chatPageEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get chatPageEdit;

  /// No description provided for @chatPageRenameFailed.
  ///
  /// In en, this message translates to:
  /// **'Rename failed: {error}'**
  String chatPageRenameFailed(String error);

  /// No description provided for @chatPageExitTitle.
  ///
  /// In en, this message translates to:
  /// **'Quit app?'**
  String get chatPageExitTitle;

  /// No description provided for @chatPageExitMessage.
  ///
  /// In en, this message translates to:
  /// **'Exits Einz on this device.'**
  String get chatPageExitMessage;

  /// No description provided for @chatPageEmailSubmit.
  ///
  /// In en, this message translates to:
  /// **'Submit'**
  String get chatPageEmailSubmit;

  /// No description provided for @chatPageRenamingSubmit.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get chatPageRenamingSubmit;

  /// No description provided for @chatPageChangePassphraseTitle.
  ///
  /// In en, this message translates to:
  /// **'Change passphrase'**
  String get chatPageChangePassphraseTitle;

  /// No description provided for @chatPageChangePassphraseSubmit.
  ///
  /// In en, this message translates to:
  /// **'Change'**
  String get chatPageChangePassphraseSubmit;

  /// No description provided for @chatPageChangePassphraseOldLabel.
  ///
  /// In en, this message translates to:
  /// **'Current passphrase'**
  String get chatPageChangePassphraseOldLabel;

  /// No description provided for @chatPageChangePassphraseNewLabel.
  ///
  /// In en, this message translates to:
  /// **'New passphrase'**
  String get chatPageChangePassphraseNewLabel;

  /// No description provided for @chatPageChangePassphraseConfirmLabel.
  ///
  /// In en, this message translates to:
  /// **'Confirm new passphrase'**
  String get chatPageChangePassphraseConfirmLabel;

  /// No description provided for @chatPagePassphraseRevealTip.
  ///
  /// In en, this message translates to:
  /// **'Show plain text (auto-hides after 3s)'**
  String get chatPagePassphraseRevealTip;

  /// No description provided for @chatPageChangePassphraseMismatch.
  ///
  /// In en, this message translates to:
  /// **'New passphrases do not match'**
  String get chatPageChangePassphraseMismatch;

  /// No description provided for @chatPageChangePassphraseSame.
  ///
  /// In en, this message translates to:
  /// **'New passphrase cannot be the same as the current one'**
  String get chatPageChangePassphraseSame;

  /// No description provided for @chatPageChangePassphraseOldRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter your current passphrase first'**
  String get chatPageChangePassphraseOldRequired;

  /// No description provided for @chatPageChangePassphraseOldWrong.
  ///
  /// In en, this message translates to:
  /// **'Wrong current passphrase'**
  String get chatPageChangePassphraseOldWrong;

  /// No description provided for @chatPageChangePassphraseDone.
  ///
  /// In en, this message translates to:
  /// **'✅ Shared passphrase updated — tell {mode, select, duo{your companion} other{your companions}}; new entrances must use the new one'**
  String chatPageChangePassphraseDone(String mode);

  /// No description provided for @chatPageChangePassphraseFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to change passphrase: {error}'**
  String chatPageChangePassphraseFailed(String error);

  /// No description provided for @chatPageEscrowRotatedNotice.
  ///
  /// In en, this message translates to:
  /// **'{mode, select, duo{Your companion} other{Your companions}} reset the shared passphrase — use the new one to create entrance tokens or change it'**
  String chatPageEscrowRotatedNotice(String mode);

  /// No description provided for @chatPageMenuLocaleLabel.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get chatPageMenuLocaleLabel;

  /// No description provided for @chatPageMenuAttachmentStorage.
  ///
  /// In en, this message translates to:
  /// **'Attachment storage'**
  String get chatPageMenuAttachmentStorage;

  /// No description provided for @chatPageAttachmentStorageSecured.
  ///
  /// In en, this message translates to:
  /// **'Remote only'**
  String get chatPageAttachmentStorageSecured;

  /// No description provided for @chatPageAttachmentStorageSecuredDesc.
  ///
  /// In en, this message translates to:
  /// **'Downloads and decrypts every time it is opened; no plaintext copy is kept on this device. More private.'**
  String get chatPageAttachmentStorageSecuredDesc;

  /// No description provided for @chatPageAttachmentStorageStored.
  ///
  /// In en, this message translates to:
  /// **'Keep locally'**
  String get chatPageAttachmentStorageStored;

  /// No description provided for @chatPageAttachmentStorageStoredDesc.
  ///
  /// In en, this message translates to:
  /// **'Keeps a plaintext copy after the first download, so you can open it directly on this device. More convenient.'**
  String get chatPageAttachmentStorageStoredDesc;

  /// No description provided for @chatPageAttachmentStorageSubmit.
  ///
  /// In en, this message translates to:
  /// **'Submit'**
  String get chatPageAttachmentStorageSubmit;

  /// No description provided for @chatPageAttachmentStorageWarnClear.
  ///
  /// In en, this message translates to:
  /// **'Switching to “Remote only” immediately deletes locally stored attachments'**
  String get chatPageAttachmentStorageWarnClear;

  /// No description provided for @chatPageMenuStyleLabel.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get chatPageMenuStyleLabel;

  /// No description provided for @chatPageUiStylePlain.
  ///
  /// In en, this message translates to:
  /// **'Plain'**
  String get chatPageUiStylePlain;

  /// No description provided for @chatPageUiStylePlainDesc.
  ///
  /// In en, this message translates to:
  /// **'Light pink solid background, clean and calm'**
  String get chatPageUiStylePlainDesc;

  /// No description provided for @chatPageUiStyleGradient.
  ///
  /// In en, this message translates to:
  /// **'Gradient'**
  String get chatPageUiStyleGradient;

  /// No description provided for @chatPageUiStyleGradientDesc.
  ///
  /// In en, this message translates to:
  /// **'Pink-blue gradient in the brand colors'**
  String get chatPageUiStyleGradientDesc;

  /// No description provided for @chatPageMenuBurnLabel.
  ///
  /// In en, this message translates to:
  /// **'Burn-after-read'**
  String get chatPageMenuBurnLabel;

  /// No description provided for @chatPageMenuMyNameLabel.
  ///
  /// In en, this message translates to:
  /// **'My identity'**
  String get chatPageMenuMyNameLabel;

  /// No description provided for @chatPageMenuEntranceList.
  ///
  /// In en, this message translates to:
  /// **'My entrances'**
  String get chatPageMenuEntranceList;

  /// No description provided for @wizardJoinInviteHint.
  ///
  /// In en, this message translates to:
  /// **'Invited by “{name}”'**
  String wizardJoinInviteHint(String name, int count);

  /// No description provided for @wizardJoinInviteHintNoName.
  ///
  /// In en, this message translates to:
  /// **'Invited to join a space'**
  String wizardJoinInviteHintNoName(int count);

  /// No description provided for @wizardJoinAttachHint.
  ///
  /// In en, this message translates to:
  /// **'Add a new entrance of “{name}”'**
  String wizardJoinAttachHint(String name);

  /// No description provided for @wizardJoinReinviteHint.
  ///
  /// In en, this message translates to:
  /// **'Invited by “{name}” to add a new entrance of “{target}”'**
  String wizardJoinReinviteHint(String name, String target);

  /// No description provided for @wizardJoinReinviteHintNoName.
  ///
  /// In en, this message translates to:
  /// **'Invited to add a new entrance of “{target}”'**
  String wizardJoinReinviteHintNoName(String target);

  /// No description provided for @chatPageMenuMembers.
  ///
  /// In en, this message translates to:
  /// **'{mode, select, duo{My companion} other{My companions}}'**
  String chatPageMenuMembers(String mode);

  /// No description provided for @chatPageMembersHint.
  ///
  /// In en, this message translates to:
  /// **'If a companion loses all entrances, tap Re-invite to generate a dedicated entrance token for them to rejoin this space.'**
  String get chatPageMembersHint;

  /// No description provided for @chatPageMembersTitle.
  ///
  /// In en, this message translates to:
  /// **'{mode, select, duo{My companion} other{My companions}}'**
  String chatPageMembersTitle(String mode);

  /// No description provided for @chatPageMembersUnnamed.
  ///
  /// In en, this message translates to:
  /// **'Unnamed'**
  String get chatPageMembersUnnamed;

  /// No description provided for @chatPageMembersInvite.
  ///
  /// In en, this message translates to:
  /// **'Invite'**
  String get chatPageMembersInvite;

  /// No description provided for @chatPageMembersReinvite.
  ///
  /// In en, this message translates to:
  /// **'Re-invite'**
  String get chatPageMembersReinvite;

  /// No description provided for @chatPageReinvitePassphraseTitle.
  ///
  /// In en, this message translates to:
  /// **'Verify passphrase'**
  String get chatPageReinvitePassphraseTitle;

  /// No description provided for @chatPageReinvitePassphraseHint.
  ///
  /// In en, this message translates to:
  /// **'After verification you can re-invite “{name}”'**
  String chatPageReinvitePassphraseHint(String name);

  /// No description provided for @chatPagePassphraseFieldHint.
  ///
  /// In en, this message translates to:
  /// **'Shared passphrase'**
  String get chatPagePassphraseFieldHint;

  /// No description provided for @chatPagePassphraseShow.
  ///
  /// In en, this message translates to:
  /// **'Show'**
  String get chatPagePassphraseShow;

  /// No description provided for @chatPagePassphraseHide.
  ///
  /// In en, this message translates to:
  /// **'Hide'**
  String get chatPagePassphraseHide;

  /// No description provided for @chatPageMembersInviteNew.
  ///
  /// In en, this message translates to:
  /// **'Invite new companion'**
  String get chatPageMembersInviteNew;

  /// No description provided for @chatPageMembersFullWithMax.
  ///
  /// In en, this message translates to:
  /// **'Space is full ({current}/{max})'**
  String chatPageMembersFullWithMax(int current, int max);

  /// No description provided for @chatPageEntranceListFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not load other entrances (offline?)'**
  String get chatPageEntranceListFailed;

  /// No description provided for @chatPageEntranceScopeHint.
  ///
  /// In en, this message translates to:
  /// **'An entrance connects a device to a space. Below are all your authorized entrances to this space.'**
  String get chatPageEntranceScopeHint;

  /// No description provided for @chatPageEntranceListThisDevice.
  ///
  /// In en, this message translates to:
  /// **'Current entrance name'**
  String get chatPageEntranceListThisDevice;

  /// No description provided for @chatPageEntranceListNew.
  ///
  /// In en, this message translates to:
  /// **'Add my new entrance'**
  String get chatPageEntranceListNew;

  /// No description provided for @chatPageEntranceListRefresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get chatPageEntranceListRefresh;

  /// No description provided for @chatPagePinLabel.
  ///
  /// In en, this message translates to:
  /// **'PIN'**
  String get chatPagePinLabel;

  /// No description provided for @chatPageLockNow.
  ///
  /// In en, this message translates to:
  /// **'Lock now'**
  String get chatPageLockNow;

  /// No description provided for @chatPagePinSetValue.
  ///
  /// In en, this message translates to:
  /// **'Set'**
  String get chatPagePinSetValue;

  /// No description provided for @chatPageNotifyLabel.
  ///
  /// In en, this message translates to:
  /// **'My email alerts'**
  String get chatPageNotifyLabel;

  /// No description provided for @chatPageNotifyTitle.
  ///
  /// In en, this message translates to:
  /// **'My email alerts'**
  String get chatPageNotifyTitle;

  /// No description provided for @chatPageNotifyHint.
  ///
  /// In en, this message translates to:
  /// **'If you have new messages and haven\'t been online for a while, we\'ll email you here. Alert emails never contain message text.'**
  String get chatPageNotifyHint;

  /// No description provided for @chatPageNotifyAllSpaces.
  ///
  /// In en, this message translates to:
  /// **'Apply this setting to all spaces on this device.'**
  String get chatPageNotifyAllSpaces;

  /// No description provided for @chatPageNotifyEmailLabel.
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get chatPageNotifyEmailLabel;

  /// No description provided for @chatPageNotifyEmptyError.
  ///
  /// In en, this message translates to:
  /// **'Enter an email address first'**
  String get chatPageNotifyEmptyError;

  /// No description provided for @chatPageNotifyInvalidError.
  ///
  /// In en, this message translates to:
  /// **'That doesn\'t look like an email address'**
  String get chatPageNotifyInvalidError;

  /// No description provided for @chatPageNotifyOnValue.
  ///
  /// In en, this message translates to:
  /// **'On'**
  String get chatPageNotifyOnValue;

  /// No description provided for @chatPageNotifyPendingValue.
  ///
  /// In en, this message translates to:
  /// **'Waiting confirm'**
  String get chatPageNotifyPendingValue;

  /// No description provided for @chatPageNotifyOffValue.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get chatPageNotifyOffValue;

  /// No description provided for @chatPageNotifyStatePending.
  ///
  /// In en, this message translates to:
  /// **'A confirmation email is on its way — alerts start once you open the link in it. Come back to the app and this updates on its own.'**
  String get chatPageNotifyStatePending;

  /// No description provided for @chatPageNotifySent.
  ///
  /// In en, this message translates to:
  /// **'Confirmation sent to {email}. Open the link in it to turn alerts on.'**
  String chatPageNotifySent(String email);

  /// No description provided for @chatPageNotifyDone.
  ///
  /// In en, this message translates to:
  /// **'On. We\'ll email {email} when you have new messages and haven\'t been online for a while.'**
  String chatPageNotifyDone(String email);

  /// No description provided for @chatPageNotifyRemoved.
  ///
  /// In en, this message translates to:
  /// **'Email alerts turned off.'**
  String get chatPageNotifyRemoved;

  /// No description provided for @chatPageNotifyStop.
  ///
  /// In en, this message translates to:
  /// **'Turn off'**
  String get chatPageNotifyStop;

  /// No description provided for @chatPageNotifyFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not save: {error}'**
  String chatPageNotifyFailed(String error);

  /// No description provided for @chatPageBurnHeading.
  ///
  /// In en, this message translates to:
  /// **'Burn-after-read'**
  String get chatPageBurnHeading;

  /// No description provided for @chatPageBurnNote.
  ///
  /// In en, this message translates to:
  /// **'New messages are deleted on a countdown once read'**
  String get chatPageBurnNote;

  /// No description provided for @chatPageBurnOff.
  ///
  /// In en, this message translates to:
  /// **'Burn-after-read is off (this message will be kept)'**
  String get chatPageBurnOff;

  /// No description provided for @chatPageBurnFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to set burn-after-read'**
  String get chatPageBurnFailed;

  /// No description provided for @chatPageBurnWillDelete.
  ///
  /// In en, this message translates to:
  /// **'New messages auto-delete after {duration}'**
  String chatPageBurnWillDelete(String duration);

  /// No description provided for @chatPageActionDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete now'**
  String get chatPageActionDelete;

  /// No description provided for @chatPageActionQuote.
  ///
  /// In en, this message translates to:
  /// **'Quote'**
  String get chatPageActionQuote;

  /// No description provided for @chatPageActionSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get chatPageActionSave;

  /// No description provided for @chatPageAttachmentSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved.'**
  String get chatPageAttachmentSaved;

  /// No description provided for @chatPageFileSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Save failed: {error}'**
  String chatPageFileSaveFailed(Object error);

  /// No description provided for @chatPageActionBurn.
  ///
  /// In en, this message translates to:
  /// **'Burn after reading'**
  String get chatPageActionBurn;

  /// No description provided for @chatPageDeleteConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete message'**
  String get chatPageDeleteConfirmTitle;

  /// No description provided for @chatPageDeleteConfirmMessage.
  ///
  /// In en, this message translates to:
  /// **'Removed only on this device; the others aren\'t affected, and it can\'t be undone. Delete?'**
  String get chatPageDeleteConfirmMessage;

  /// No description provided for @chatPageDeleteCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get chatPageDeleteCancel;

  /// No description provided for @chatPageDeleteConfirmOk.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get chatPageDeleteConfirmOk;

  /// No description provided for @chatPageSendFailed.
  ///
  /// In en, this message translates to:
  /// **'Send failed: {error}'**
  String chatPageSendFailed(String error);

  /// No description provided for @chatPageMsgSent.
  ///
  /// In en, this message translates to:
  /// **'Sent'**
  String get chatPageMsgSent;

  /// No description provided for @chatPageMsgSendingTap.
  ///
  /// In en, this message translates to:
  /// **'Sending… tap to verify and resend'**
  String get chatPageMsgSendingTap;

  /// No description provided for @chatPageMsgDelivered.
  ///
  /// In en, this message translates to:
  /// **'Delivered'**
  String get chatPageMsgDelivered;

  /// No description provided for @chatPageMsgFailed.
  ///
  /// In en, this message translates to:
  /// **'Send failed, tap to retry'**
  String get chatPageMsgFailed;

  /// No description provided for @chatPageMsgFailedTap.
  ///
  /// In en, this message translates to:
  /// **'Tap to resend'**
  String get chatPageMsgFailedTap;

  /// No description provided for @chatPageOfflineUnsent.
  ///
  /// In en, this message translates to:
  /// **'Offline · {count} unsent'**
  String chatPageOfflineUnsent(int count);

  /// No description provided for @chatPageEntranceUnrecognized.
  ///
  /// In en, this message translates to:
  /// **'This entrance is not recognized by the server (its data may have been reset) · local messages only, no sync; your local data is NOT cleared'**
  String get chatPageEntranceUnrecognized;

  /// No description provided for @chatPageOfflineLocalOnly.
  ///
  /// In en, this message translates to:
  /// **'Offline · local messages only, cannot send or receive'**
  String get chatPageOfflineLocalOnly;

  /// No description provided for @chatPageMsgResending.
  ///
  /// In en, this message translates to:
  /// **'Resending…'**
  String get chatPageMsgResending;

  /// No description provided for @chatPageMsgSpeedingUp.
  ///
  /// In en, this message translates to:
  /// **'Speeding up…'**
  String get chatPageMsgSpeedingUp;

  /// No description provided for @chatPageVoiceStartFailed.
  ///
  /// In en, this message translates to:
  /// **'Recording start failed: {error}'**
  String chatPageVoiceStartFailed(String error);

  /// No description provided for @chatPageVoiceFailed.
  ///
  /// In en, this message translates to:
  /// **'Recording failed: {error}'**
  String chatPageVoiceFailed(String error);

  /// No description provided for @chatPageVoicePermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Microphone permission denied. Please enable it in system settings.'**
  String get chatPageVoicePermissionDenied;

  /// No description provided for @chatPageVoiceEmpty.
  ///
  /// In en, this message translates to:
  /// **'Recording was empty and was discarded.'**
  String get chatPageVoiceEmpty;

  /// No description provided for @chatPageLongPressToRecord.
  ///
  /// In en, this message translates to:
  /// **'Long press to record'**
  String get chatPageLongPressToRecord;

  /// No description provided for @chatPageInputHint.
  ///
  /// In en, this message translates to:
  /// **'Type a message…'**
  String get chatPageInputHint;

  /// No description provided for @chatPageAudioMetaMissing.
  ///
  /// In en, this message translates to:
  /// **'Audio metadata missing'**
  String get chatPageAudioMetaMissing;

  /// No description provided for @chatPageAudioPlayFailed.
  ///
  /// In en, this message translates to:
  /// **'Audio playback failed: {error}'**
  String chatPageAudioPlayFailed(String error);

  /// No description provided for @chatPageAttachEmoji.
  ///
  /// In en, this message translates to:
  /// **'Emoji'**
  String get chatPageAttachEmoji;

  /// No description provided for @chatPageEmojiKeyboard.
  ///
  /// In en, this message translates to:
  /// **'Keyboard'**
  String get chatPageEmojiKeyboard;

  /// No description provided for @chatPageAttachPhoto.
  ///
  /// In en, this message translates to:
  /// **'Take photo'**
  String get chatPageAttachPhoto;

  /// No description provided for @chatPageAttachGalleryImage.
  ///
  /// In en, this message translates to:
  /// **'Gallery image'**
  String get chatPageAttachGalleryImage;

  /// No description provided for @chatPageAttachVideoCamera.
  ///
  /// In en, this message translates to:
  /// **'Record video'**
  String get chatPageAttachVideoCamera;

  /// No description provided for @chatPageAttachVideoGallery.
  ///
  /// In en, this message translates to:
  /// **'Gallery video'**
  String get chatPageAttachVideoGallery;

  /// No description provided for @chatPageAttachAudioFile.
  ///
  /// In en, this message translates to:
  /// **'Audio file'**
  String get chatPageAttachAudioFile;

  /// No description provided for @chatPageAttachAnyFile.
  ///
  /// In en, this message translates to:
  /// **'Any file'**
  String get chatPageAttachAnyFile;

  /// No description provided for @chatPagePlaying.
  ///
  /// In en, this message translates to:
  /// **'Playing…'**
  String get chatPagePlaying;

  /// No description provided for @chatPageVoiceLabel.
  ///
  /// In en, this message translates to:
  /// **'Voice'**
  String get chatPageVoiceLabel;

  /// No description provided for @chatPageAttachmentMetaMissing.
  ///
  /// In en, this message translates to:
  /// **'Attachment metadata missing'**
  String get chatPageAttachmentMetaMissing;

  /// No description provided for @chatPageSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved: {path}'**
  String chatPageSaved(String path);

  /// No description provided for @chatPageDownloadFailed.
  ///
  /// In en, this message translates to:
  /// **'Download failed: {error}'**
  String chatPageDownloadFailed(String error);

  /// No description provided for @chatPageAttachmentTapToDownload.
  ///
  /// In en, this message translates to:
  /// **'Not on this device — tap to download again'**
  String get chatPageAttachmentTapToDownload;

  /// No description provided for @chatPageVideoLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Video failed to load — tap to retry'**
  String get chatPageVideoLoadFailed;

  /// No description provided for @chatPageFileOpenFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not open file: {error}'**
  String chatPageFileOpenFailed(String error);

  /// No description provided for @chatPageEntranceRevoked.
  ///
  /// In en, this message translates to:
  /// **'Entrance revoked — local data cleared, please set up again'**
  String get chatPageEntranceRevoked;

  /// No description provided for @burnOptionOff.
  ///
  /// In en, this message translates to:
  /// **'Off (Do not burn anymore)'**
  String get burnOptionOff;

  /// No description provided for @burnOption1Minute.
  ///
  /// In en, this message translates to:
  /// **'1 minute'**
  String get burnOption1Minute;

  /// No description provided for @burnOption5Minutes.
  ///
  /// In en, this message translates to:
  /// **'5 minutes'**
  String get burnOption5Minutes;

  /// No description provided for @burnOption1Hour.
  ///
  /// In en, this message translates to:
  /// **'1 hour'**
  String get burnOption1Hour;

  /// No description provided for @burnOption1Day.
  ///
  /// In en, this message translates to:
  /// **'1 day'**
  String get burnOption1Day;

  /// No description provided for @burnOption7Days.
  ///
  /// In en, this message translates to:
  /// **'7 days'**
  String get burnOption7Days;

  /// No description provided for @lockPageTitle.
  ///
  /// In en, this message translates to:
  /// **'My Einz'**
  String get lockPageTitle;

  /// No description provided for @lockPagePinPrompt.
  ///
  /// In en, this message translates to:
  /// **'Enter PIN to unlock'**
  String get lockPagePinPrompt;

  /// No description provided for @lockPageLockedSeconds.
  ///
  /// In en, this message translates to:
  /// **'Locked for {seconds}s'**
  String lockPageLockedSeconds(int seconds);

  /// No description provided for @lockPageNoPinSet.
  ///
  /// In en, this message translates to:
  /// **'No PIN set (lock screen activates only with a PIN)'**
  String get lockPageNoPinSet;

  /// No description provided for @lockPageUnlock.
  ///
  /// In en, this message translates to:
  /// **'Unlock'**
  String get lockPageUnlock;

  /// No description provided for @lockPageTooManyAttempts.
  ///
  /// In en, this message translates to:
  /// **'Too many attempts, try again in {seconds}s'**
  String lockPageTooManyAttempts(int seconds);

  /// No description provided for @lockPageUnlockFailed.
  ///
  /// In en, this message translates to:
  /// **'Unlock failed: {error}'**
  String lockPageUnlockFailed(String error);

  /// No description provided for @chatPageMenuAbout.
  ///
  /// In en, this message translates to:
  /// **'About Einz'**
  String get chatPageMenuAbout;

  /// No description provided for @aboutPageTitle.
  ///
  /// In en, this message translates to:
  /// **'About Einz'**
  String get aboutPageTitle;

  /// No description provided for @aboutIntro.
  ///
  /// In en, this message translates to:
  /// **'Einz is an end-to-end encrypted space for private chatting and sharing, and no third party — including Einz itself — can read them, strictly safeguarding your privacy.'**
  String get aboutIntro;

  /// No description provided for @aboutVersionLabel.
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get aboutVersionLabel;

  /// No description provided for @aboutServerLabel.
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get aboutServerLabel;

  /// No description provided for @aboutServerDevNote.
  ///
  /// In en, this message translates to:
  /// **'Development address for debugging only'**
  String get aboutServerDevNote;

  /// No description provided for @advancedMenuTitle.
  ///
  /// In en, this message translates to:
  /// **'Advanced security'**
  String get advancedMenuTitle;

  /// No description provided for @advancedDestroyEntrance.
  ///
  /// In en, this message translates to:
  /// **'Destroy this entrance'**
  String get advancedDestroyEntrance;

  /// No description provided for @advancedClearMessages.
  ///
  /// In en, this message translates to:
  /// **'Delete all messages'**
  String get advancedClearMessages;

  /// No description provided for @clearMessagesMessage.
  ///
  /// In en, this message translates to:
  /// **'Deletes all messages and attachments saved in the current entrance. The entrance stays usable and will keep receiving new messages. Other entrances are unaffected.'**
  String get clearMessagesMessage;

  /// No description provided for @clearMessagesConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get clearMessagesConfirm;

  /// No description provided for @clearMessagesDone.
  ///
  /// In en, this message translates to:
  /// **'All messages deleted.'**
  String get clearMessagesDone;

  /// No description provided for @clearMessagesFailed.
  ///
  /// In en, this message translates to:
  /// **'Delete failed: {error}'**
  String clearMessagesFailed(String error);

  /// No description provided for @leaveSpaceTitle.
  ///
  /// In en, this message translates to:
  /// **'Destroy this entrance?'**
  String get leaveSpaceTitle;

  /// No description provided for @leaveSpaceMessage.
  ///
  /// In en, this message translates to:
  /// **'Permanently erases all messages, attachments and credentials of the current entrance, then takes you back to the setup wizard. The space itself and its data are kept; other entrances are unaffected. This cannot be undone!'**
  String get leaveSpaceMessage;

  /// No description provided for @resetEntranceNameLabel.
  ///
  /// In en, this message translates to:
  /// **'{name}'**
  String resetEntranceNameLabel(String name);

  /// No description provided for @resetEntranceNameHint.
  ///
  /// In en, this message translates to:
  /// **'Type the current entrance name “{name}”'**
  String resetEntranceNameHint(String name);

  /// No description provided for @resetEntranceNameMismatch.
  ///
  /// In en, this message translates to:
  /// **'Enter the correct entrance name to confirm'**
  String get resetEntranceNameMismatch;

  /// No description provided for @resetEntranceConfirmWord.
  ///
  /// In en, this message translates to:
  /// **'RESET'**
  String get resetEntranceConfirmWord;

  /// No description provided for @resetEntrancePinLabel.
  ///
  /// In en, this message translates to:
  /// **'PIN'**
  String get resetEntrancePinLabel;

  /// No description provided for @resetEntrancePinHint.
  ///
  /// In en, this message translates to:
  /// **'Enter this device\'s PIN'**
  String get resetEntrancePinHint;

  /// No description provided for @resetEntranceServerResidualHint.
  ///
  /// In en, this message translates to:
  /// **'⚠️ Local data erased, but retiring it on the server failed; the others may still see this entrance'**
  String get resetEntranceServerResidualHint;

  /// No description provided for @spaceListHint.
  ///
  /// In en, this message translates to:
  /// **'Tap another space to switch to it'**
  String get spaceListHint;

  /// No description provided for @spaceListTitle.
  ///
  /// In en, this message translates to:
  /// **'My Einz spaces'**
  String get spaceListTitle;

  /// No description provided for @spaceListEmpty.
  ///
  /// In en, this message translates to:
  /// **'No spaces joined yet'**
  String get spaceListEmpty;

  /// No description provided for @spaceListAdd.
  ///
  /// In en, this message translates to:
  /// **'Add a space'**
  String get spaceListAdd;

  /// No description provided for @spaceListSwitch.
  ///
  /// In en, this message translates to:
  /// **'My Einz spaces'**
  String get spaceListSwitch;

  /// No description provided for @promptLockCodeTitle.
  ///
  /// In en, this message translates to:
  /// **'Enter your PIN'**
  String get promptLockCodeTitle;

  /// No description provided for @promptLockCodeHint.
  ///
  /// In en, this message translates to:
  /// **'Verify this device\'s lock screen code first'**
  String get promptLockCodeHint;

  /// No description provided for @leaveSpaceConfirm.
  ///
  /// In en, this message translates to:
  /// **'Destroy'**
  String get leaveSpaceConfirm;

  /// No description provided for @setupPinReuseNotice.
  ///
  /// In en, this message translates to:
  /// **'This space will share the current PIN.'**
  String get setupPinReuseNotice;

  /// Prefix for errors reported by the server; errors decided on this device carry no prefix
  ///
  /// In en, this message translates to:
  /// **'Server: {message}'**
  String errorBackend(String message);

  /// Status word when a member has not joined yet (shared by the space card, space list, and members sheet)
  ///
  /// In en, this message translates to:
  /// **'Waiting'**
  String get memberPending;

  /// Group space top bar, right of the member avatars: how many others are online / how many others there are. BOTH numbers exclude me.
  ///
  /// In en, this message translates to:
  /// **'{online}/{total}'**
  String chatPageStatusOthersOnline(int online, int total);

  /// Tooltip of the voice call button in the chat page top bar / 聊天页顶部栏语音通话按钮的 tooltip
  ///
  /// In en, this message translates to:
  /// **'Voice call'**
  String get voiceCallMenuCall;

  /// Voice call UI / 语音通话界面文案
  ///
  /// In en, this message translates to:
  /// **'Incoming call'**
  String get voiceCallIncoming;

  /// Voice call UI / 语音通话界面文案
  ///
  /// In en, this message translates to:
  /// **'Calling…'**
  String get voiceCallCalling;

  /// Voice call UI / 语音通话界面文案
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get voiceCallConnecting;

  /// Voice call UI / 语音通话界面文案
  ///
  /// In en, this message translates to:
  /// **'Accept'**
  String get voiceCallAccept;

  /// Voice call UI / 语音通话界面文案
  ///
  /// In en, this message translates to:
  /// **'Decline'**
  String get voiceCallDecline;

  /// Voice call UI / 语音通话界面文案
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get voiceCallCancel;

  /// Voice call UI / 语音通话界面文案
  ///
  /// In en, this message translates to:
  /// **'Hang up'**
  String get voiceCallHangUp;

  /// Voice call UI / 语音通话界面文案
  ///
  /// In en, this message translates to:
  /// **'Mute'**
  String get voiceCallMute;

  /// Voice call UI / 语音通话界面文案
  ///
  /// In en, this message translates to:
  /// **'Unmute'**
  String get voiceCallUnmute;

  /// Voice call UI / 语音通话界面文案
  ///
  /// In en, this message translates to:
  /// **'Speaker'**
  String get voiceCallSpeaker;

  /// Voice call UI / 语音通话界面文案
  ///
  /// In en, this message translates to:
  /// **'Speaker off'**
  String get voiceCallSpeakerOff;

  /// Voice call UI / 语音通话界面文案
  ///
  /// In en, this message translates to:
  /// **'Call ended'**
  String get voiceCallEnded;

  /// Voice call UI / 语音通话界面文案
  ///
  /// In en, this message translates to:
  /// **'Call declined'**
  String get voiceCallEndedDeclined;

  /// Voice call UI / 语音通话界面文案
  ///
  /// In en, this message translates to:
  /// **'Busy'**
  String get voiceCallEndedBusy;

  /// Voice call UI / 语音通话界面文案
  ///
  /// In en, this message translates to:
  /// **'No answer'**
  String get voiceCallEndedNoAnswer;

  /// Voice call UI / 语音通话界面文案
  ///
  /// In en, this message translates to:
  /// **'Call canceled'**
  String get voiceCallEndedCanceled;

  /// Voice call UI / 语音通话界面文案
  ///
  /// In en, this message translates to:
  /// **'Call failed'**
  String get voiceCallEndedFailed;

  /// Hint under the ringing UI: no background incoming calls, so both sides must be in foreground / 振铃界面下方提示：不做后台呼入，双方都要在前台
  ///
  /// In en, this message translates to:
  /// **'Calls connect only while both sides have Einz open'**
  String get voiceCallForegroundOnly;

  /// Call record line in the chat flow, with mm:ss duration / 聊天流里的通话记录行，带 mm:ss 时长
  ///
  /// In en, this message translates to:
  /// **'Call duration {duration}'**
  String voiceCallRecordDuration(String duration);

  /// Button on the fullscreen avatar: opens the picker (an empty avatar goes straight here)
  ///
  /// In en, this message translates to:
  /// **'Change avatar'**
  String get chatPageAvatarChange;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
