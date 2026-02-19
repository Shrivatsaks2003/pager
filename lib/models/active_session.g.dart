// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'active_session.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class ActiveSessionAdapter extends TypeAdapter<ActiveSession> {
  @override
  final int typeId = 2;

  @override
  ActiveSession read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return ActiveSession(
      orderId: fields[0] as String,
      customerName: fields[1] as String,
      phoneNumber: fields[2] as String,
      pagerNumber: fields[3] as int,
      createdAt: fields[5] as DateTime,
      status: fields[4] as String,
    );
  }

  @override
  void write(BinaryWriter writer, ActiveSession obj) {
    writer
      ..writeByte(6)
      ..writeByte(0)
      ..write(obj.orderId)
      ..writeByte(1)
      ..write(obj.customerName)
      ..writeByte(2)
      ..write(obj.phoneNumber)
      ..writeByte(3)
      ..write(obj.pagerNumber)
      ..writeByte(4)
      ..write(obj.status)
      ..writeByte(5)
      ..write(obj.createdAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ActiveSessionAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
