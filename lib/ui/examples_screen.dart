import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/tip_of_day.dart';
import '../services/reminders.dart';

const _categories = [
  _Category(
    icon: Icons.calendar_today_rounded,
    color: Color(0xFF5C6BC0),
    label: 'Calendar & Reminders',
    tips: [
      "What's on my calendar today?",
      "What's my next meeting?",
      "Add a reminder for tomorrow at 9am",
      "What are my upcoming reminders?",
    ],
  ),
  _Category(
    icon: Icons.email_rounded,
    color: Color(0xFF26A69A),
    label: 'Email',
    tips: [
      "Read my latest emails",
      "Read me the email from Sarah",
      "Find emails from my boss this week",
    ],
  ),
  _Category(
    icon: Icons.navigation_rounded,
    color: Color(0xFF42A5F5),
    label: 'Navigation & Traffic',
    tips: [
      "How long to get to work?",
      "Navigate to the nearest gas station",
      "What's the traffic like on my route?",
      "Navigate home",
    ],
  ),
  _Category(
    icon: Icons.people_rounded,
    color: Color(0xFFEF5350),
    label: 'Follow Up Boss',
    tips: [
      "Show me my hot leads in Follow Up Boss",
      "What leads came in today?",
      "Add a note to John Smith's contact in FUB",
      "Who are my leads with no activity this week?",
      "What's the status of my pipeline?",
      "Search for lead Maria Garcia in FUB",
    ],
  ),
  _Category(
    icon: Icons.phone_rounded,
    color: Color(0xFF66BB6A),
    label: 'Calls & Messages',
    tips: [
      "Call John",
      "Text Sarah I'm on my way",
    ],
  ),
  _Category(
    icon: Icons.psychology_rounded,
    color: Color(0xFFFF7043),
    label: 'Memory & Preferences',
    tips: [
      "Remember that I prefer highway routes",
      "What did you remember about me?",
    ],
  ),
  _Category(
    icon: Icons.search_rounded,
    color: Color(0xFFAB47BC),
    label: 'Web & YouTube',
    tips: [
      "Search the web for latest mortgage rates",
      "Open YouTube and play jazz music",
      "What's the weather like today?",
      "What time is it in New York?",
    ],
  ),
];

class _Category {
  final IconData icon;
  final Color color;
  final String label;
  final List<String> tips;
  const _Category({
    required this.icon,
    required this.color,
    required this.label,
    required this.tips,
  });
}

class ExamplesScreen extends StatefulWidget {
  const ExamplesScreen({super.key});

  @override
  State<ExamplesScreen> createState() => _ExamplesScreenState();
}

class _ExamplesScreenState extends State<ExamplesScreen> {
  bool _tipEnabled = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _tipEnabled = prefs.getBool('tip_of_day_enabled') ?? true;
    });
  }

  Future<void> _setTipEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('tip_of_day_enabled', value);
    setState(() => _tipEnabled = value);
    if (!value) {
      final oldId = prefs.getInt('tip_of_day_reminder_id');
      if (oldId != null) {
        try { await RemindersService.instance.cancelReminder(oldId); } catch (_) {}
        await prefs.remove('tip_of_day_reminder_id');
        await prefs.remove('tip_of_day_scheduled_date');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Example Commands')),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          // Daily tip toggle card
          Card(
            elevation: 0,
            color: scheme.surfaceContainerHighest.withOpacity(0.5),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            child: SwitchListTile(
              secondary: Icon(Icons.lightbulb_rounded,
                  color: _tipEnabled ? Colors.amber[600] : Colors.grey),
              title: const Text('Daily Tip Notification',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text('A command example every morning at 7am'),
              value: _tipEnabled,
              onChanged: _setTipEnabled,
            ),
          ),
          const SizedBox(height: 20),

          const Text(
            'THINGS YOU CAN SAY',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Colors.black45,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 12),

          ..._categories.map((cat) => _CategoryCard(category: cat)),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _CategoryCard extends StatefulWidget {
  const _CategoryCard({required this.category});
  final _Category category;

  @override
  State<_CategoryCard> createState() => _CategoryCardState();
}

class _CategoryCardState extends State<_CategoryCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final cat = widget.category;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            // Header row
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: cat.color.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(cat.icon, color: cat.color, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(cat.label,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 15)),
                    ),
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: const Icon(Icons.keyboard_arrow_down_rounded,
                          color: Colors.black38),
                    ),
                  ],
                ),
              ),
            ),
            // Tips list
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeInOut,
              child: _expanded
                  ? Column(
                      children: [
                        const Divider(height: 1),
                        ...cat.tips.map((tip) => _TipRow(tip: tip, color: cat.color)),
                        const SizedBox(height: 6),
                      ],
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

class _TipRow extends StatelessWidget {
  const _TipRow({required this.tip, required this.color});
  final String tip;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Icon(Icons.mic_rounded, size: 14, color: color.withOpacity(0.7)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '"$tip"',
              style: TextStyle(
                fontSize: 13.5,
                color: Colors.black87,
                fontStyle: FontStyle.italic,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
