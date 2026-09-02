import 'package:hive/hive.dart';

/// Hive `DateTime` adapter — REQUIRED because hive 2.2.3's [BinaryWriter] has
/// no built-in DateTime branch (writing one throws
/// `HiveError: Cannot write, unknown type: DateTime`), so every Session row
/// with createdAt/startedAt/endedAt silently failed to persist.
/// typeId 30: clear of Session (0) and Segment (1).
class DateTimeAdapter extends TypeAdapter<DateTime> {
  @override
  final int typeId = 30;

  @override
  DateTime read(BinaryReader reader) =>
      DateTime.fromMillisecondsSinceEpoch(reader.readInt());

  @override
  void write(BinaryWriter writer, DateTime obj) =>
      writer.writeInt(obj.millisecondsSinceEpoch);
}
