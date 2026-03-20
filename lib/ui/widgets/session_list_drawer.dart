import 'package:flutter/material.dart';
import '../../models/conversation_session.dart';
import '../../services/conversation_store.dart';

/// Drawer widget showing list of conversation sessions
class SessionListDrawer extends StatelessWidget {
  final ConversationStore conversationStore;
  final VoidCallback onSessionChanged;

  const SessionListDrawer({
    super.key,
    required this.conversationStore,
    required this.onSessionChanged,
  });

  @override
  Widget build(BuildContext context) {
    final sessions = conversationStore.allSessions;
    final activeSessionId = conversationStore.activeSessionId;

    return Drawer(
      child: Column(
        children: [
          // New Chat Button
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 56, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () async {
                  await conversationStore.createNewSession();
                  onSessionChanged();
                  if (context.mounted) {
                    Navigator.pop(context);
                  }
                },
                icon: const Icon(Icons.add),
                label: const Text('New Chat'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ),

          const Divider(height: 1),

          // Sessions List
          Expanded(
            child: sessions.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.chat_bubble_outline,
                          size: 48,
                          color: Colors.grey.shade400,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No conversations yet',
                          style: TextStyle(
                            fontSize: 16,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: sessions.length,
                    itemBuilder: (context, index) {
                      final session = sessions[index];
                      final isActive = session.id == activeSessionId;

                      return _SessionListItem(
                        session: session,
                        isActive: isActive,
                        onTap: () async {
                          if (!isActive) {
                            await conversationStore.switchToSession(session.id);
                            onSessionChanged();
                          }
                          if (context.mounted) {
                            Navigator.pop(context);
                          }
                        },
                        onDelete: () async {
                          await conversationStore.deleteSession(session.id);
                          onSessionChanged();
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Individual session list item
class _SessionListItem extends StatelessWidget {
  final ConversationSession session;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _SessionListItem({
    required this.session,
    required this.isActive,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: Key(session.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.red,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (direction) async {
        // Confirm deletion
        return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Delete Conversation'),
            content: const Text('Are you sure you want to delete this conversation? This cannot be undone.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.red,
                ),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
      },
      onDismissed: (_) => onDelete(),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: isActive ? Colors.blue : Colors.grey.shade300,
          child: Icon(
            isActive ? Icons.check : Icons.chat_bubble_outline,
            color: isActive ? Colors.white : Colors.grey.shade600,
            size: 20,
          ),
        ),
        title: Text(
          session.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text(
              session.preview,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              session.displayTime,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade500,
              ),
            ),
          ],
        ),
        onTap: onTap,
        selected: isActive,
        selectedTileColor: Colors.blue.shade50,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        trailing: isActive
            ? null
            : IconButton(
                icon: Icon(Icons.delete_outline, color: Colors.grey.shade600),
                onPressed: () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Delete Conversation'),
                      content: const Text('Are you sure you want to delete this conversation? This cannot be undone.'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.red,
                          ),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    onDelete();
                  }
                },
              ),
      ),
    );
  }
}
