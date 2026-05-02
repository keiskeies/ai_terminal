// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'host_config.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class HostConfigAdapter extends TypeAdapter<HostConfig> {
  @override
  final int typeId = 0;

  @override
  HostConfig read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return HostConfig()
      ..id = fields[0] as String
      ..name = fields[1] as String
      ..host = fields[2] as String
      ..port = fields[3] as int
      ..username = fields[4] as String
      ..authType = fields[10] as String
      ..group = fields[20] as String
      ..tagColor = fields[21] as String?
      ..jumpHost = fields[22] as String?
      ..timeout = fields[23] as int
      ..encoding = fields[24] as String
      ..jumpPort = fields[25] as int? ?? 22
      ..jumpUsername = fields[26] as String?
      ..jumpAuthType = fields[27] as String?
      ..createdAt = fields[30] as DateTime
      ..lastConnectedAt = fields[31] as DateTime?
      ..lastStatus = fields[32] as String?;
  }

  @override
  void write(BinaryWriter writer, HostConfig obj) {
    writer
      ..writeByte(17)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.host)
      ..writeByte(3)
      ..write(obj.port)
      ..writeByte(4)
      ..write(obj.username)
      ..writeByte(10)
      ..write(obj.authType)
      ..writeByte(20)
      ..write(obj.group)
      ..writeByte(21)
      ..write(obj.tagColor)
      ..writeByte(22)
      ..write(obj.jumpHost)
      ..writeByte(23)
      ..write(obj.timeout)
      ..writeByte(24)
      ..write(obj.encoding)
      ..writeByte(25)
      ..write(obj.jumpPort)
      ..writeByte(26)
      ..write(obj.jumpUsername)
      ..writeByte(27)
      ..write(obj.jumpAuthType)
      ..writeByte(30)
      ..write(obj.createdAt)
      ..writeByte(31)
      ..write(obj.lastConnectedAt)
      ..writeByte(32)
      ..write(obj.lastStatus);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HostConfigAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
