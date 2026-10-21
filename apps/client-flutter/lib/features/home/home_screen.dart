import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../widgets/ui_kit.dart';
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
        title: Text(isFr ? 'Accueil' : 'Home'),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 12),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(20),
            ),
            child: DropdownButton<Locale>(
              value: Localizations.localeOf(context),
              underline: const SizedBox(),
              icon: const Icon(Icons.language, size: 18, color: AppColors.primary),
              onChanged: (l){ if(l!=null) widget.onLocaleChange(l); },
              items: const [
                DropdownMenuItem(value: Locale('fr'), child: Text('FR', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5))),
                DropdownMenuItem(value: Locale('en'), child: Text('EN', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5))),
              ],
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Bandeau stats du jour
            SoftCard(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(child: StatTile(value: '76', label: isFr ? 'Picks du jour' : 'Picks today', color: AppColors.primary, leading: const IconBubble(icon: Icons.insights, size: 38, iconSize: 18))),
                  Container(width: 1, height: 36, color: AppColors.border),
                  Expanded(child: StatTile(value: '64', label: isFr ? 'Confiance moy.' : 'Avg. confidence', color: AppColors.green, leading: const IconBubble(icon: Icons.favorite, color: AppColors.red, size: 38, iconSize: 18))),
                  Container(width: 1, height: 36, color: AppColors.border),
                  Expanded(child: StatTile(value: '07:00', label: isFr ? 'Prochain scan' : 'Next scan', color: AppColors.orange, leading: const IconBubble(icon: Icons.schedule, color: AppColors.orange, size: 38, iconSize: 18))),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // Mode selector: Réel / Virtuel / Mix
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                PillChip(label: isFr ? 'Réel' : 'Real', icon: Icons.sports_soccer, selected: mode=='real_only', activeColor: AppColors.green, onTap: (){ setState((){ mode='real_only'; picksFuture=_fetchPicks(); }); }),
                PillChip(label: isFr ? 'Virtuel' : 'Virtual', icon: Icons.videogame_asset, selected: mode=='virtual_only', activeColor: AppColors.orange, onTap: (){ setState((){ mode='virtual_only'; picksFuture=_fetchPicks(); }); }),
                PillChip(label: 'Mix', icon: Icons.shuffle, selected: mode=='mix', onTap: (){ setState((){ mode='mix'; picksFuture=_fetchPicks(); }); }),
              ],
            ),
            const SizedBox(height: 14),
            FutureBuilder(
              future: picksFuture,
              builder: (ctx, snap) {
                if (!snap.hasData) return const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()));
                final picks = snap.data!;
                return Column(
                  children: picks.where((p){
                    if(mode=='real_only') return p['is_virtual']==false;
                    if(mode=='virtual_only') return p['is_virtual']==true;
                    return true;
                  }).map((item){
                    final pick = item['pick'] as Map<String,dynamic>;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(left: 4, bottom: 6),
                            child: Row(children:[
                              StatusBadge(
                                text: item['is_virtual'] ? (isFr ? 'Virtuel' : 'Virtual') : (isFr ? 'Réel' : 'Real'),
                                color: item['is_virtual'] ? AppColors.orange : AppColors.green,
                              ),
                              const SizedBox(width: 8),
                              Expanded(child: Text(item['event'], style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.ink))),
                            ]),
                          ),
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
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: () {},
              icon: const Icon(Icons.confirmation_number),
              label: Text(isFr ? 'Générer un coupon' : 'Generate coupon'),
            ),
          ],
        ),
      ),
    );
  }
}
