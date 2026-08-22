import 'package:flutter/material.dart';

class NotificationsPage extends StatelessWidget {
  const NotificationsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const _MessageState(
      icon: Icons.notifications_none_rounded,
      title: 'Notificações indisponíveis',
      message:
          'Esta área será ativada quando o backend disponibilizar as '
          'notificações exclusivas do entregador autenticado.',
    );
  }
}

class _MessageState extends StatelessWidget {
  const _MessageState({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => ListView(
    physics: const AlwaysScrollableScrollPhysics(),
    padding: const EdgeInsets.fromLTRB(36, 100, 36, 24),
    children: [
      Icon(icon, size: 50, color: const Color(0xFF858279)),
      const SizedBox(height: 14),
      Text(
        title,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
      ),
      const SizedBox(height: 6),
      Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Color(0xFF858279),
          fontSize: 12,
          height: 1.4,
        ),
      ),
    ],
  );
}
