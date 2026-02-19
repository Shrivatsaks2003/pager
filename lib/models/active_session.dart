import 'package:hive/hive.dart';

part 'active_session.g.dart';

@HiveType(typeId: 2)
class ActiveSession extends HiveObject {
  @HiveField(0)
  final String orderId;

  @HiveField(1)
  final String customerName;

  @HiveField(2)
  final String phoneNumber;

  @HiveField(3)
  final int pagerNumber;

  @HiveField(4)
  String status;

  @HiveField(5)
  final DateTime createdAt;

  ActiveSession({
    required this.orderId,
    required this.customerName,
    required this.phoneNumber,
    required this.pagerNumber,
    required this.createdAt,
    this.status = "start",
  });
}
