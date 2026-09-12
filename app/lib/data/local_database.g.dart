// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'local_database.dart';

// ignore_for_file: type=lint
class $LocalMessagesTable extends LocalMessages
    with TableInfo<$LocalMessagesTable, LocalMessage> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalMessagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _messageIdMeta = const VerificationMeta(
    'messageId',
  );
  @override
  late final GeneratedColumn<String> messageId = GeneratedColumn<String>(
    'message_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _spaceIdMeta = const VerificationMeta(
    'spaceId',
  );
  @override
  late final GeneratedColumn<String> spaceId = GeneratedColumn<String>(
    'space_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _senderDeviceIdMeta = const VerificationMeta(
    'senderDeviceId',
  );
  @override
  late final GeneratedColumn<String> senderDeviceId = GeneratedColumn<String>(
    'sender_device_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _keyVersionMeta = const VerificationMeta(
    'keyVersion',
  );
  @override
  late final GeneratedColumn<int> keyVersion = GeneratedColumn<int>(
    'key_version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nonceMeta = const VerificationMeta('nonce');
  @override
  late final GeneratedColumn<String> nonce = GeneratedColumn<String>(
    'nonce',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _ciphertextMeta = const VerificationMeta(
    'ciphertext',
  );
  @override
  late final GeneratedColumn<String> ciphertext = GeneratedColumn<String>(
    'ciphertext',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverSequenceMeta = const VerificationMeta(
    'serverSequence',
  );
  @override
  late final GeneratedColumn<int> serverSequence = GeneratedColumn<int>(
    'server_sequence',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('pending'),
  );
  static const VerificationMeta _localCreatedAtMeta = const VerificationMeta(
    'localCreatedAt',
  );
  @override
  late final GeneratedColumn<int> localCreatedAt = GeneratedColumn<int>(
    'local_created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _burnAfterSecondsMeta = const VerificationMeta(
    'burnAfterSeconds',
  );
  @override
  late final GeneratedColumn<int> burnAfterSeconds = GeneratedColumn<int>(
    'burn_after_seconds',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _expiresAtMeta = const VerificationMeta(
    'expiresAt',
  );
  @override
  late final GeneratedColumn<int> expiresAt = GeneratedColumn<int>(
    'expires_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _burnManualMeta = const VerificationMeta(
    'burnManual',
  );
  @override
  late final GeneratedColumn<bool> burnManual = GeneratedColumn<bool>(
    'burn_manual',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("burn_manual" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<int> deletedAt = GeneratedColumn<int>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    messageId,
    spaceId,
    senderDeviceId,
    type,
    keyVersion,
    nonce,
    ciphertext,
    serverSequence,
    createdAt,
    status,
    localCreatedAt,
    burnAfterSeconds,
    expiresAt,
    burnManual,
    deletedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_messages';
  @override
  VerificationContext validateIntegrity(
    Insertable<LocalMessage> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('message_id')) {
      context.handle(
        _messageIdMeta,
        messageId.isAcceptableOrUnknown(data['message_id']!, _messageIdMeta),
      );
    } else if (isInserting) {
      context.missing(_messageIdMeta);
    }
    if (data.containsKey('space_id')) {
      context.handle(
        _spaceIdMeta,
        spaceId.isAcceptableOrUnknown(data['space_id']!, _spaceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_spaceIdMeta);
    }
    if (data.containsKey('sender_device_id')) {
      context.handle(
        _senderDeviceIdMeta,
        senderDeviceId.isAcceptableOrUnknown(
          data['sender_device_id']!,
          _senderDeviceIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_senderDeviceIdMeta);
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    } else if (isInserting) {
      context.missing(_typeMeta);
    }
    if (data.containsKey('key_version')) {
      context.handle(
        _keyVersionMeta,
        keyVersion.isAcceptableOrUnknown(data['key_version']!, _keyVersionMeta),
      );
    } else if (isInserting) {
      context.missing(_keyVersionMeta);
    }
    if (data.containsKey('nonce')) {
      context.handle(
        _nonceMeta,
        nonce.isAcceptableOrUnknown(data['nonce']!, _nonceMeta),
      );
    } else if (isInserting) {
      context.missing(_nonceMeta);
    }
    if (data.containsKey('ciphertext')) {
      context.handle(
        _ciphertextMeta,
        ciphertext.isAcceptableOrUnknown(data['ciphertext']!, _ciphertextMeta),
      );
    } else if (isInserting) {
      context.missing(_ciphertextMeta);
    }
    if (data.containsKey('server_sequence')) {
      context.handle(
        _serverSequenceMeta,
        serverSequence.isAcceptableOrUnknown(
          data['server_sequence']!,
          _serverSequenceMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('local_created_at')) {
      context.handle(
        _localCreatedAtMeta,
        localCreatedAt.isAcceptableOrUnknown(
          data['local_created_at']!,
          _localCreatedAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_localCreatedAtMeta);
    }
    if (data.containsKey('burn_after_seconds')) {
      context.handle(
        _burnAfterSecondsMeta,
        burnAfterSeconds.isAcceptableOrUnknown(
          data['burn_after_seconds']!,
          _burnAfterSecondsMeta,
        ),
      );
    }
    if (data.containsKey('expires_at')) {
      context.handle(
        _expiresAtMeta,
        expiresAt.isAcceptableOrUnknown(data['expires_at']!, _expiresAtMeta),
      );
    }
    if (data.containsKey('burn_manual')) {
      context.handle(
        _burnManualMeta,
        burnManual.isAcceptableOrUnknown(data['burn_manual']!, _burnManualMeta),
      );
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {messageId};
  @override
  LocalMessage map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalMessage(
      messageId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}message_id'],
      )!,
      spaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}space_id'],
      )!,
      senderDeviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sender_device_id'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}type'],
      )!,
      keyVersion: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}key_version'],
      )!,
      nonce: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}nonce'],
      )!,
      ciphertext: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}ciphertext'],
      )!,
      serverSequence: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}server_sequence'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      localCreatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}local_created_at'],
      )!,
      burnAfterSeconds: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}burn_after_seconds'],
      )!,
      expiresAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}expires_at'],
      ),
      burnManual: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}burn_manual'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}deleted_at'],
      ),
    );
  }

  @override
  $LocalMessagesTable createAlias(String alias) {
    return $LocalMessagesTable(attachedDatabase, alias);
  }
}

class LocalMessage extends DataClass implements Insertable<LocalMessage> {
  final String messageId;
  final String spaceId;
  final String senderDeviceId;
  final String type;
  final int keyVersion;
  final String nonce;
  final String ciphertext;
  final int? serverSequence;
  final int createdAt;
  final String status;
  final int localCreatedAt;
  final int burnAfterSeconds;
  final int? expiresAt;
  final bool burnManual;
  final int? deletedAt;
  const LocalMessage({
    required this.messageId,
    required this.spaceId,
    required this.senderDeviceId,
    required this.type,
    required this.keyVersion,
    required this.nonce,
    required this.ciphertext,
    this.serverSequence,
    required this.createdAt,
    required this.status,
    required this.localCreatedAt,
    required this.burnAfterSeconds,
    this.expiresAt,
    required this.burnManual,
    this.deletedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['message_id'] = Variable<String>(messageId);
    map['space_id'] = Variable<String>(spaceId);
    map['sender_device_id'] = Variable<String>(senderDeviceId);
    map['type'] = Variable<String>(type);
    map['key_version'] = Variable<int>(keyVersion);
    map['nonce'] = Variable<String>(nonce);
    map['ciphertext'] = Variable<String>(ciphertext);
    if (!nullToAbsent || serverSequence != null) {
      map['server_sequence'] = Variable<int>(serverSequence);
    }
    map['created_at'] = Variable<int>(createdAt);
    map['status'] = Variable<String>(status);
    map['local_created_at'] = Variable<int>(localCreatedAt);
    map['burn_after_seconds'] = Variable<int>(burnAfterSeconds);
    if (!nullToAbsent || expiresAt != null) {
      map['expires_at'] = Variable<int>(expiresAt);
    }
    map['burn_manual'] = Variable<bool>(burnManual);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<int>(deletedAt);
    }
    return map;
  }

  LocalMessagesCompanion toCompanion(bool nullToAbsent) {
    return LocalMessagesCompanion(
      messageId: Value(messageId),
      spaceId: Value(spaceId),
      senderDeviceId: Value(senderDeviceId),
      type: Value(type),
      keyVersion: Value(keyVersion),
      nonce: Value(nonce),
      ciphertext: Value(ciphertext),
      serverSequence: serverSequence == null && nullToAbsent
          ? const Value.absent()
          : Value(serverSequence),
      createdAt: Value(createdAt),
      status: Value(status),
      localCreatedAt: Value(localCreatedAt),
      burnAfterSeconds: Value(burnAfterSeconds),
      expiresAt: expiresAt == null && nullToAbsent
          ? const Value.absent()
          : Value(expiresAt),
      burnManual: Value(burnManual),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
    );
  }

  factory LocalMessage.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalMessage(
      messageId: serializer.fromJson<String>(json['messageId']),
      spaceId: serializer.fromJson<String>(json['spaceId']),
      senderDeviceId: serializer.fromJson<String>(json['senderDeviceId']),
      type: serializer.fromJson<String>(json['type']),
      keyVersion: serializer.fromJson<int>(json['keyVersion']),
      nonce: serializer.fromJson<String>(json['nonce']),
      ciphertext: serializer.fromJson<String>(json['ciphertext']),
      serverSequence: serializer.fromJson<int?>(json['serverSequence']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      status: serializer.fromJson<String>(json['status']),
      localCreatedAt: serializer.fromJson<int>(json['localCreatedAt']),
      burnAfterSeconds: serializer.fromJson<int>(json['burnAfterSeconds']),
      expiresAt: serializer.fromJson<int?>(json['expiresAt']),
      burnManual: serializer.fromJson<bool>(json['burnManual']),
      deletedAt: serializer.fromJson<int?>(json['deletedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'messageId': serializer.toJson<String>(messageId),
      'spaceId': serializer.toJson<String>(spaceId),
      'senderDeviceId': serializer.toJson<String>(senderDeviceId),
      'type': serializer.toJson<String>(type),
      'keyVersion': serializer.toJson<int>(keyVersion),
      'nonce': serializer.toJson<String>(nonce),
      'ciphertext': serializer.toJson<String>(ciphertext),
      'serverSequence': serializer.toJson<int?>(serverSequence),
      'createdAt': serializer.toJson<int>(createdAt),
      'status': serializer.toJson<String>(status),
      'localCreatedAt': serializer.toJson<int>(localCreatedAt),
      'burnAfterSeconds': serializer.toJson<int>(burnAfterSeconds),
      'expiresAt': serializer.toJson<int?>(expiresAt),
      'burnManual': serializer.toJson<bool>(burnManual),
      'deletedAt': serializer.toJson<int?>(deletedAt),
    };
  }

  LocalMessage copyWith({
    String? messageId,
    String? spaceId,
    String? senderDeviceId,
    String? type,
    int? keyVersion,
    String? nonce,
    String? ciphertext,
    Value<int?> serverSequence = const Value.absent(),
    int? createdAt,
    String? status,
    int? localCreatedAt,
    int? burnAfterSeconds,
    Value<int?> expiresAt = const Value.absent(),
    bool? burnManual,
    Value<int?> deletedAt = const Value.absent(),
  }) => LocalMessage(
    messageId: messageId ?? this.messageId,
    spaceId: spaceId ?? this.spaceId,
    senderDeviceId: senderDeviceId ?? this.senderDeviceId,
    type: type ?? this.type,
    keyVersion: keyVersion ?? this.keyVersion,
    nonce: nonce ?? this.nonce,
    ciphertext: ciphertext ?? this.ciphertext,
    serverSequence: serverSequence.present
        ? serverSequence.value
        : this.serverSequence,
    createdAt: createdAt ?? this.createdAt,
    status: status ?? this.status,
    localCreatedAt: localCreatedAt ?? this.localCreatedAt,
    burnAfterSeconds: burnAfterSeconds ?? this.burnAfterSeconds,
    expiresAt: expiresAt.present ? expiresAt.value : this.expiresAt,
    burnManual: burnManual ?? this.burnManual,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
  );
  LocalMessage copyWithCompanion(LocalMessagesCompanion data) {
    return LocalMessage(
      messageId: data.messageId.present ? data.messageId.value : this.messageId,
      spaceId: data.spaceId.present ? data.spaceId.value : this.spaceId,
      senderDeviceId: data.senderDeviceId.present
          ? data.senderDeviceId.value
          : this.senderDeviceId,
      type: data.type.present ? data.type.value : this.type,
      keyVersion: data.keyVersion.present
          ? data.keyVersion.value
          : this.keyVersion,
      nonce: data.nonce.present ? data.nonce.value : this.nonce,
      ciphertext: data.ciphertext.present
          ? data.ciphertext.value
          : this.ciphertext,
      serverSequence: data.serverSequence.present
          ? data.serverSequence.value
          : this.serverSequence,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      status: data.status.present ? data.status.value : this.status,
      localCreatedAt: data.localCreatedAt.present
          ? data.localCreatedAt.value
          : this.localCreatedAt,
      burnAfterSeconds: data.burnAfterSeconds.present
          ? data.burnAfterSeconds.value
          : this.burnAfterSeconds,
      expiresAt: data.expiresAt.present ? data.expiresAt.value : this.expiresAt,
      burnManual: data.burnManual.present
          ? data.burnManual.value
          : this.burnManual,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalMessage(')
          ..write('messageId: $messageId, ')
          ..write('spaceId: $spaceId, ')
          ..write('senderDeviceId: $senderDeviceId, ')
          ..write('type: $type, ')
          ..write('keyVersion: $keyVersion, ')
          ..write('nonce: $nonce, ')
          ..write('ciphertext: $ciphertext, ')
          ..write('serverSequence: $serverSequence, ')
          ..write('createdAt: $createdAt, ')
          ..write('status: $status, ')
          ..write('localCreatedAt: $localCreatedAt, ')
          ..write('burnAfterSeconds: $burnAfterSeconds, ')
          ..write('expiresAt: $expiresAt, ')
          ..write('burnManual: $burnManual, ')
          ..write('deletedAt: $deletedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    messageId,
    spaceId,
    senderDeviceId,
    type,
    keyVersion,
    nonce,
    ciphertext,
    serverSequence,
    createdAt,
    status,
    localCreatedAt,
    burnAfterSeconds,
    expiresAt,
    burnManual,
    deletedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalMessage &&
          other.messageId == this.messageId &&
          other.spaceId == this.spaceId &&
          other.senderDeviceId == this.senderDeviceId &&
          other.type == this.type &&
          other.keyVersion == this.keyVersion &&
          other.nonce == this.nonce &&
          other.ciphertext == this.ciphertext &&
          other.serverSequence == this.serverSequence &&
          other.createdAt == this.createdAt &&
          other.status == this.status &&
          other.localCreatedAt == this.localCreatedAt &&
          other.burnAfterSeconds == this.burnAfterSeconds &&
          other.expiresAt == this.expiresAt &&
          other.burnManual == this.burnManual &&
          other.deletedAt == this.deletedAt);
}

class LocalMessagesCompanion extends UpdateCompanion<LocalMessage> {
  final Value<String> messageId;
  final Value<String> spaceId;
  final Value<String> senderDeviceId;
  final Value<String> type;
  final Value<int> keyVersion;
  final Value<String> nonce;
  final Value<String> ciphertext;
  final Value<int?> serverSequence;
  final Value<int> createdAt;
  final Value<String> status;
  final Value<int> localCreatedAt;
  final Value<int> burnAfterSeconds;
  final Value<int?> expiresAt;
  final Value<bool> burnManual;
  final Value<int?> deletedAt;
  final Value<int> rowid;
  const LocalMessagesCompanion({
    this.messageId = const Value.absent(),
    this.spaceId = const Value.absent(),
    this.senderDeviceId = const Value.absent(),
    this.type = const Value.absent(),
    this.keyVersion = const Value.absent(),
    this.nonce = const Value.absent(),
    this.ciphertext = const Value.absent(),
    this.serverSequence = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.status = const Value.absent(),
    this.localCreatedAt = const Value.absent(),
    this.burnAfterSeconds = const Value.absent(),
    this.expiresAt = const Value.absent(),
    this.burnManual = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalMessagesCompanion.insert({
    required String messageId,
    required String spaceId,
    required String senderDeviceId,
    required String type,
    required int keyVersion,
    required String nonce,
    required String ciphertext,
    this.serverSequence = const Value.absent(),
    required int createdAt,
    this.status = const Value.absent(),
    required int localCreatedAt,
    this.burnAfterSeconds = const Value.absent(),
    this.expiresAt = const Value.absent(),
    this.burnManual = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : messageId = Value(messageId),
       spaceId = Value(spaceId),
       senderDeviceId = Value(senderDeviceId),
       type = Value(type),
       keyVersion = Value(keyVersion),
       nonce = Value(nonce),
       ciphertext = Value(ciphertext),
       createdAt = Value(createdAt),
       localCreatedAt = Value(localCreatedAt);
  static Insertable<LocalMessage> custom({
    Expression<String>? messageId,
    Expression<String>? spaceId,
    Expression<String>? senderDeviceId,
    Expression<String>? type,
    Expression<int>? keyVersion,
    Expression<String>? nonce,
    Expression<String>? ciphertext,
    Expression<int>? serverSequence,
    Expression<int>? createdAt,
    Expression<String>? status,
    Expression<int>? localCreatedAt,
    Expression<int>? burnAfterSeconds,
    Expression<int>? expiresAt,
    Expression<bool>? burnManual,
    Expression<int>? deletedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (messageId != null) 'message_id': messageId,
      if (spaceId != null) 'space_id': spaceId,
      if (senderDeviceId != null) 'sender_device_id': senderDeviceId,
      if (type != null) 'type': type,
      if (keyVersion != null) 'key_version': keyVersion,
      if (nonce != null) 'nonce': nonce,
      if (ciphertext != null) 'ciphertext': ciphertext,
      if (serverSequence != null) 'server_sequence': serverSequence,
      if (createdAt != null) 'created_at': createdAt,
      if (status != null) 'status': status,
      if (localCreatedAt != null) 'local_created_at': localCreatedAt,
      if (burnAfterSeconds != null) 'burn_after_seconds': burnAfterSeconds,
      if (expiresAt != null) 'expires_at': expiresAt,
      if (burnManual != null) 'burn_manual': burnManual,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalMessagesCompanion copyWith({
    Value<String>? messageId,
    Value<String>? spaceId,
    Value<String>? senderDeviceId,
    Value<String>? type,
    Value<int>? keyVersion,
    Value<String>? nonce,
    Value<String>? ciphertext,
    Value<int?>? serverSequence,
    Value<int>? createdAt,
    Value<String>? status,
    Value<int>? localCreatedAt,
    Value<int>? burnAfterSeconds,
    Value<int?>? expiresAt,
    Value<bool>? burnManual,
    Value<int?>? deletedAt,
    Value<int>? rowid,
  }) {
    return LocalMessagesCompanion(
      messageId: messageId ?? this.messageId,
      spaceId: spaceId ?? this.spaceId,
      senderDeviceId: senderDeviceId ?? this.senderDeviceId,
      type: type ?? this.type,
      keyVersion: keyVersion ?? this.keyVersion,
      nonce: nonce ?? this.nonce,
      ciphertext: ciphertext ?? this.ciphertext,
      serverSequence: serverSequence ?? this.serverSequence,
      createdAt: createdAt ?? this.createdAt,
      status: status ?? this.status,
      localCreatedAt: localCreatedAt ?? this.localCreatedAt,
      burnAfterSeconds: burnAfterSeconds ?? this.burnAfterSeconds,
      expiresAt: expiresAt ?? this.expiresAt,
      burnManual: burnManual ?? this.burnManual,
      deletedAt: deletedAt ?? this.deletedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (messageId.present) {
      map['message_id'] = Variable<String>(messageId.value);
    }
    if (spaceId.present) {
      map['space_id'] = Variable<String>(spaceId.value);
    }
    if (senderDeviceId.present) {
      map['sender_device_id'] = Variable<String>(senderDeviceId.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (keyVersion.present) {
      map['key_version'] = Variable<int>(keyVersion.value);
    }
    if (nonce.present) {
      map['nonce'] = Variable<String>(nonce.value);
    }
    if (ciphertext.present) {
      map['ciphertext'] = Variable<String>(ciphertext.value);
    }
    if (serverSequence.present) {
      map['server_sequence'] = Variable<int>(serverSequence.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (localCreatedAt.present) {
      map['local_created_at'] = Variable<int>(localCreatedAt.value);
    }
    if (burnAfterSeconds.present) {
      map['burn_after_seconds'] = Variable<int>(burnAfterSeconds.value);
    }
    if (expiresAt.present) {
      map['expires_at'] = Variable<int>(expiresAt.value);
    }
    if (burnManual.present) {
      map['burn_manual'] = Variable<bool>(burnManual.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<int>(deletedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalMessagesCompanion(')
          ..write('messageId: $messageId, ')
          ..write('spaceId: $spaceId, ')
          ..write('senderDeviceId: $senderDeviceId, ')
          ..write('type: $type, ')
          ..write('keyVersion: $keyVersion, ')
          ..write('nonce: $nonce, ')
          ..write('ciphertext: $ciphertext, ')
          ..write('serverSequence: $serverSequence, ')
          ..write('createdAt: $createdAt, ')
          ..write('status: $status, ')
          ..write('localCreatedAt: $localCreatedAt, ')
          ..write('burnAfterSeconds: $burnAfterSeconds, ')
          ..write('expiresAt: $expiresAt, ')
          ..write('burnManual: $burnManual, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalAttachmentsTable extends LocalAttachments
    with TableInfo<$LocalAttachmentsTable, LocalAttachment> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalAttachmentsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _attachmentIdMeta = const VerificationMeta(
    'attachmentId',
  );
  @override
  late final GeneratedColumn<String> attachmentId = GeneratedColumn<String>(
    'attachment_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _messageIdMeta = const VerificationMeta(
    'messageId',
  );
  @override
  late final GeneratedColumn<String> messageId = GeneratedColumn<String>(
    'message_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES local_messages (message_id)',
    ),
  );
  static const VerificationMeta _keyVersionMeta = const VerificationMeta(
    'keyVersion',
  );
  @override
  late final GeneratedColumn<int> keyVersion = GeneratedColumn<int>(
    'key_version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sizeMeta = const VerificationMeta('size');
  @override
  late final GeneratedColumn<int> size = GeneratedColumn<int>(
    'size',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sha256Meta = const VerificationMeta('sha256');
  @override
  late final GeneratedColumn<String> sha256 = GeneratedColumn<String>(
    'sha256',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nonceMeta = const VerificationMeta('nonce');
  @override
  late final GeneratedColumn<String> nonce = GeneratedColumn<String>(
    'nonce',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _localPathMeta = const VerificationMeta(
    'localPath',
  );
  @override
  late final GeneratedColumn<String> localPath = GeneratedColumn<String>(
    'local_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _localCipherMeta = const VerificationMeta(
    'localCipher',
  );
  @override
  late final GeneratedColumn<Uint8List> localCipher =
      GeneratedColumn<Uint8List>(
        'local_cipher',
        aliasedName,
        true,
        type: DriftSqlType.blob,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('pending'),
  );
  @override
  List<GeneratedColumn> get $columns => [
    attachmentId,
    messageId,
    keyVersion,
    size,
    sha256,
    nonce,
    localPath,
    localCipher,
    status,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_attachments';
  @override
  VerificationContext validateIntegrity(
    Insertable<LocalAttachment> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('attachment_id')) {
      context.handle(
        _attachmentIdMeta,
        attachmentId.isAcceptableOrUnknown(
          data['attachment_id']!,
          _attachmentIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_attachmentIdMeta);
    }
    if (data.containsKey('message_id')) {
      context.handle(
        _messageIdMeta,
        messageId.isAcceptableOrUnknown(data['message_id']!, _messageIdMeta),
      );
    } else if (isInserting) {
      context.missing(_messageIdMeta);
    }
    if (data.containsKey('key_version')) {
      context.handle(
        _keyVersionMeta,
        keyVersion.isAcceptableOrUnknown(data['key_version']!, _keyVersionMeta),
      );
    } else if (isInserting) {
      context.missing(_keyVersionMeta);
    }
    if (data.containsKey('size')) {
      context.handle(
        _sizeMeta,
        size.isAcceptableOrUnknown(data['size']!, _sizeMeta),
      );
    } else if (isInserting) {
      context.missing(_sizeMeta);
    }
    if (data.containsKey('sha256')) {
      context.handle(
        _sha256Meta,
        sha256.isAcceptableOrUnknown(data['sha256']!, _sha256Meta),
      );
    } else if (isInserting) {
      context.missing(_sha256Meta);
    }
    if (data.containsKey('nonce')) {
      context.handle(
        _nonceMeta,
        nonce.isAcceptableOrUnknown(data['nonce']!, _nonceMeta),
      );
    } else if (isInserting) {
      context.missing(_nonceMeta);
    }
    if (data.containsKey('local_path')) {
      context.handle(
        _localPathMeta,
        localPath.isAcceptableOrUnknown(data['local_path']!, _localPathMeta),
      );
    }
    if (data.containsKey('local_cipher')) {
      context.handle(
        _localCipherMeta,
        localCipher.isAcceptableOrUnknown(
          data['local_cipher']!,
          _localCipherMeta,
        ),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {attachmentId};
  @override
  LocalAttachment map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalAttachment(
      attachmentId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}attachment_id'],
      )!,
      messageId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}message_id'],
      )!,
      keyVersion: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}key_version'],
      )!,
      size: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}size'],
      )!,
      sha256: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sha256'],
      )!,
      nonce: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}nonce'],
      )!,
      localPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}local_path'],
      ),
      localCipher: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}local_cipher'],
      ),
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
    );
  }

  @override
  $LocalAttachmentsTable createAlias(String alias) {
    return $LocalAttachmentsTable(attachedDatabase, alias);
  }
}

class LocalAttachment extends DataClass implements Insertable<LocalAttachment> {
  final String attachmentId;
  final String messageId;
  final int keyVersion;
  final int size;
  final String sha256;
  final String nonce;
  final String? localPath;
  final Uint8List? localCipher;
  final String status;
  const LocalAttachment({
    required this.attachmentId,
    required this.messageId,
    required this.keyVersion,
    required this.size,
    required this.sha256,
    required this.nonce,
    this.localPath,
    this.localCipher,
    required this.status,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['attachment_id'] = Variable<String>(attachmentId);
    map['message_id'] = Variable<String>(messageId);
    map['key_version'] = Variable<int>(keyVersion);
    map['size'] = Variable<int>(size);
    map['sha256'] = Variable<String>(sha256);
    map['nonce'] = Variable<String>(nonce);
    if (!nullToAbsent || localPath != null) {
      map['local_path'] = Variable<String>(localPath);
    }
    if (!nullToAbsent || localCipher != null) {
      map['local_cipher'] = Variable<Uint8List>(localCipher);
    }
    map['status'] = Variable<String>(status);
    return map;
  }

  LocalAttachmentsCompanion toCompanion(bool nullToAbsent) {
    return LocalAttachmentsCompanion(
      attachmentId: Value(attachmentId),
      messageId: Value(messageId),
      keyVersion: Value(keyVersion),
      size: Value(size),
      sha256: Value(sha256),
      nonce: Value(nonce),
      localPath: localPath == null && nullToAbsent
          ? const Value.absent()
          : Value(localPath),
      localCipher: localCipher == null && nullToAbsent
          ? const Value.absent()
          : Value(localCipher),
      status: Value(status),
    );
  }

  factory LocalAttachment.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalAttachment(
      attachmentId: serializer.fromJson<String>(json['attachmentId']),
      messageId: serializer.fromJson<String>(json['messageId']),
      keyVersion: serializer.fromJson<int>(json['keyVersion']),
      size: serializer.fromJson<int>(json['size']),
      sha256: serializer.fromJson<String>(json['sha256']),
      nonce: serializer.fromJson<String>(json['nonce']),
      localPath: serializer.fromJson<String?>(json['localPath']),
      localCipher: serializer.fromJson<Uint8List?>(json['localCipher']),
      status: serializer.fromJson<String>(json['status']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'attachmentId': serializer.toJson<String>(attachmentId),
      'messageId': serializer.toJson<String>(messageId),
      'keyVersion': serializer.toJson<int>(keyVersion),
      'size': serializer.toJson<int>(size),
      'sha256': serializer.toJson<String>(sha256),
      'nonce': serializer.toJson<String>(nonce),
      'localPath': serializer.toJson<String?>(localPath),
      'localCipher': serializer.toJson<Uint8List?>(localCipher),
      'status': serializer.toJson<String>(status),
    };
  }

  LocalAttachment copyWith({
    String? attachmentId,
    String? messageId,
    int? keyVersion,
    int? size,
    String? sha256,
    String? nonce,
    Value<String?> localPath = const Value.absent(),
    Value<Uint8List?> localCipher = const Value.absent(),
    String? status,
  }) => LocalAttachment(
    attachmentId: attachmentId ?? this.attachmentId,
    messageId: messageId ?? this.messageId,
    keyVersion: keyVersion ?? this.keyVersion,
    size: size ?? this.size,
    sha256: sha256 ?? this.sha256,
    nonce: nonce ?? this.nonce,
    localPath: localPath.present ? localPath.value : this.localPath,
    localCipher: localCipher.present ? localCipher.value : this.localCipher,
    status: status ?? this.status,
  );
  LocalAttachment copyWithCompanion(LocalAttachmentsCompanion data) {
    return LocalAttachment(
      attachmentId: data.attachmentId.present
          ? data.attachmentId.value
          : this.attachmentId,
      messageId: data.messageId.present ? data.messageId.value : this.messageId,
      keyVersion: data.keyVersion.present
          ? data.keyVersion.value
          : this.keyVersion,
      size: data.size.present ? data.size.value : this.size,
      sha256: data.sha256.present ? data.sha256.value : this.sha256,
      nonce: data.nonce.present ? data.nonce.value : this.nonce,
      localPath: data.localPath.present ? data.localPath.value : this.localPath,
      localCipher: data.localCipher.present
          ? data.localCipher.value
          : this.localCipher,
      status: data.status.present ? data.status.value : this.status,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalAttachment(')
          ..write('attachmentId: $attachmentId, ')
          ..write('messageId: $messageId, ')
          ..write('keyVersion: $keyVersion, ')
          ..write('size: $size, ')
          ..write('sha256: $sha256, ')
          ..write('nonce: $nonce, ')
          ..write('localPath: $localPath, ')
          ..write('localCipher: $localCipher, ')
          ..write('status: $status')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    attachmentId,
    messageId,
    keyVersion,
    size,
    sha256,
    nonce,
    localPath,
    $driftBlobEquality.hash(localCipher),
    status,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalAttachment &&
          other.attachmentId == this.attachmentId &&
          other.messageId == this.messageId &&
          other.keyVersion == this.keyVersion &&
          other.size == this.size &&
          other.sha256 == this.sha256 &&
          other.nonce == this.nonce &&
          other.localPath == this.localPath &&
          $driftBlobEquality.equals(other.localCipher, this.localCipher) &&
          other.status == this.status);
}

class LocalAttachmentsCompanion extends UpdateCompanion<LocalAttachment> {
  final Value<String> attachmentId;
  final Value<String> messageId;
  final Value<int> keyVersion;
  final Value<int> size;
  final Value<String> sha256;
  final Value<String> nonce;
  final Value<String?> localPath;
  final Value<Uint8List?> localCipher;
  final Value<String> status;
  final Value<int> rowid;
  const LocalAttachmentsCompanion({
    this.attachmentId = const Value.absent(),
    this.messageId = const Value.absent(),
    this.keyVersion = const Value.absent(),
    this.size = const Value.absent(),
    this.sha256 = const Value.absent(),
    this.nonce = const Value.absent(),
    this.localPath = const Value.absent(),
    this.localCipher = const Value.absent(),
    this.status = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalAttachmentsCompanion.insert({
    required String attachmentId,
    required String messageId,
    required int keyVersion,
    required int size,
    required String sha256,
    required String nonce,
    this.localPath = const Value.absent(),
    this.localCipher = const Value.absent(),
    this.status = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : attachmentId = Value(attachmentId),
       messageId = Value(messageId),
       keyVersion = Value(keyVersion),
       size = Value(size),
       sha256 = Value(sha256),
       nonce = Value(nonce);
  static Insertable<LocalAttachment> custom({
    Expression<String>? attachmentId,
    Expression<String>? messageId,
    Expression<int>? keyVersion,
    Expression<int>? size,
    Expression<String>? sha256,
    Expression<String>? nonce,
    Expression<String>? localPath,
    Expression<Uint8List>? localCipher,
    Expression<String>? status,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (attachmentId != null) 'attachment_id': attachmentId,
      if (messageId != null) 'message_id': messageId,
      if (keyVersion != null) 'key_version': keyVersion,
      if (size != null) 'size': size,
      if (sha256 != null) 'sha256': sha256,
      if (nonce != null) 'nonce': nonce,
      if (localPath != null) 'local_path': localPath,
      if (localCipher != null) 'local_cipher': localCipher,
      if (status != null) 'status': status,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalAttachmentsCompanion copyWith({
    Value<String>? attachmentId,
    Value<String>? messageId,
    Value<int>? keyVersion,
    Value<int>? size,
    Value<String>? sha256,
    Value<String>? nonce,
    Value<String?>? localPath,
    Value<Uint8List?>? localCipher,
    Value<String>? status,
    Value<int>? rowid,
  }) {
    return LocalAttachmentsCompanion(
      attachmentId: attachmentId ?? this.attachmentId,
      messageId: messageId ?? this.messageId,
      keyVersion: keyVersion ?? this.keyVersion,
      size: size ?? this.size,
      sha256: sha256 ?? this.sha256,
      nonce: nonce ?? this.nonce,
      localPath: localPath ?? this.localPath,
      localCipher: localCipher ?? this.localCipher,
      status: status ?? this.status,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (attachmentId.present) {
      map['attachment_id'] = Variable<String>(attachmentId.value);
    }
    if (messageId.present) {
      map['message_id'] = Variable<String>(messageId.value);
    }
    if (keyVersion.present) {
      map['key_version'] = Variable<int>(keyVersion.value);
    }
    if (size.present) {
      map['size'] = Variable<int>(size.value);
    }
    if (sha256.present) {
      map['sha256'] = Variable<String>(sha256.value);
    }
    if (nonce.present) {
      map['nonce'] = Variable<String>(nonce.value);
    }
    if (localPath.present) {
      map['local_path'] = Variable<String>(localPath.value);
    }
    if (localCipher.present) {
      map['local_cipher'] = Variable<Uint8List>(localCipher.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalAttachmentsCompanion(')
          ..write('attachmentId: $attachmentId, ')
          ..write('messageId: $messageId, ')
          ..write('keyVersion: $keyVersion, ')
          ..write('size: $size, ')
          ..write('sha256: $sha256, ')
          ..write('nonce: $nonce, ')
          ..write('localPath: $localPath, ')
          ..write('localCipher: $localCipher, ')
          ..write('status: $status, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncStateTable extends SyncState
    with TableInfo<$SyncStateTable, SyncStateData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncStateTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _spaceIdMeta = const VerificationMeta(
    'spaceId',
  );
  @override
  late final GeneratedColumn<String> spaceId = GeneratedColumn<String>(
    'space_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastServerSequenceMeta =
      const VerificationMeta('lastServerSequence');
  @override
  late final GeneratedColumn<int> lastServerSequence = GeneratedColumn<int>(
    'last_server_sequence',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [spaceId, lastServerSequence];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_state';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncStateData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('space_id')) {
      context.handle(
        _spaceIdMeta,
        spaceId.isAcceptableOrUnknown(data['space_id']!, _spaceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_spaceIdMeta);
    }
    if (data.containsKey('last_server_sequence')) {
      context.handle(
        _lastServerSequenceMeta,
        lastServerSequence.isAcceptableOrUnknown(
          data['last_server_sequence']!,
          _lastServerSequenceMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {spaceId};
  @override
  SyncStateData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncStateData(
      spaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}space_id'],
      )!,
      lastServerSequence: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_server_sequence'],
      )!,
    );
  }

  @override
  $SyncStateTable createAlias(String alias) {
    return $SyncStateTable(attachedDatabase, alias);
  }
}

class SyncStateData extends DataClass implements Insertable<SyncStateData> {
  final String spaceId;
  final int lastServerSequence;
  const SyncStateData({
    required this.spaceId,
    required this.lastServerSequence,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['space_id'] = Variable<String>(spaceId);
    map['last_server_sequence'] = Variable<int>(lastServerSequence);
    return map;
  }

  SyncStateCompanion toCompanion(bool nullToAbsent) {
    return SyncStateCompanion(
      spaceId: Value(spaceId),
      lastServerSequence: Value(lastServerSequence),
    );
  }

  factory SyncStateData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncStateData(
      spaceId: serializer.fromJson<String>(json['spaceId']),
      lastServerSequence: serializer.fromJson<int>(json['lastServerSequence']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'spaceId': serializer.toJson<String>(spaceId),
      'lastServerSequence': serializer.toJson<int>(lastServerSequence),
    };
  }

  SyncStateData copyWith({String? spaceId, int? lastServerSequence}) =>
      SyncStateData(
        spaceId: spaceId ?? this.spaceId,
        lastServerSequence: lastServerSequence ?? this.lastServerSequence,
      );
  SyncStateData copyWithCompanion(SyncStateCompanion data) {
    return SyncStateData(
      spaceId: data.spaceId.present ? data.spaceId.value : this.spaceId,
      lastServerSequence: data.lastServerSequence.present
          ? data.lastServerSequence.value
          : this.lastServerSequence,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncStateData(')
          ..write('spaceId: $spaceId, ')
          ..write('lastServerSequence: $lastServerSequence')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(spaceId, lastServerSequence);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncStateData &&
          other.spaceId == this.spaceId &&
          other.lastServerSequence == this.lastServerSequence);
}

class SyncStateCompanion extends UpdateCompanion<SyncStateData> {
  final Value<String> spaceId;
  final Value<int> lastServerSequence;
  final Value<int> rowid;
  const SyncStateCompanion({
    this.spaceId = const Value.absent(),
    this.lastServerSequence = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncStateCompanion.insert({
    required String spaceId,
    this.lastServerSequence = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : spaceId = Value(spaceId);
  static Insertable<SyncStateData> custom({
    Expression<String>? spaceId,
    Expression<int>? lastServerSequence,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (spaceId != null) 'space_id': spaceId,
      if (lastServerSequence != null)
        'last_server_sequence': lastServerSequence,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncStateCompanion copyWith({
    Value<String>? spaceId,
    Value<int>? lastServerSequence,
    Value<int>? rowid,
  }) {
    return SyncStateCompanion(
      spaceId: spaceId ?? this.spaceId,
      lastServerSequence: lastServerSequence ?? this.lastServerSequence,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (spaceId.present) {
      map['space_id'] = Variable<String>(spaceId.value);
    }
    if (lastServerSequence.present) {
      map['last_server_sequence'] = Variable<int>(lastServerSequence.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncStateCompanion(')
          ..write('spaceId: $spaceId, ')
          ..write('lastServerSequence: $lastServerSequence, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $DraftsTable extends Drafts with TableInfo<$DraftsTable, Draft> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DraftsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _messageIdMeta = const VerificationMeta(
    'messageId',
  );
  @override
  late final GeneratedColumn<String> messageId = GeneratedColumn<String>(
    'message_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _spaceIdMeta = const VerificationMeta(
    'spaceId',
  );
  @override
  late final GeneratedColumn<String> spaceId = GeneratedColumn<String>(
    'space_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _contentMeta = const VerificationMeta(
    'content',
  );
  @override
  late final GeneratedColumn<String> content = GeneratedColumn<String>(
    'content',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    messageId,
    spaceId,
    content,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'drafts';
  @override
  VerificationContext validateIntegrity(
    Insertable<Draft> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('message_id')) {
      context.handle(
        _messageIdMeta,
        messageId.isAcceptableOrUnknown(data['message_id']!, _messageIdMeta),
      );
    } else if (isInserting) {
      context.missing(_messageIdMeta);
    }
    if (data.containsKey('space_id')) {
      context.handle(
        _spaceIdMeta,
        spaceId.isAcceptableOrUnknown(data['space_id']!, _spaceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_spaceIdMeta);
    }
    if (data.containsKey('content')) {
      context.handle(
        _contentMeta,
        content.isAcceptableOrUnknown(data['content']!, _contentMeta),
      );
    } else if (isInserting) {
      context.missing(_contentMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {messageId};
  @override
  Draft map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Draft(
      messageId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}message_id'],
      )!,
      spaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}space_id'],
      )!,
      content: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $DraftsTable createAlias(String alias) {
    return $DraftsTable(attachedDatabase, alias);
  }
}

class Draft extends DataClass implements Insertable<Draft> {
  final String messageId;
  final String spaceId;
  final String content;
  final int updatedAt;
  const Draft({
    required this.messageId,
    required this.spaceId,
    required this.content,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['message_id'] = Variable<String>(messageId);
    map['space_id'] = Variable<String>(spaceId);
    map['content'] = Variable<String>(content);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  DraftsCompanion toCompanion(bool nullToAbsent) {
    return DraftsCompanion(
      messageId: Value(messageId),
      spaceId: Value(spaceId),
      content: Value(content),
      updatedAt: Value(updatedAt),
    );
  }

  factory Draft.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Draft(
      messageId: serializer.fromJson<String>(json['messageId']),
      spaceId: serializer.fromJson<String>(json['spaceId']),
      content: serializer.fromJson<String>(json['content']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'messageId': serializer.toJson<String>(messageId),
      'spaceId': serializer.toJson<String>(spaceId),
      'content': serializer.toJson<String>(content),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  Draft copyWith({
    String? messageId,
    String? spaceId,
    String? content,
    int? updatedAt,
  }) => Draft(
    messageId: messageId ?? this.messageId,
    spaceId: spaceId ?? this.spaceId,
    content: content ?? this.content,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  Draft copyWithCompanion(DraftsCompanion data) {
    return Draft(
      messageId: data.messageId.present ? data.messageId.value : this.messageId,
      spaceId: data.spaceId.present ? data.spaceId.value : this.spaceId,
      content: data.content.present ? data.content.value : this.content,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Draft(')
          ..write('messageId: $messageId, ')
          ..write('spaceId: $spaceId, ')
          ..write('content: $content, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(messageId, spaceId, content, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Draft &&
          other.messageId == this.messageId &&
          other.spaceId == this.spaceId &&
          other.content == this.content &&
          other.updatedAt == this.updatedAt);
}

class DraftsCompanion extends UpdateCompanion<Draft> {
  final Value<String> messageId;
  final Value<String> spaceId;
  final Value<String> content;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const DraftsCompanion({
    this.messageId = const Value.absent(),
    this.spaceId = const Value.absent(),
    this.content = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  DraftsCompanion.insert({
    required String messageId,
    required String spaceId,
    required String content,
    required int updatedAt,
    this.rowid = const Value.absent(),
  }) : messageId = Value(messageId),
       spaceId = Value(spaceId),
       content = Value(content),
       updatedAt = Value(updatedAt);
  static Insertable<Draft> custom({
    Expression<String>? messageId,
    Expression<String>? spaceId,
    Expression<String>? content,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (messageId != null) 'message_id': messageId,
      if (spaceId != null) 'space_id': spaceId,
      if (content != null) 'content': content,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DraftsCompanion copyWith({
    Value<String>? messageId,
    Value<String>? spaceId,
    Value<String>? content,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return DraftsCompanion(
      messageId: messageId ?? this.messageId,
      spaceId: spaceId ?? this.spaceId,
      content: content ?? this.content,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (messageId.present) {
      map['message_id'] = Variable<String>(messageId.value);
    }
    if (spaceId.present) {
      map['space_id'] = Variable<String>(spaceId.value);
    }
    if (content.present) {
      map['content'] = Variable<String>(content.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DraftsCompanion(')
          ..write('messageId: $messageId, ')
          ..write('spaceId: $spaceId, ')
          ..write('content: $content, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AppStateTable extends AppState
    with TableInfo<$AppStateTable, AppStateData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AppStateTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'app_state';
  @override
  VerificationContext validateIntegrity(
    Insertable<AppStateData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  AppStateData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AppStateData(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $AppStateTable createAlias(String alias) {
    return $AppStateTable(attachedDatabase, alias);
  }
}

class AppStateData extends DataClass implements Insertable<AppStateData> {
  final String key;
  final String value;
  const AppStateData({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  AppStateCompanion toCompanion(bool nullToAbsent) {
    return AppStateCompanion(key: Value(key), value: Value(value));
  }

  factory AppStateData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AppStateData(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  AppStateData copyWith({String? key, String? value}) =>
      AppStateData(key: key ?? this.key, value: value ?? this.value);
  AppStateData copyWithCompanion(AppStateCompanion data) {
    return AppStateData(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AppStateData(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AppStateData &&
          other.key == this.key &&
          other.value == this.value);
}

class AppStateCompanion extends UpdateCompanion<AppStateData> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const AppStateCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AppStateCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<AppStateData> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AppStateCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return AppStateCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AppStateCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PeerReceiptsTable extends PeerReceipts
    with TableInfo<$PeerReceiptsTable, PeerReceipt> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PeerReceiptsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _spaceIdMeta = const VerificationMeta(
    'spaceId',
  );
  @override
  late final GeneratedColumn<String> spaceId = GeneratedColumn<String>(
    'space_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _personIdMeta = const VerificationMeta(
    'personId',
  );
  @override
  late final GeneratedColumn<String> personId = GeneratedColumn<String>(
    'person_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deliveredUptoSeqMeta = const VerificationMeta(
    'deliveredUptoSeq',
  );
  @override
  late final GeneratedColumn<int> deliveredUptoSeq = GeneratedColumn<int>(
    'delivered_upto_seq',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _readUptoSeqMeta = const VerificationMeta(
    'readUptoSeq',
  );
  @override
  late final GeneratedColumn<int> readUptoSeq = GeneratedColumn<int>(
    'read_upto_seq',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    spaceId,
    personId,
    deliveredUptoSeq,
    readUptoSeq,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'peer_receipts';
  @override
  VerificationContext validateIntegrity(
    Insertable<PeerReceipt> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('space_id')) {
      context.handle(
        _spaceIdMeta,
        spaceId.isAcceptableOrUnknown(data['space_id']!, _spaceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_spaceIdMeta);
    }
    if (data.containsKey('person_id')) {
      context.handle(
        _personIdMeta,
        personId.isAcceptableOrUnknown(data['person_id']!, _personIdMeta),
      );
    } else if (isInserting) {
      context.missing(_personIdMeta);
    }
    if (data.containsKey('delivered_upto_seq')) {
      context.handle(
        _deliveredUptoSeqMeta,
        deliveredUptoSeq.isAcceptableOrUnknown(
          data['delivered_upto_seq']!,
          _deliveredUptoSeqMeta,
        ),
      );
    }
    if (data.containsKey('read_upto_seq')) {
      context.handle(
        _readUptoSeqMeta,
        readUptoSeq.isAcceptableOrUnknown(
          data['read_upto_seq']!,
          _readUptoSeqMeta,
        ),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {spaceId, personId};
  @override
  PeerReceipt map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PeerReceipt(
      spaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}space_id'],
      )!,
      personId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}person_id'],
      )!,
      deliveredUptoSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}delivered_upto_seq'],
      )!,
      readUptoSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}read_upto_seq'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $PeerReceiptsTable createAlias(String alias) {
    return $PeerReceiptsTable(attachedDatabase, alias);
  }
}

class PeerReceipt extends DataClass implements Insertable<PeerReceipt> {
  final String spaceId;
  final String personId;
  final int deliveredUptoSeq;
  final int readUptoSeq;
  final int updatedAt;
  const PeerReceipt({
    required this.spaceId,
    required this.personId,
    required this.deliveredUptoSeq,
    required this.readUptoSeq,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['space_id'] = Variable<String>(spaceId);
    map['person_id'] = Variable<String>(personId);
    map['delivered_upto_seq'] = Variable<int>(deliveredUptoSeq);
    map['read_upto_seq'] = Variable<int>(readUptoSeq);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  PeerReceiptsCompanion toCompanion(bool nullToAbsent) {
    return PeerReceiptsCompanion(
      spaceId: Value(spaceId),
      personId: Value(personId),
      deliveredUptoSeq: Value(deliveredUptoSeq),
      readUptoSeq: Value(readUptoSeq),
      updatedAt: Value(updatedAt),
    );
  }

  factory PeerReceipt.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PeerReceipt(
      spaceId: serializer.fromJson<String>(json['spaceId']),
      personId: serializer.fromJson<String>(json['personId']),
      deliveredUptoSeq: serializer.fromJson<int>(json['deliveredUptoSeq']),
      readUptoSeq: serializer.fromJson<int>(json['readUptoSeq']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'spaceId': serializer.toJson<String>(spaceId),
      'personId': serializer.toJson<String>(personId),
      'deliveredUptoSeq': serializer.toJson<int>(deliveredUptoSeq),
      'readUptoSeq': serializer.toJson<int>(readUptoSeq),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  PeerReceipt copyWith({
    String? spaceId,
    String? personId,
    int? deliveredUptoSeq,
    int? readUptoSeq,
    int? updatedAt,
  }) => PeerReceipt(
    spaceId: spaceId ?? this.spaceId,
    personId: personId ?? this.personId,
    deliveredUptoSeq: deliveredUptoSeq ?? this.deliveredUptoSeq,
    readUptoSeq: readUptoSeq ?? this.readUptoSeq,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  PeerReceipt copyWithCompanion(PeerReceiptsCompanion data) {
    return PeerReceipt(
      spaceId: data.spaceId.present ? data.spaceId.value : this.spaceId,
      personId: data.personId.present ? data.personId.value : this.personId,
      deliveredUptoSeq: data.deliveredUptoSeq.present
          ? data.deliveredUptoSeq.value
          : this.deliveredUptoSeq,
      readUptoSeq: data.readUptoSeq.present
          ? data.readUptoSeq.value
          : this.readUptoSeq,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PeerReceipt(')
          ..write('spaceId: $spaceId, ')
          ..write('personId: $personId, ')
          ..write('deliveredUptoSeq: $deliveredUptoSeq, ')
          ..write('readUptoSeq: $readUptoSeq, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(spaceId, personId, deliveredUptoSeq, readUptoSeq, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PeerReceipt &&
          other.spaceId == this.spaceId &&
          other.personId == this.personId &&
          other.deliveredUptoSeq == this.deliveredUptoSeq &&
          other.readUptoSeq == this.readUptoSeq &&
          other.updatedAt == this.updatedAt);
}

class PeerReceiptsCompanion extends UpdateCompanion<PeerReceipt> {
  final Value<String> spaceId;
  final Value<String> personId;
  final Value<int> deliveredUptoSeq;
  final Value<int> readUptoSeq;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const PeerReceiptsCompanion({
    this.spaceId = const Value.absent(),
    this.personId = const Value.absent(),
    this.deliveredUptoSeq = const Value.absent(),
    this.readUptoSeq = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PeerReceiptsCompanion.insert({
    required String spaceId,
    required String personId,
    this.deliveredUptoSeq = const Value.absent(),
    this.readUptoSeq = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : spaceId = Value(spaceId),
       personId = Value(personId);
  static Insertable<PeerReceipt> custom({
    Expression<String>? spaceId,
    Expression<String>? personId,
    Expression<int>? deliveredUptoSeq,
    Expression<int>? readUptoSeq,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (spaceId != null) 'space_id': spaceId,
      if (personId != null) 'person_id': personId,
      if (deliveredUptoSeq != null) 'delivered_upto_seq': deliveredUptoSeq,
      if (readUptoSeq != null) 'read_upto_seq': readUptoSeq,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PeerReceiptsCompanion copyWith({
    Value<String>? spaceId,
    Value<String>? personId,
    Value<int>? deliveredUptoSeq,
    Value<int>? readUptoSeq,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return PeerReceiptsCompanion(
      spaceId: spaceId ?? this.spaceId,
      personId: personId ?? this.personId,
      deliveredUptoSeq: deliveredUptoSeq ?? this.deliveredUptoSeq,
      readUptoSeq: readUptoSeq ?? this.readUptoSeq,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (spaceId.present) {
      map['space_id'] = Variable<String>(spaceId.value);
    }
    if (personId.present) {
      map['person_id'] = Variable<String>(personId.value);
    }
    if (deliveredUptoSeq.present) {
      map['delivered_upto_seq'] = Variable<int>(deliveredUptoSeq.value);
    }
    if (readUptoSeq.present) {
      map['read_upto_seq'] = Variable<int>(readUptoSeq.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PeerReceiptsCompanion(')
          ..write('spaceId: $spaceId, ')
          ..write('personId: $personId, ')
          ..write('deliveredUptoSeq: $deliveredUptoSeq, ')
          ..write('readUptoSeq: $readUptoSeq, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$LocalDatabase extends GeneratedDatabase {
  _$LocalDatabase(QueryExecutor e) : super(e);
  $LocalDatabaseManager get managers => $LocalDatabaseManager(this);
  late final $LocalMessagesTable localMessages = $LocalMessagesTable(this);
  late final $LocalAttachmentsTable localAttachments = $LocalAttachmentsTable(
    this,
  );
  late final $SyncStateTable syncState = $SyncStateTable(this);
  late final $DraftsTable drafts = $DraftsTable(this);
  late final $AppStateTable appState = $AppStateTable(this);
  late final $PeerReceiptsTable peerReceipts = $PeerReceiptsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    localMessages,
    localAttachments,
    syncState,
    drafts,
    appState,
    peerReceipts,
  ];
}

typedef $$LocalMessagesTableCreateCompanionBuilder =
    LocalMessagesCompanion Function({
      required String messageId,
      required String spaceId,
      required String senderDeviceId,
      required String type,
      required int keyVersion,
      required String nonce,
      required String ciphertext,
      Value<int?> serverSequence,
      required int createdAt,
      Value<String> status,
      required int localCreatedAt,
      Value<int> burnAfterSeconds,
      Value<int?> expiresAt,
      Value<bool> burnManual,
      Value<int?> deletedAt,
      Value<int> rowid,
    });
typedef $$LocalMessagesTableUpdateCompanionBuilder =
    LocalMessagesCompanion Function({
      Value<String> messageId,
      Value<String> spaceId,
      Value<String> senderDeviceId,
      Value<String> type,
      Value<int> keyVersion,
      Value<String> nonce,
      Value<String> ciphertext,
      Value<int?> serverSequence,
      Value<int> createdAt,
      Value<String> status,
      Value<int> localCreatedAt,
      Value<int> burnAfterSeconds,
      Value<int?> expiresAt,
      Value<bool> burnManual,
      Value<int?> deletedAt,
      Value<int> rowid,
    });

final class $$LocalMessagesTableReferences
    extends BaseReferences<_$LocalDatabase, $LocalMessagesTable, LocalMessage> {
  $$LocalMessagesTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static MultiTypedResultKey<$LocalAttachmentsTable, List<LocalAttachment>>
  _localAttachmentsRefsTable(_$LocalDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.localAttachments,
        aliasName: 'local_messages__message_id__local_attachments__message_id',
      );

  $$LocalAttachmentsTableProcessedTableManager get localAttachmentsRefs {
    final manager =
        $$LocalAttachmentsTableTableManager($_db, $_db.localAttachments).filter(
          (f) => f.messageId.messageId.sqlEquals(
            $_itemColumn<String>('message_id')!,
          ),
        );

    final cache = $_typedResult.readTableOrNull(
      _localAttachmentsRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$LocalMessagesTableFilterComposer
    extends Composer<_$LocalDatabase, $LocalMessagesTable> {
  $$LocalMessagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get messageId => $composableBuilder(
    column: $table.messageId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get spaceId => $composableBuilder(
    column: $table.spaceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get senderDeviceId => $composableBuilder(
    column: $table.senderDeviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get keyVersion => $composableBuilder(
    column: $table.keyVersion,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get nonce => $composableBuilder(
    column: $table.nonce,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ciphertext => $composableBuilder(
    column: $table.ciphertext,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get serverSequence => $composableBuilder(
    column: $table.serverSequence,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get localCreatedAt => $composableBuilder(
    column: $table.localCreatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get burnAfterSeconds => $composableBuilder(
    column: $table.burnAfterSeconds,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get expiresAt => $composableBuilder(
    column: $table.expiresAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get burnManual => $composableBuilder(
    column: $table.burnManual,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> localAttachmentsRefs(
    Expression<bool> Function($$LocalAttachmentsTableFilterComposer f) f,
  ) {
    final $$LocalAttachmentsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.messageId,
      referencedTable: $db.localAttachments,
      getReferencedColumn: (t) => t.messageId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalAttachmentsTableFilterComposer(
            $db: $db,
            $table: $db.localAttachments,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$LocalMessagesTableOrderingComposer
    extends Composer<_$LocalDatabase, $LocalMessagesTable> {
  $$LocalMessagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get messageId => $composableBuilder(
    column: $table.messageId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get spaceId => $composableBuilder(
    column: $table.spaceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get senderDeviceId => $composableBuilder(
    column: $table.senderDeviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get keyVersion => $composableBuilder(
    column: $table.keyVersion,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get nonce => $composableBuilder(
    column: $table.nonce,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ciphertext => $composableBuilder(
    column: $table.ciphertext,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get serverSequence => $composableBuilder(
    column: $table.serverSequence,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get localCreatedAt => $composableBuilder(
    column: $table.localCreatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get burnAfterSeconds => $composableBuilder(
    column: $table.burnAfterSeconds,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get expiresAt => $composableBuilder(
    column: $table.expiresAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get burnManual => $composableBuilder(
    column: $table.burnManual,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalMessagesTableAnnotationComposer
    extends Composer<_$LocalDatabase, $LocalMessagesTable> {
  $$LocalMessagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get messageId =>
      $composableBuilder(column: $table.messageId, builder: (column) => column);

  GeneratedColumn<String> get spaceId =>
      $composableBuilder(column: $table.spaceId, builder: (column) => column);

  GeneratedColumn<String> get senderDeviceId => $composableBuilder(
    column: $table.senderDeviceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<int> get keyVersion => $composableBuilder(
    column: $table.keyVersion,
    builder: (column) => column,
  );

  GeneratedColumn<String> get nonce =>
      $composableBuilder(column: $table.nonce, builder: (column) => column);

  GeneratedColumn<String> get ciphertext => $composableBuilder(
    column: $table.ciphertext,
    builder: (column) => column,
  );

  GeneratedColumn<int> get serverSequence => $composableBuilder(
    column: $table.serverSequence,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<int> get localCreatedAt => $composableBuilder(
    column: $table.localCreatedAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get burnAfterSeconds => $composableBuilder(
    column: $table.burnAfterSeconds,
    builder: (column) => column,
  );

  GeneratedColumn<int> get expiresAt =>
      $composableBuilder(column: $table.expiresAt, builder: (column) => column);

  GeneratedColumn<bool> get burnManual => $composableBuilder(
    column: $table.burnManual,
    builder: (column) => column,
  );

  GeneratedColumn<int> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  Expression<T> localAttachmentsRefs<T extends Object>(
    Expression<T> Function($$LocalAttachmentsTableAnnotationComposer a) f,
  ) {
    final $$LocalAttachmentsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.messageId,
      referencedTable: $db.localAttachments,
      getReferencedColumn: (t) => t.messageId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalAttachmentsTableAnnotationComposer(
            $db: $db,
            $table: $db.localAttachments,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$LocalMessagesTableTableManager
    extends
        RootTableManager<
          _$LocalDatabase,
          $LocalMessagesTable,
          LocalMessage,
          $$LocalMessagesTableFilterComposer,
          $$LocalMessagesTableOrderingComposer,
          $$LocalMessagesTableAnnotationComposer,
          $$LocalMessagesTableCreateCompanionBuilder,
          $$LocalMessagesTableUpdateCompanionBuilder,
          (LocalMessage, $$LocalMessagesTableReferences),
          LocalMessage,
          PrefetchHooks Function({bool localAttachmentsRefs})
        > {
  $$LocalMessagesTableTableManager(
    _$LocalDatabase db,
    $LocalMessagesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalMessagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalMessagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalMessagesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> messageId = const Value.absent(),
                Value<String> spaceId = const Value.absent(),
                Value<String> senderDeviceId = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<int> keyVersion = const Value.absent(),
                Value<String> nonce = const Value.absent(),
                Value<String> ciphertext = const Value.absent(),
                Value<int?> serverSequence = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<int> localCreatedAt = const Value.absent(),
                Value<int> burnAfterSeconds = const Value.absent(),
                Value<int?> expiresAt = const Value.absent(),
                Value<bool> burnManual = const Value.absent(),
                Value<int?> deletedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalMessagesCompanion(
                messageId: messageId,
                spaceId: spaceId,
                senderDeviceId: senderDeviceId,
                type: type,
                keyVersion: keyVersion,
                nonce: nonce,
                ciphertext: ciphertext,
                serverSequence: serverSequence,
                createdAt: createdAt,
                status: status,
                localCreatedAt: localCreatedAt,
                burnAfterSeconds: burnAfterSeconds,
                expiresAt: expiresAt,
                burnManual: burnManual,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String messageId,
                required String spaceId,
                required String senderDeviceId,
                required String type,
                required int keyVersion,
                required String nonce,
                required String ciphertext,
                Value<int?> serverSequence = const Value.absent(),
                required int createdAt,
                Value<String> status = const Value.absent(),
                required int localCreatedAt,
                Value<int> burnAfterSeconds = const Value.absent(),
                Value<int?> expiresAt = const Value.absent(),
                Value<bool> burnManual = const Value.absent(),
                Value<int?> deletedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalMessagesCompanion.insert(
                messageId: messageId,
                spaceId: spaceId,
                senderDeviceId: senderDeviceId,
                type: type,
                keyVersion: keyVersion,
                nonce: nonce,
                ciphertext: ciphertext,
                serverSequence: serverSequence,
                createdAt: createdAt,
                status: status,
                localCreatedAt: localCreatedAt,
                burnAfterSeconds: burnAfterSeconds,
                expiresAt: expiresAt,
                burnManual: burnManual,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$LocalMessagesTable, LocalMessage>(table),
                  $$LocalMessagesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({localAttachmentsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (localAttachmentsRefs) db.localAttachments,
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (localAttachmentsRefs)
                    await $_getPrefetchedData<
                      LocalMessage,
                      $LocalMessagesTable,
                      LocalAttachment
                    >(
                      currentTable: table,
                      referencedTable: $$LocalMessagesTableReferences
                          ._localAttachmentsRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$LocalMessagesTableReferences(
                            db,
                            table,
                            p0,
                          ).localAttachmentsRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where(
                            (e) => e.messageId == item.messageId,
                          ),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$LocalMessagesTableProcessedTableManager =
    ProcessedTableManager<
      _$LocalDatabase,
      $LocalMessagesTable,
      LocalMessage,
      $$LocalMessagesTableFilterComposer,
      $$LocalMessagesTableOrderingComposer,
      $$LocalMessagesTableAnnotationComposer,
      $$LocalMessagesTableCreateCompanionBuilder,
      $$LocalMessagesTableUpdateCompanionBuilder,
      (LocalMessage, $$LocalMessagesTableReferences),
      LocalMessage,
      PrefetchHooks Function({bool localAttachmentsRefs})
    >;
typedef $$LocalAttachmentsTableCreateCompanionBuilder =
    LocalAttachmentsCompanion Function({
      required String attachmentId,
      required String messageId,
      required int keyVersion,
      required int size,
      required String sha256,
      required String nonce,
      Value<String?> localPath,
      Value<Uint8List?> localCipher,
      Value<String> status,
      Value<int> rowid,
    });
typedef $$LocalAttachmentsTableUpdateCompanionBuilder =
    LocalAttachmentsCompanion Function({
      Value<String> attachmentId,
      Value<String> messageId,
      Value<int> keyVersion,
      Value<int> size,
      Value<String> sha256,
      Value<String> nonce,
      Value<String?> localPath,
      Value<Uint8List?> localCipher,
      Value<String> status,
      Value<int> rowid,
    });

final class $$LocalAttachmentsTableReferences
    extends
        BaseReferences<
          _$LocalDatabase,
          $LocalAttachmentsTable,
          LocalAttachment
        > {
  $$LocalAttachmentsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $LocalMessagesTable _messageIdTable(_$LocalDatabase db) => db
      .localMessages
      .createAlias('local_attachments__message_id__local_messages__message_id');

  $$LocalMessagesTableProcessedTableManager get messageId {
    final $_column = $_itemColumn<String>('message_id')!;

    final manager = $$LocalMessagesTableTableManager(
      $_db,
      $_db.localMessages,
    ).filter((f) => f.messageId.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_messageIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$LocalAttachmentsTableFilterComposer
    extends Composer<_$LocalDatabase, $LocalAttachmentsTable> {
  $$LocalAttachmentsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get attachmentId => $composableBuilder(
    column: $table.attachmentId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get keyVersion => $composableBuilder(
    column: $table.keyVersion,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get size => $composableBuilder(
    column: $table.size,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sha256 => $composableBuilder(
    column: $table.sha256,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get nonce => $composableBuilder(
    column: $table.nonce,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get localPath => $composableBuilder(
    column: $table.localPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get localCipher => $composableBuilder(
    column: $table.localCipher,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  $$LocalMessagesTableFilterComposer get messageId {
    final $$LocalMessagesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.messageId,
      referencedTable: $db.localMessages,
      getReferencedColumn: (t) => t.messageId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalMessagesTableFilterComposer(
            $db: $db,
            $table: $db.localMessages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LocalAttachmentsTableOrderingComposer
    extends Composer<_$LocalDatabase, $LocalAttachmentsTable> {
  $$LocalAttachmentsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get attachmentId => $composableBuilder(
    column: $table.attachmentId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get keyVersion => $composableBuilder(
    column: $table.keyVersion,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get size => $composableBuilder(
    column: $table.size,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sha256 => $composableBuilder(
    column: $table.sha256,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get nonce => $composableBuilder(
    column: $table.nonce,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get localPath => $composableBuilder(
    column: $table.localPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get localCipher => $composableBuilder(
    column: $table.localCipher,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  $$LocalMessagesTableOrderingComposer get messageId {
    final $$LocalMessagesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.messageId,
      referencedTable: $db.localMessages,
      getReferencedColumn: (t) => t.messageId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalMessagesTableOrderingComposer(
            $db: $db,
            $table: $db.localMessages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LocalAttachmentsTableAnnotationComposer
    extends Composer<_$LocalDatabase, $LocalAttachmentsTable> {
  $$LocalAttachmentsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get attachmentId => $composableBuilder(
    column: $table.attachmentId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get keyVersion => $composableBuilder(
    column: $table.keyVersion,
    builder: (column) => column,
  );

  GeneratedColumn<int> get size =>
      $composableBuilder(column: $table.size, builder: (column) => column);

  GeneratedColumn<String> get sha256 =>
      $composableBuilder(column: $table.sha256, builder: (column) => column);

  GeneratedColumn<String> get nonce =>
      $composableBuilder(column: $table.nonce, builder: (column) => column);

  GeneratedColumn<String> get localPath =>
      $composableBuilder(column: $table.localPath, builder: (column) => column);

  GeneratedColumn<Uint8List> get localCipher => $composableBuilder(
    column: $table.localCipher,
    builder: (column) => column,
  );

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  $$LocalMessagesTableAnnotationComposer get messageId {
    final $$LocalMessagesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.messageId,
      referencedTable: $db.localMessages,
      getReferencedColumn: (t) => t.messageId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalMessagesTableAnnotationComposer(
            $db: $db,
            $table: $db.localMessages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LocalAttachmentsTableTableManager
    extends
        RootTableManager<
          _$LocalDatabase,
          $LocalAttachmentsTable,
          LocalAttachment,
          $$LocalAttachmentsTableFilterComposer,
          $$LocalAttachmentsTableOrderingComposer,
          $$LocalAttachmentsTableAnnotationComposer,
          $$LocalAttachmentsTableCreateCompanionBuilder,
          $$LocalAttachmentsTableUpdateCompanionBuilder,
          (LocalAttachment, $$LocalAttachmentsTableReferences),
          LocalAttachment,
          PrefetchHooks Function({bool messageId})
        > {
  $$LocalAttachmentsTableTableManager(
    _$LocalDatabase db,
    $LocalAttachmentsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalAttachmentsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalAttachmentsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalAttachmentsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> attachmentId = const Value.absent(),
                Value<String> messageId = const Value.absent(),
                Value<int> keyVersion = const Value.absent(),
                Value<int> size = const Value.absent(),
                Value<String> sha256 = const Value.absent(),
                Value<String> nonce = const Value.absent(),
                Value<String?> localPath = const Value.absent(),
                Value<Uint8List?> localCipher = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalAttachmentsCompanion(
                attachmentId: attachmentId,
                messageId: messageId,
                keyVersion: keyVersion,
                size: size,
                sha256: sha256,
                nonce: nonce,
                localPath: localPath,
                localCipher: localCipher,
                status: status,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String attachmentId,
                required String messageId,
                required int keyVersion,
                required int size,
                required String sha256,
                required String nonce,
                Value<String?> localPath = const Value.absent(),
                Value<Uint8List?> localCipher = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalAttachmentsCompanion.insert(
                attachmentId: attachmentId,
                messageId: messageId,
                keyVersion: keyVersion,
                size: size,
                sha256: sha256,
                nonce: nonce,
                localPath: localPath,
                localCipher: localCipher,
                status: status,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$LocalAttachmentsTable, LocalAttachment>(table),
                  $$LocalAttachmentsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({messageId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (messageId) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.messageId,
                        referencedTable: $$LocalAttachmentsTableReferences
                            ._messageIdTable(db),
                        referencedColumn: $$LocalAttachmentsTableReferences
                            ._messageIdTable(db)
                            .messageId,
                      ) as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$LocalAttachmentsTableProcessedTableManager =
    ProcessedTableManager<
      _$LocalDatabase,
      $LocalAttachmentsTable,
      LocalAttachment,
      $$LocalAttachmentsTableFilterComposer,
      $$LocalAttachmentsTableOrderingComposer,
      $$LocalAttachmentsTableAnnotationComposer,
      $$LocalAttachmentsTableCreateCompanionBuilder,
      $$LocalAttachmentsTableUpdateCompanionBuilder,
      (LocalAttachment, $$LocalAttachmentsTableReferences),
      LocalAttachment,
      PrefetchHooks Function({bool messageId})
    >;
typedef $$SyncStateTableCreateCompanionBuilder = SyncStateCompanion Function({
  required String spaceId,
  Value<int> lastServerSequence,
  Value<int> rowid,
});
typedef $$SyncStateTableUpdateCompanionBuilder = SyncStateCompanion Function({
  Value<String> spaceId,
  Value<int> lastServerSequence,
  Value<int> rowid,
});

class $$SyncStateTableFilterComposer
    extends Composer<_$LocalDatabase, $SyncStateTable> {
  $$SyncStateTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get spaceId => $composableBuilder(
    column: $table.spaceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastServerSequence => $composableBuilder(
    column: $table.lastServerSequence,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SyncStateTableOrderingComposer
    extends Composer<_$LocalDatabase, $SyncStateTable> {
  $$SyncStateTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get spaceId => $composableBuilder(
    column: $table.spaceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastServerSequence => $composableBuilder(
    column: $table.lastServerSequence,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SyncStateTableAnnotationComposer
    extends Composer<_$LocalDatabase, $SyncStateTable> {
  $$SyncStateTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get spaceId =>
      $composableBuilder(column: $table.spaceId, builder: (column) => column);

  GeneratedColumn<int> get lastServerSequence => $composableBuilder(
    column: $table.lastServerSequence,
    builder: (column) => column,
  );
}

class $$SyncStateTableTableManager
    extends
        RootTableManager<
          _$LocalDatabase,
          $SyncStateTable,
          SyncStateData,
          $$SyncStateTableFilterComposer,
          $$SyncStateTableOrderingComposer,
          $$SyncStateTableAnnotationComposer,
          $$SyncStateTableCreateCompanionBuilder,
          $$SyncStateTableUpdateCompanionBuilder,
          (
            SyncStateData,
            BaseReferences<_$LocalDatabase, $SyncStateTable, SyncStateData>,
          ),
          SyncStateData,
          PrefetchHooks Function()
        > {
  $$SyncStateTableTableManager(_$LocalDatabase db, $SyncStateTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncStateTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncStateTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncStateTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> spaceId = const Value.absent(),
                Value<int> lastServerSequence = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncStateCompanion(
                spaceId: spaceId,
                lastServerSequence: lastServerSequence,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String spaceId,
                Value<int> lastServerSequence = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncStateCompanion.insert(
                spaceId: spaceId,
                lastServerSequence: lastServerSequence,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SyncStateTable, SyncStateData>(table),
                  BaseReferences<
                    _$LocalDatabase,
                    $SyncStateTable,
                    SyncStateData
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SyncStateTableProcessedTableManager =
    ProcessedTableManager<
      _$LocalDatabase,
      $SyncStateTable,
      SyncStateData,
      $$SyncStateTableFilterComposer,
      $$SyncStateTableOrderingComposer,
      $$SyncStateTableAnnotationComposer,
      $$SyncStateTableCreateCompanionBuilder,
      $$SyncStateTableUpdateCompanionBuilder,
      (
        SyncStateData,
        BaseReferences<_$LocalDatabase, $SyncStateTable, SyncStateData>,
      ),
      SyncStateData,
      PrefetchHooks Function()
    >;
typedef $$DraftsTableCreateCompanionBuilder = DraftsCompanion Function({
  required String messageId,
  required String spaceId,
  required String content,
  required int updatedAt,
  Value<int> rowid,
});
typedef $$DraftsTableUpdateCompanionBuilder = DraftsCompanion Function({
  Value<String> messageId,
  Value<String> spaceId,
  Value<String> content,
  Value<int> updatedAt,
  Value<int> rowid,
});

class $$DraftsTableFilterComposer
    extends Composer<_$LocalDatabase, $DraftsTable> {
  $$DraftsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get messageId => $composableBuilder(
    column: $table.messageId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get spaceId => $composableBuilder(
    column: $table.spaceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$DraftsTableOrderingComposer
    extends Composer<_$LocalDatabase, $DraftsTable> {
  $$DraftsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get messageId => $composableBuilder(
    column: $table.messageId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get spaceId => $composableBuilder(
    column: $table.spaceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$DraftsTableAnnotationComposer
    extends Composer<_$LocalDatabase, $DraftsTable> {
  $$DraftsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get messageId =>
      $composableBuilder(column: $table.messageId, builder: (column) => column);

  GeneratedColumn<String> get spaceId =>
      $composableBuilder(column: $table.spaceId, builder: (column) => column);

  GeneratedColumn<String> get content =>
      $composableBuilder(column: $table.content, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$DraftsTableTableManager
    extends
        RootTableManager<
          _$LocalDatabase,
          $DraftsTable,
          Draft,
          $$DraftsTableFilterComposer,
          $$DraftsTableOrderingComposer,
          $$DraftsTableAnnotationComposer,
          $$DraftsTableCreateCompanionBuilder,
          $$DraftsTableUpdateCompanionBuilder,
          (Draft, BaseReferences<_$LocalDatabase, $DraftsTable, Draft>),
          Draft,
          PrefetchHooks Function()
        > {
  $$DraftsTableTableManager(_$LocalDatabase db, $DraftsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DraftsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DraftsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DraftsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> messageId = const Value.absent(),
                Value<String> spaceId = const Value.absent(),
                Value<String> content = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => DraftsCompanion(
                messageId: messageId,
                spaceId: spaceId,
                content: content,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String messageId,
                required String spaceId,
                required String content,
                required int updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => DraftsCompanion.insert(
                messageId: messageId,
                spaceId: spaceId,
                content: content,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$DraftsTable, Draft>(table),
                  BaseReferences<_$LocalDatabase, $DraftsTable, Draft>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$DraftsTableProcessedTableManager =
    ProcessedTableManager<
      _$LocalDatabase,
      $DraftsTable,
      Draft,
      $$DraftsTableFilterComposer,
      $$DraftsTableOrderingComposer,
      $$DraftsTableAnnotationComposer,
      $$DraftsTableCreateCompanionBuilder,
      $$DraftsTableUpdateCompanionBuilder,
      (Draft, BaseReferences<_$LocalDatabase, $DraftsTable, Draft>),
      Draft,
      PrefetchHooks Function()
    >;
typedef $$AppStateTableCreateCompanionBuilder = AppStateCompanion Function({
  required String key,
  required String value,
  Value<int> rowid,
});
typedef $$AppStateTableUpdateCompanionBuilder = AppStateCompanion Function({
  Value<String> key,
  Value<String> value,
  Value<int> rowid,
});

class $$AppStateTableFilterComposer
    extends Composer<_$LocalDatabase, $AppStateTable> {
  $$AppStateTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AppStateTableOrderingComposer
    extends Composer<_$LocalDatabase, $AppStateTable> {
  $$AppStateTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AppStateTableAnnotationComposer
    extends Composer<_$LocalDatabase, $AppStateTable> {
  $$AppStateTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$AppStateTableTableManager
    extends
        RootTableManager<
          _$LocalDatabase,
          $AppStateTable,
          AppStateData,
          $$AppStateTableFilterComposer,
          $$AppStateTableOrderingComposer,
          $$AppStateTableAnnotationComposer,
          $$AppStateTableCreateCompanionBuilder,
          $$AppStateTableUpdateCompanionBuilder,
          (
            AppStateData,
            BaseReferences<_$LocalDatabase, $AppStateTable, AppStateData>,
          ),
          AppStateData,
          PrefetchHooks Function()
        > {
  $$AppStateTableTableManager(_$LocalDatabase db, $AppStateTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AppStateTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AppStateTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AppStateTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<String> value = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) => AppStateCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback: ({
            required String key,
            required String value,
            Value<int> rowid = const Value.absent(),
          }) => AppStateCompanion.insert(key: key, value: value, rowid: rowid),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$AppStateTable, AppStateData>(table),
                  BaseReferences<_$LocalDatabase, $AppStateTable, AppStateData>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AppStateTableProcessedTableManager =
    ProcessedTableManager<
      _$LocalDatabase,
      $AppStateTable,
      AppStateData,
      $$AppStateTableFilterComposer,
      $$AppStateTableOrderingComposer,
      $$AppStateTableAnnotationComposer,
      $$AppStateTableCreateCompanionBuilder,
      $$AppStateTableUpdateCompanionBuilder,
      (
        AppStateData,
        BaseReferences<_$LocalDatabase, $AppStateTable, AppStateData>,
      ),
      AppStateData,
      PrefetchHooks Function()
    >;
typedef $$PeerReceiptsTableCreateCompanionBuilder =
    PeerReceiptsCompanion Function({
      required String spaceId,
      required String personId,
      Value<int> deliveredUptoSeq,
      Value<int> readUptoSeq,
      Value<int> updatedAt,
      Value<int> rowid,
    });
typedef $$PeerReceiptsTableUpdateCompanionBuilder =
    PeerReceiptsCompanion Function({
      Value<String> spaceId,
      Value<String> personId,
      Value<int> deliveredUptoSeq,
      Value<int> readUptoSeq,
      Value<int> updatedAt,
      Value<int> rowid,
    });

class $$PeerReceiptsTableFilterComposer
    extends Composer<_$LocalDatabase, $PeerReceiptsTable> {
  $$PeerReceiptsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get spaceId => $composableBuilder(
    column: $table.spaceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get personId => $composableBuilder(
    column: $table.personId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get deliveredUptoSeq => $composableBuilder(
    column: $table.deliveredUptoSeq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get readUptoSeq => $composableBuilder(
    column: $table.readUptoSeq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$PeerReceiptsTableOrderingComposer
    extends Composer<_$LocalDatabase, $PeerReceiptsTable> {
  $$PeerReceiptsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get spaceId => $composableBuilder(
    column: $table.spaceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get personId => $composableBuilder(
    column: $table.personId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get deliveredUptoSeq => $composableBuilder(
    column: $table.deliveredUptoSeq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get readUptoSeq => $composableBuilder(
    column: $table.readUptoSeq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$PeerReceiptsTableAnnotationComposer
    extends Composer<_$LocalDatabase, $PeerReceiptsTable> {
  $$PeerReceiptsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get spaceId =>
      $composableBuilder(column: $table.spaceId, builder: (column) => column);

  GeneratedColumn<String> get personId =>
      $composableBuilder(column: $table.personId, builder: (column) => column);

  GeneratedColumn<int> get deliveredUptoSeq => $composableBuilder(
    column: $table.deliveredUptoSeq,
    builder: (column) => column,
  );

  GeneratedColumn<int> get readUptoSeq => $composableBuilder(
    column: $table.readUptoSeq,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$PeerReceiptsTableTableManager
    extends
        RootTableManager<
          _$LocalDatabase,
          $PeerReceiptsTable,
          PeerReceipt,
          $$PeerReceiptsTableFilterComposer,
          $$PeerReceiptsTableOrderingComposer,
          $$PeerReceiptsTableAnnotationComposer,
          $$PeerReceiptsTableCreateCompanionBuilder,
          $$PeerReceiptsTableUpdateCompanionBuilder,
          (
            PeerReceipt,
            BaseReferences<_$LocalDatabase, $PeerReceiptsTable, PeerReceipt>,
          ),
          PeerReceipt,
          PrefetchHooks Function()
        > {
  $$PeerReceiptsTableTableManager(_$LocalDatabase db, $PeerReceiptsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PeerReceiptsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PeerReceiptsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PeerReceiptsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> spaceId = const Value.absent(),
                Value<String> personId = const Value.absent(),
                Value<int> deliveredUptoSeq = const Value.absent(),
                Value<int> readUptoSeq = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PeerReceiptsCompanion(
                spaceId: spaceId,
                personId: personId,
                deliveredUptoSeq: deliveredUptoSeq,
                readUptoSeq: readUptoSeq,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String spaceId,
                required String personId,
                Value<int> deliveredUptoSeq = const Value.absent(),
                Value<int> readUptoSeq = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PeerReceiptsCompanion.insert(
                spaceId: spaceId,
                personId: personId,
                deliveredUptoSeq: deliveredUptoSeq,
                readUptoSeq: readUptoSeq,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$PeerReceiptsTable, PeerReceipt>(table),
                  BaseReferences<
                    _$LocalDatabase,
                    $PeerReceiptsTable,
                    PeerReceipt
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$PeerReceiptsTableProcessedTableManager =
    ProcessedTableManager<
      _$LocalDatabase,
      $PeerReceiptsTable,
      PeerReceipt,
      $$PeerReceiptsTableFilterComposer,
      $$PeerReceiptsTableOrderingComposer,
      $$PeerReceiptsTableAnnotationComposer,
      $$PeerReceiptsTableCreateCompanionBuilder,
      $$PeerReceiptsTableUpdateCompanionBuilder,
      (
        PeerReceipt,
        BaseReferences<_$LocalDatabase, $PeerReceiptsTable, PeerReceipt>,
      ),
      PeerReceipt,
      PrefetchHooks Function()
    >;

class $LocalDatabaseManager {
  final _$LocalDatabase _db;
  $LocalDatabaseManager(this._db);
  $$LocalMessagesTableTableManager get localMessages =>
      $$LocalMessagesTableTableManager(_db, _db.localMessages);
  $$LocalAttachmentsTableTableManager get localAttachments =>
      $$LocalAttachmentsTableTableManager(_db, _db.localAttachments);
  $$SyncStateTableTableManager get syncState =>
      $$SyncStateTableTableManager(_db, _db.syncState);
  $$DraftsTableTableManager get drafts =>
      $$DraftsTableTableManager(_db, _db.drafts);
  $$AppStateTableTableManager get appState =>
      $$AppStateTableTableManager(_db, _db.appState);
  $$PeerReceiptsTableTableManager get peerReceipts =>
      $$PeerReceiptsTableTableManager(_db, _db.peerReceipts);
}
