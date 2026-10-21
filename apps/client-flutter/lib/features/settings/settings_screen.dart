import 'package:flutter/material.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/adaptive_app_shell.dart';
import '../../shared/widgets/glass_container.dart';

/// Réglages — thème instantané, langue, préférences.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.locale, required this.onLocaleChange});
  final Locale locale;
  final ValueChanged<Locale> onLocaleChange;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool notif = true;
  double limit = 50000;
  String risk = 'balanced';

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final isFr = widget.locale.languageCode == 'fr';
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(isFr ? 'Réglages' : 'Settings', style: AppFonts.title(size: 19, weight: FontWeight.w800)),
          const SizedBox(height: 14),

          // Thème instantané
          GlassContainer(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(p.isDark ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
                        size: 18, color: p.amber),
                    const SizedBox(width: 10),
                    Text(isFr ? 'Apparence' : 'Appearance',
                        style: AppFonts.title(size: 14, weight: FontWeight.w800)),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _themeCard(
                        p,
                        title: 'Obsidian Glow',
                        subtitle: 'Noir brillant',
                        selected: p.isDark,
                        onTap: () => ThemeScope.setMode(context, true),
                        icon: Icons.nightlight_round,
                        colors: [const Color(0xFF07090E), const Color(0xFF111623)],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _themeCard(
                        p,
                        title: 'Pure Crystal',
                        subtitle: 'Blanc pur',
                        selected: !p.isDark,
                        onTap: () => ThemeScope.setMode(context, false),
                        icon: Icons.wb_sunny,
                        colors: [const Color(0xFFF4F7FB), Colors.white],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Langue
          GlassContainer(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.language, size: 18, color: p.cyan),
                    const SizedBox(width: 10),
                    Text(isFr ? 'Langue' : 'Language',
                        style: AppFonts.title(size: 14, weight: FontWeight.w800)),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _langChip(p, 'Français', widget.locale.languageCode == 'fr',
                          () => widget.onLocaleChange(const Locale('fr'))),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _langChip(p, 'English', widget.locale.languageCode == 'en',
                          () => widget.onLocaleChange(const Locale('en'))),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Préférences
          GlassContainer(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.tune, size: 18, color: p.violet),
                    const SizedBox(width: 10),
                    Text(isFr ? 'Préférences' : 'Preferences',
                        style: AppFonts.title(size: 14, weight: FontWeight.w800)),
                  ],
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  value: notif,
                  onChanged: (v) => setState(() => notif = v),
                  contentPadding: EdgeInsets.zero,
                  title: Text(isFr ? 'Notifications picks du jour' : 'Daily picks notifications',
                      style: AppFonts.label(size: 13, weight: FontWeight.w600)),
                ),
                Text(isFr ? 'Profil de risque' : 'Risk profile',
                    style: AppFonts.label(size: 12, weight: FontWeight.w600, color: p.textSoft)),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _riskChip(p, isFr ? 'Prudent' : 'Safe', 'conservative', p.emerald),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _riskChip(p, isFr ? 'Équilibré' : 'Balanced', 'balanced', p.cyan),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _riskChip(p, isFr ? 'Dynamique' : 'Bold', 'aggressive', p.carmin),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(isFr ? 'Limite de mise (XOF)' : 'Stake limit (XOF)',
                    style: AppFonts.label(size: 12, weight: FontWeight.w600, color: p.textSoft)),
                Slider(
                  value: limit,
                  min: 5000,
                  max: 200000,
                  divisions: 20,
                  label: '${limit.toInt()}',
                  onChanged: (v) => setState(() => limit = v),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('5 000', style: AppFonts.caption(size: 10)),
                    Text('${limit.toInt()} XOF',
                        style: AppFonts.num(size: 12, weight: FontWeight.w800, color: p.cyan)),
                    Text('200 000', style: AppFonts.caption(size: 10)),
                  ],
                ),
              ],
            ),
          ),
          SizedBox(height: MediaQuery.of(context).size.width < 768 ? 100 : 24),
        ],
      ),
    );
  }

  Widget _themeCard(
    AppPalette p, {
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
    required IconData icon,
    required List<Color> colors,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? p.cyan : p.glassBorder,
            width: selected ? 1.8 : 1,
          ),
          boxShadow: selected
              ? [BoxShadow(color: p.cyan.withOpacity(0.25), blurRadius: 18)]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: title.contains('Obsidian') ? Colors.white : const Color(0xFF0F172A)),
            const SizedBox(height: 8),
            Text(title,
                style: AppFonts.title(
                  size: 12.5,
                  weight: FontWeight.w800,
                  color: title.contains('Obsidian') ? Colors.white : const Color(0xFF0F172A),
                )),
            Text(subtitle,
                style: AppFonts.caption(
                  size: 10,
                  color: title.contains('Obsidian') ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                )),
          ],
        ),
      ),
    );
  }

  Widget _langChip(AppPalette p, String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: selected ? p.cyan.withOpacity(0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: selected ? p.cyan.withOpacity(0.6) : p.glassBorder),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: AppFonts.label(size: 13, weight: FontWeight.w700, color: selected ? p.cyan : p.textSoft),
        ),
      ),
    );
  }

  Widget _riskChip(AppPalette p, String label, String value, Color color) {
    final selected = risk == value;
    return GestureDetector(
      onTap: () => setState(() => risk = value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          color: selected ? color.withOpacity(0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: selected ? color.withOpacity(0.6) : p.glassBorder),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: AppFonts.label(size: 11.5, weight: FontWeight.w700, color: selected ? color : p.textSoft),
        ),
      ),
    );
  }
}
