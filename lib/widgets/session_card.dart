import 'package:flutter/material.dart';
import '../models/active_session.dart';

class SessionCard extends StatelessWidget {
  final ActiveSession session;
  final VoidCallback onDelete;
  final VoidCallback onStatusChange;
  final ValueChanged<String> onPreparingAction;

  const SessionCard({
    super.key,
    required this.session,
    required this.onDelete,
    required this.onStatusChange,
    required this.onPreparingAction,
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
    final colors = Theme.of(context).colorScheme;
    final statusColor = _statusColor(session.status);

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  "Order #${session.orderId}",
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    session.status.toUpperCase(),
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              "Customer: ${session.customerName}",
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
            Text(
              "Phone: ${session.phoneNumber}",
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
            Text(
              "Pager: ${session.pagerNumber}",
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 16),

            Row(
              children: [
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: statusColor,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                  ),
                  onPressed: next == null
                      ? null
                      : () {
                          session.status = next;
                          session.save();
                          onStatusChange();
                        },
                  child: Text(
                    next == null ? "COMPLETED" : "MARK ${next.toUpperCase()}",
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                if (session.status == "preparing") ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Wrap(
                      spacing: 6,
                      children: ["A", "B", "C", "D", "E"]
                          .map(
                            (code) => OutlinedButton(
                              onPressed: () => onPreparingAction(code),
                              style: OutlinedButton.styleFrom(
                                side: BorderSide(color: colors.outlineVariant),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                              ),
                              child: Text(
                                code,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ],
                const Spacer(),
                IconButton(
                  icon: Icon(Icons.delete_outline_rounded, color: colors.error),
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
