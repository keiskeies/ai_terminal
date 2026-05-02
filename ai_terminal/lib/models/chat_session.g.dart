// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'chat_session.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class ChatSessionAdapter extends TypeAdapter<ChatSession> {
  @override
  final int typeId = 2;

  @override
  ChatSession read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return ChatSession()
      ..id = fields[0] as String
      ..hostId = fields[1] as String?
      ..messages = (fields[2] as List).cast<ChatMessage>()
      ..createdAt = fields[3] as DateTime
      ..updatedAt = fields[4] as DateTime;
  }

  @override
  void write(BinaryWriter writer, ChatSession obj) {
    writer
      ..writeByte(5)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.hostId)
      ..writeByte(2)
      ..write(obj.messages)
      ..writeByte(3)
      ..write(obj.createdAt)
      ..writeByte(4)
      ..write(obj.updatedAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatSessionAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class ChatMessageAdapter extends TypeAdapter<ChatMessage> {
  @override
  final int typeId = 4;

  @override
  ChatMessage read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return ChatMessage()
      ..role = fields[0] as String
      ..content = fields[1] as String
      ..timestamp = fields[2] as DateTime
      ..commandBlocks = (fields[3] as List?)?.cast<CommandBlock>();
  }

  @override
  void write(BinaryWriter writer, ChatMessage obj) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(obj.role)
      ..writeByte(1)
      ..write(obj.content)
      ..writeByte(2)
      ..write(obj.timestamp)
      ..writeByte(3)
      ..write(obj.commandBlocks);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatMessageAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class CommandBlockAdapter extends TypeAdapter<CommandBlock> {
  @override
  final int typeId = 5;

  @override
  CommandBlock read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return CommandBlock()
      ..command = fields[0] as String
      ..description = fields[1] as String?
      ..dangerous = fields[2] as bool
      ..safetyLevel = fields[3] as String
      ..output = fields[4] as String?;
  }

  @override
  void write(BinaryWriter writer, CommandBlock obj) {
    writer
      ..writeByte(5)
      ..writeByte(0)
      ..write(obj.command)
      ..writeByte(1)
      ..write(obj.description)
      ..writeByte(2)
      ..write(obj.dangerous)
      ..writeByte(3)
      ..write(obj.safetyLevel)
      ..writeByte(4)
      ..write(obj.output);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CommandBlockAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
