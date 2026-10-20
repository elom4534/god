import 'package:flutter/material.dart';
import '../../widgets/responsible_gambling_banner.dart';

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
      appBar: AppBar(title: Text(isFr ? 'Paramètres' : 'Settings')),
      body: ListView(
        padding: EdgeInsets.all(16),
        children:[
          DropdownButtonFormField<Locale>(
            value: widget.currentLocale,
            decoration: InputDecoration(labelText: isFr ? 'Langue' : 'Language', border: OutlineInputBorder()),
            items: [DropdownMenuItem(value: Locale('fr'), child: Text('Français')), DropdownMenuItem(value: Locale('en'), child: Text('English'))],
            onChanged: (l){ if(l!=null) widget.onLocaleChange(l); },
          ),
          SizedBox(height:12),
          DropdownButtonFormField<String>(
            value: country,
            decoration: InputDecoration(labelText: isFr ? 'Pays (Country Policy Gate)' : 'Country', border: OutlineInputBorder(), helperText: 'fail-closed si non autorisé → blocage création coupon'),
            items: ['TG','BJ','CI','FR','BE','US'].map((c)=>DropdownMenuItem(value:c, child:Text(c))).toList(),
            onChanged:(v)=>setState(()=>country=v!),
          ),
          SizedBox(height:12),
          DropdownButtonFormField<String>(
            value: risk,
            decoration: InputDecoration(labelText: isFr ? 'Profil risque' : 'Risk profile', border: OutlineInputBorder()),
            items: ['conservative','balanced','aggressive'].map((e)=>DropdownMenuItem(value:e, child:Text(e))).toList(),
            onChanged:(v)=>setState(()=>risk=v!),
          ),
          SwitchListTile(value: notif, onChanged:(v)=>setState(()=>notif=v), title: Text(isFr ? 'Notifications picks du jour' : 'Daily picks notifications')),
          SizedBox(height:12),
          Text(isFr ? 'Limite jeu responsable (XOF)' : 'Responsible gambling limit (XOF)'),
          Slider(value: limit, min: 5000, max: 200000, divisions: 20, label: '${limit.toInt()}', onChanged:(v)=>setState(()=>limit=v)),
          SizedBox(height:12),
          ResponsibleGamblingBanner(),
          SizedBox(height:12),
          Text('Country Policy Gate: ${country} — ${['TG','BJ','CI','FR','BE'].contains(country) ? (isFr ? 'Autorisé' : 'Allowed') : (isFr ? 'Bloqué (fail-closed)' : 'Blocked (fail-closed)')}',
            style: TextStyle(color: ['TG','BJ','CI','FR','BE'].contains(country) ? Colors.green : Colors.red, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
