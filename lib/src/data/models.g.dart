// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'models.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class SessionAdapter extends TypeAdapter<Session> {
  @override
  final int typeId = 0;

  @override
  Session read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Session(
      id: fields[0] as String,
      title: fields[1] as String,
      createdAt: fields[2] as DateTime,
      startedAt: fields[3] as DateTime?,
      endedAt: fields[4] as DateTime?,
      durationMsLive: fields[5] as int,
      srcLang: fields[6] as String,
      tgtLang: fields[7] as String,
      mode: fields[8] as String,
      favorite: fields[9] as bool,
    );
  }

  @override
  void write(BinaryWriter writer, Session obj) {
    writer
      ..writeByte(10)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.title)
      ..writeByte(2)
      ..write(obj.createdAt)
      ..writeByte(3)
      ..write(obj.startedAt)
      ..writeByte(4)
      ..write(obj.endedAt)
      ..writeByte(5)
      ..write(obj.durationMsLive)
      ..writeByte(6)
      ..write(obj.srcLang)
      ..writeByte(7)
      ..write(obj.tgtLang)
      ..writeByte(8)
      ..write(obj.mode)
      ..writeByte(9)
      ..write(obj.favorite);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class SegmentAdapter extends TypeAdapter<Segment> {
  @override
  final int typeId = 1;

  @override
  Segment read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Segment(
      id: fields[0] as String,
      sessionId: fields[1] as String,
      t0Ms: fields[2] as double,
      t1Ms: fields[3] as double,
      sourceText: fields[4] as String,
      translatedText: fields[5] as String,
      confidence: fields[6] as double?,
      srcLang: fields[7] as String,
      searchIndex: fields[8] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, Segment obj) {
    writer
      ..writeByte(9)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.sessionId)
      ..writeByte(2)
      ..write(obj.t0Ms)
      ..writeByte(3)
      ..write(obj.t1Ms)
      ..writeByte(4)
      ..write(obj.sourceText)
      ..writeByte(5)
      ..write(obj.translatedText)
      ..writeByte(6)
      ..write(obj.confidence)
      ..writeByte(7)
      ..write(obj.srcLang)
      ..writeByte(8)
      ..write(obj.searchIndex);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SegmentAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
