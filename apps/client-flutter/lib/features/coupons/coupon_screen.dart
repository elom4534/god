import 'package:flutter/material.dart';
import 'custom_coupon_screen.dart';

class CouponScreen extends StatefulWidget {
  const CouponScreen({super.key});
  @override
  State<CouponScreen> createState() => _CouponScreenState();
}

class _CouponScreenState extends State<CouponScreen> {
  String mode = 'mix';
  String format = 'COMBINE';
  int k=2, n=3;
  bool loading=false;
  Map<String,dynamic>? draft;

  Future<void> generate() async {
    setState(()=> loading=true);
    await Future.delayed(Duration(seconds: 1));
    // Mock draft
    setState((){
      draft = {
        'draft_id': 'draft_abc123',
        'mode': mode,
        'format': format=='SYSTEM' ? 'SYSTEM_${k}_${n}' : format,
        'selections': [
          {'event':'Arsenal vs Chelsea','pick':'Over 2.5','p_lower':0.54,'confidence':'MEDIUM'},
          {'event':'Barça vs Real','pick':'BTTS Yes','p_lower':0.52,'confidence':'MEDIUM'},
          {'event':'Virt 42','pick':'Over 2.5','p_lower':0.50,'confidence':'LOW'},
        ],
        'warnings': ['MIX_VIRTUAL_REAL'],
        'expires_at': DateTime.now().add(Duration(minutes:5)).toIso8601String(),
      };
      loading=false;
    });
  }

  Future<void> place() async {
    setState(()=> loading=true);
    await Future.delayed(Duration(seconds: 1));
    // Mock
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Coupon placé (mock) — ticket tkt_${DateTime.now().millisecondsSinceEpoch}')));
    setState(()=> loading=false);
  }

  @override
  Widget build(BuildContext context) {
    final isFr = Localizations.localeOf(context).languageCode=='fr';
    return Scaffold(
      appBar: AppBar(title: Text(isFr ? 'Générateur de coupons' : 'Coupon Generator')),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(isFr ? '1. Choisis le mode' : '1. Choose mode', style: TextStyle(fontWeight: FontWeight.bold)),
            SegmentedButton<String>(
              segments: [
                ButtonSegment(value:'real_only', label: Text(isFr ? 'Réel' : 'Real')),
                ButtonSegment(value:'virtual_only', label: Text(isFr ? 'Virtuel' : 'Virtual')),
                ButtonSegment(value:'mix', label: Text('Mix')),
              ],
              selected: {mode},
              onSelectionChanged: (v)=> setState(()=> mode=v.first),
            ),
            SizedBox(height: 12),
            Text(isFr ? '2. Format' : '2. Format', style: TextStyle(fontWeight: FontWeight.bold)),
            SegmentedButton<String>(
              segments: [
                ButtonSegment(value:'SINGLE', label: Text('Singles')),
                ButtonSegment(value:'COMBINE', label: Text(isFr ? 'Combiné' : 'Accumulator')),
                ButtonSegment(value:'SYSTEM', label: Text('Système')),
              ],
              selected: {format},
              onSelectionChanged: (v)=> setState(()=> format=v.first),
            ),
            if(format=='SYSTEM') Row(children:[
              Expanded(child: DropdownButtonFormField<int>(value:k, items:[2,3,4].map((e)=>DropdownMenuItem(value:e, child:Text('k=$e'))).toList(), onChanged:(v)=>setState(()=>k=v!))),
              SizedBox(width:8),
              Expanded(child: DropdownButtonFormField<int>(value:n, items:[3,4,5].map((e)=>DropdownMenuItem(value:e, child:Text('n=$e'))).toList(), onChanged:(v)=>setState(()=>n=v!))),
            ]),
            SizedBox(height: 16),
            FilledButton(onPressed: loading?null:generate, child: loading? CircularProgressIndicator(color:Colors.white): Text(isFr ? 'Générer le draft' : 'Generate draft')),
            if(draft!=null) ...[
              SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Draft ${draft!['draft_id']} — ${draft!['format']} — ${draft!['mode']}', style: TextStyle(fontWeight: FontWeight.bold)),
                      Text('Expire: ${draft!['expires_at']}', style: TextStyle(fontSize:11, color:Colors.grey)),
                      Divider(),
                      ...((draft!['selections'] as List).map((s)=> ListTile(
                        dense:true,
                        title: Text('${s['event']}'),
                        subtitle: Text('${s['pick']} — ${(s['p_lower']*100).toStringAsFixed(1)}%'),
                        trailing: Icon(Icons.check_circle, color:Colors.green),
                      ))),
                      SizedBox(height:12),
                      FilledButton.icon(onPressed: place, icon: Icon(Icons.send), label: Text(isFr ? 'Placer le coupon' : 'Place coupon')),
            SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CustomCouponScreen())),
              icon: Icon(Icons.auto_awesome),
              label: Text(isFr ? 'Combiné sur mesure (nombre de matchs + côte cible)' : 'Custom accumulator (matches + target odds)'),
            ),
                    ],
                  ),
                ),
              ),
            ]
          ],
        ),
      ),
    );
  }
}
