import 'package:flutter/material.dart';
import '../../widgets/responsible_gambling_banner.dart';
import '../../widgets/probability_card.dart';

class HomeScreen extends StatefulWidget {
  final Function(Locale) onLocaleChange;
  const HomeScreen({super.key, required this.onLocaleChange});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String mode = 'mix';
  late Future<List<Map<String,dynamic>>> picksFuture;

  @override
  void initState() {
    super.initState();
    picksFuture = _fetchPicks();
  }

  Future<List<Map<String,dynamic>>> _fetchPicks() async {
    // Mock data — en prod: appel GET /picks/today + /events/today
    await Future.delayed(Duration(milliseconds: 300));
    return [
      {
        'event': 'Arsenal vs Man City — Premier League — 20/10 19:45',
        'is_virtual': false,
        'pick': {'title':'Over 2.5','p_lower':0.54,'p_model':0.61,'confidence':'MEDIUM','factors':[{'name':'elo_diff','impact':'+0.04'},{'name':'form_home','impact':'+0.02'}]},
        'event_id':'evt_123'
      },
      {
        'event': 'Virtual Match 42 — Virtual Liga — 20/10 20:00',
        'is_virtual': true,
        'pick': {'title':'BTTS Yes','p_lower':0.51,'p_model':0.58,'confidence':'LOW','factors':[{'name':'virtual_drift','impact':'-0.02'}]},
        'event_id':'virt_42'
      },
      {
        'event': 'Barça vs Real — La Liga — 20/10 20:00',
        'is_virtual': false,
        'pick': {'title':'BTTS Yes','p_lower':0.52,'p_model':0.59,'confidence':'MEDIUM','factors':[{'name':'xG_trend','impact':'+0.03'}]},
        'event_id':'evt_124'
      },
    ];
  }

  @override
  Widget build(BuildContext context) {
    final isFr = Localizations.localeOf(context).languageCode == 'fr';
    return Scaffold(
      appBar: AppBar(
        title: Text('Pred — ${isFr ? "Prédictions calibrées" : "Calibrated Predictions"}'),
        actions: [
          DropdownButton<Locale>(
            value: Localizations.localeOf(context),
            underline: SizedBox(),
            icon: Icon(Icons.language),
            onChanged: (l){ if(l!=null) widget.onLocaleChange(l); },
            items: [
              DropdownMenuItem(value: Locale('fr'), child: Text('FR')),
              DropdownMenuItem(value: Locale('en'), child: Text('EN')),
            ],
          ),
          SizedBox(width: 8),
        ],
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ResponsibleGamblingBanner(),
            SizedBox(height: 12),
            // Mode selector: Réel / Virtuel / Mix
            SegmentedButton<String>(
              segments: [
                ButtonSegment(value:'real_only', label: Text(isFr ? 'Réel' : 'Real'), icon: Icon(Icons.sports_soccer)),
                ButtonSegment(value:'virtual_only', label: Text(isFr ? 'Virtuel' : 'Virtual'), icon: Icon(Icons.videogame_asset)),
                ButtonSegment(value:'mix', label: Text('Mix'), icon: Icon(Icons.shuffle)),
              ],
              selected: {mode},
              onSelectionChanged: (v){ setState((){ mode=v.first; picksFuture=_fetchPicks(); }); },
            ),
            SizedBox(height: 8),
            Text(isFr ? 'Tous les picks affichent la borne basse prudente (p_lower) et la confiance. Jamais de cotes.' : 'All picks show conservative lower bound (p_lower) and confidence. No odds ever.', style: TextStyle(fontSize: 12, color: Colors.grey)),
            SizedBox(height: 12),
            // Picks du jour (pré-calculés, cache Redis)
            FutureBuilder(
              future: picksFuture,
              builder: (ctx, snap) {
                if (!snap.hasData) return Center(child: CircularProgressIndicator());
                final picks = snap.data!;
                return Column(
                  children: picks.where((p){
                    if(mode=='real_only') return p['is_virtual']==false;
                    if(mode=='virtual_only') return p['is_virtual']==true;
                    return true;
                  }).map((item){
                    final pick = item['pick'] as Map<String,dynamic>;
                    return Padding(
                      padding: EdgeInsets.only(bottom: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(children:[Chip(label: Text(item['is_virtual'] ? 'Virtuel' : 'Réel', style: TextStyle(fontSize:10)), visualDensity: VisualDensity.compact), SizedBox(width: 8), Expanded(child: Text(item['event'], style: TextStyle(fontSize:12, fontWeight: FontWeight.w600)))]),
                          ProbabilityCard(
                            title: pick['title'],
                            pLower: pick['p_lower'],
                            pModel: pick['p_model'],
                            confidence: pick['confidence'],
                            factors: (pick['factors'] as List).cast<Map<String,String>>(),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                );
              },
            ),
            SizedBox(height: 16),
            FilledButton.icon(
              onPressed: ()=> Navigator.push(context, MaterialPageRoute(builder: (_)=> Placeholder())),
              icon: Icon(Icons.confirmation_number),
              label: Text(isFr ? 'Générer un coupon (sans cotes)' : 'Generate coupon (no odds)'),
            ),
            SizedBox(height: 8),
            Text(isFr ? 'Fail-closed: si info incertaine (marge >5% ou drift), aucun pick proposé.' : 'Fail-closed: if uncertain (margin >5% or drift), no pick is suggested.', style: TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}
