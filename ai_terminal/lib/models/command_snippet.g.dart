// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'command_snippet.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class CommandSnippetAdapter extends TypeAdapter<CommandSnippet> {
  @override
  final int typeId = 3;

  @override
  CommandSnippet read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return CommandSnippet()
      ..id = fields[0] as String
      ..name = fields[1] as String
      ..command = fields[2] as String
      ..description = fields[3] as String?
      ..variables = (fields[4] as List).cast<String>()
      ..createdAt = fields[5] as DateTime;
  }

  @override
  void write(BinaryWriter writer, CommandSnippet obj) {
    writer
      ..writeByte(6)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.command)
      ..writeByte(3)
      ..write(obj.description)
      ..writeByte(4)
      ..write(obj.variables)
      ..writeByte(5)
      ..write(obj.createdAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CommandSnippetAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
