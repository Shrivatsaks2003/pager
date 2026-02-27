import 'package:flutter/material.dart';
import '../models/active_session.dart';

class SessionCard extends StatelessWidget {
  final ActiveSession session;
  final VoidCallback onDelete;
  final VoidCallback onStatusChange;
  final VoidCallback onRingAlert;

  const SessionCard({
    super.key,
    required this.session,
    required this.onDelete,
    required this.onStatusChange,
    required this.onRingAlert,
  });

  Color _statusColor(String status) {
    switch (status) {
      case "start":
        return Colors.blue;
      case "preparing":
        return Colors.orange;
      case "ready":
        return Colors.green;
      case "delivered":
        return Colors.grey;
      default:
        return Colors.blue;
    }
  }

  String? _nextStatus(String status) {
    switch (status) {
      case "start":
        return "preparing";
      case "preparing":
        return "ready";
      case "ready":
        return "delivered";
      case "delivered":
        return null; // final state
      default:
        return "start";
    }
  }

  @override
  Widget build(BuildContext context) {
    final next = _nextStatus(session.status);

    return Card(
      elevation: 3,
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Order #${session.orderId}",
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text("Customer: ${session.customerName}"),
            Text("Phone: ${session.phoneNumber}"),
            Text("Pager: ${session.pagerNumber}"),
            const SizedBox(height: 16),

            Row(
              children: [
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _statusColor(session.status),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 12),
                  ),
                  onPressed: next == null
                      ? null
                      : () {
                          session.status = next;
                          session.save();
                          onStatusChange();
                        },
                  child: Text(
                    session.status.toUpperCase(),
                    style: const TextStyle(
                        fontWeight: FontWeight.bold),
                  ),
                ),
                if (session.status == "preparing") ...[
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: onRingAlert,
                    icon: const Icon(Icons.notifications_active),
                    label: const Text("Ring"),
                  ),
                ],
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.delete),
                  onPressed: onDelete,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
