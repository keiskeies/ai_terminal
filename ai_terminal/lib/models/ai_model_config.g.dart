// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ai_model_config.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class AIModelConfigAdapter extends TypeAdapter<AIModelConfig> {
  @override
  final int typeId = 1;

  @override
  AIModelConfig read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return AIModelConfig()
      ..id = fields[0] as String
      ..provider = fields[1] as String
      ..name = fields[2] as String
      ..apiKey = fields[3] as String
      ..baseUrl = fields[4] as String
      ..modelName = fields[5] as String
      ..temperature = fields[6] as double
      ..maxTokens = fields[7] as int
      ..isDefault = fields[8] as bool;
  }

  @override
  void write(BinaryWriter writer, AIModelConfig obj) {
    writer
      ..writeByte(9)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.provider)
      ..writeByte(2)
      ..write(obj.name)
      ..writeByte(3)
      ..write(obj.apiKey)
      ..writeByte(4)
      ..write(obj.baseUrl)
      ..writeByte(5)
      ..write(obj.modelName)
      ..writeByte(6)
      ..write(obj.temperature)
      ..writeByte(7)
      ..write(obj.maxTokens)
      ..writeByte(8)
      ..write(obj.isDefault);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AIModelConfigAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
