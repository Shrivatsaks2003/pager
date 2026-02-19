// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'pager_device.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class PagerDeviceAdapter extends TypeAdapter<PagerDevice> {
  @override
  final int typeId = 1;

  @override
  PagerDevice read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return PagerDevice(
      macAddress: fields[0] as String,
      pagerNumber: fields[1] as int,
      isAssigned: fields[2] as bool,
    );
  }

  @override
  void write(BinaryWriter writer, PagerDevice obj) {
    writer
      ..writeByte(3)
      ..writeByte(0)
      ..write(obj.macAddress)
      ..writeByte(1)
      ..write(obj.pagerNumber)
      ..writeByte(2)
      ..write(obj.isAssigned);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PagerDeviceAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
