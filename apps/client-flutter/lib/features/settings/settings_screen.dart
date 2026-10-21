import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../widgets/ui_kit.dart';

class SettingsScreen extends StatefulWidget {
  final Locale currentLocale;
  final Function(Locale) onLocaleChange;
  const SettingsScreen({super.key, required this.currentLocale, required this.onLocaleChange});
  @override
  State<SettingsScreen> createState()=> _SettingsState();
}
class _SettingsState extends State<SettingsScreen>{
  String country='TG';
  String risk='conservative';
  bool notif=true;
  double limit=50000;

  @override
  Widget build(BuildContext context){
    final isFr = widget.currentLocale.languageCode=='fr';
    return Scaffold(
      appBar: AppBar(title: Text(isFr ? 'Réglages' : 'Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children:[
          SoftCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const IconBubble(icon: Icons.language, size: 36, iconSize: 17),
                  const SizedBox(width: 10),
                  Text(isFr ? 'Langue' : 'Language', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.ink)),
                ]),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [
                    PillChip(label: 'Français', selected: widget.currentLocale.languageCode=='fr', onTap: () => widget.onLocaleChange(const Locale('fr'))),
                    PillChip(label: 'English', selected: widget.currentLocale.languageCode=='en', onTap: () => widget.onLocaleChange(const Locale('en'))),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SoftCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const IconBubble(icon: Icons.public, color: AppColors.green, size: 36, iconSize: 17),
                  const SizedBox(width: 10),
                  Text(isFr ? 'Pays' : 'Country', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.ink)),
                ]),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: ['TG','BJ','CI','FR','BE','US'].map((c) => PillChip(
                    label: c,
                    selected: country==c,
                    activeColor: AppColors.green,
                    onTap: () => setState(() => country=c),
                  )).toList(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SoftCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const IconBubble(icon: Icons.tune, color: AppColors.orange, size: 36, iconSize: 17),
                  const SizedBox(width: 10),
                  Text(isFr ? 'Profil de risque' : 'Risk profile', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.ink)),
                ]),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    PillChip(label: isFr ? 'Prudent' : 'Conservative', selected: risk=='conservative', activeColor: AppColors.green, onTap: () => setState(() => risk='conservative')),
                    PillChip(label: isFr ? 'Équilibré' : 'Balanced', selected: risk=='balanced', activeColor: AppColors.yellow, onTap: () => setState(() => risk='balanced')),
                    PillChip(label: isFr ? 'Dynamique' : 'Aggressive', selected: risk=='aggressive', activeColor: AppColors.red, onTap: () => setState(() => risk='aggressive')),
                  ],
                ),
                const Divider(height: 24),
                SwitchListTile(
                  value: notif,
                  onChanged:(v)=>setState(()=>notif=v),
                  title: Text(isFr ? 'Notifications picks du jour' : 'Daily picks notifications', style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: AppColors.ink)),
                  contentPadding: EdgeInsets.zero,
                  activeColor: AppColors.primary,
                ),
                const SizedBox(height: 4),
                Text(isFr ? 'Limite de mise (XOF)' : 'Stake limit (XOF)', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.ink)),
                Slider(
                  value: limit,
                  min: 5000,
                  max: 200000,
                  divisions: 20,
                  label: '${limit.toInt()}',
                  activeColor: AppColors.primary,
                  inactiveColor: AppColors.primarySoft,
                  onChanged:(v)=>setState(()=>limit=v),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('5 000', style: const TextStyle(fontSize: 10.5, color: AppColors.muted)),
                    Text('${limit.toInt()} XOF', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: AppColors.primary)),
                    Text('200 000', style: const TextStyle(fontSize: 10.5, color: AppColors.muted)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
