import 'package:hive/hive.dart';

part 'pager_device.g.dart';

@HiveType(typeId: 1)
class PagerDevice extends HiveObject {
  @HiveField(0)
  final String macAddress;

  @HiveField(1)
  final int pagerNumber;

  @HiveField(2)
  bool isAssigned;

  PagerDevice({
    required this.macAddress,
    required this.pagerNumber,
    this.isAssigned = false,
  });
}
