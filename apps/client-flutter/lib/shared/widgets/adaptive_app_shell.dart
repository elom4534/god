import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_theme.dart';
import '../widgets/glass_container.dart';

/// Coquille responsive intelligente (`LayoutBuilder`).
///
///  • < 768 px   : ergonomie une main, dock flottant en verre dépoli.
///  • ≥ 768 px   : barre latérale + zone centrale (tablette).
///  • ≥ 1200 px  : « Command Center » 3 colonnes (nav / contenu / analyse).
class AdaptiveAppShell extends StatelessWidget {
  const AdaptiveAppShell({
    super.key,
    required this.destinations,
    required this.index,
    required this.onIndex,
    required this.child,
    this.panel,
    this.onSearchChanged,
    this.searchHint,
  });

  final List<ShellDestination> destinations;
  final int index;
  final ValueChanged<int> onIndex;
  final Widget child;

  /// Panneau droit fixe (analyse du match sélectionné + alertes IA).
  final Widget? panel;
  final ValueChanged<String>? onSearchChanged;
  final String? searchHint;

  static const double mobileBreakpoint = 768;
  static const double wideBreakpoint = 1200;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        if (w < mobileBreakpoint) {
          return _MobileShell(
            destinations: destinations,
            index: index,
            onIndex: onIndex,
            child: child,
          );
        }
        if (w < wideBreakpoint) {
          return _TabletShell(
            destinations: destinations,
            index: index,
            onIndex: onIndex,
            child: child,
          );
        }
        return _CommandCenter(
          destinations: destinations,
          index: index,
          onIndex: onIndex,
          center: child,
          panel: panel,
          onSearchChanged: onSearchChanged,
          searchHint: searchHint,
        );
      },
    );
  }
}

class ShellDestination {
  const ShellDestination({required this.icon, required this.activeIcon, required this.label});
  final IconData icon;
  final IconData activeIcon;
  final String label;
}

// ------------------------------------------------------------- mobile ----

class _MobileShell extends StatelessWidget {
  const _MobileShell({
    required this.destinations,
    required this.index,
    required this.onIndex,
    required this.child,
  });

  final List<ShellDestination> destinations;
  final int index;
  final ValueChanged<int> onIndex;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          Positioned.fill(child: child),
          // Floating Glass Dock
          Positioned(
            left: 16,
            right: 16,
            bottom: 14,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(26),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: Container(
                  height: 66,
                  decoration: BoxDecoration(
                    color: p.glass.withOpacity(p.isDark ? 0.82 : 0.94),
                    borderRadius: BorderRadius.circular(26),
                    border: Border.all(color: p.glassBorder),
                    boxShadow: [
                      BoxShadow(
                        color: p.shadow.withOpacity(p.isDark ? 0.45 : 0.10),
                        blurRadius: 24,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Row(
                    children: List.generate(destinations.length, (i) {
                      final d = destinations[i];
                      final selected = i == index;
                      return Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => onIndex(i),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                padding: const EdgeInsets.all(7),
                                decoration: BoxDecoration(
                                  color: selected ? p.cyan.withOpacity(0.16) : Colors.transparent,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Icon(
                                  selected ? d.activeIcon : d.icon,
                                  size: 21,
                                  color: selected ? p.cyan : p.textSoft,
                                  shadows: selected
                                      ? [Shadow(color: p.cyan.withOpacity(0.6), blurRadius: 12)]
                                      : null,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                d.label,
                                maxLines: 1,
                                style: AppFonts.caption(
                                  size: 9.5,
                                  color: selected ? p.cyan : p.textSoft,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------- tablette --

class _TabletShell extends StatelessWidget {
  const _TabletShell({
    required this.destinations,
    required this.index,
    required this.onIndex,
    required this.child,
  });

  final List<ShellDestination> destinations;
  final int index;
  final ValueChanged<int> onIndex;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Row(
        children: [
          Container(
            width: 88,
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Column(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [p.cyan, p.violet]),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.radar, color: Colors.white, size: 22),
                ),
                const SizedBox(height: 22),
                Expanded(
                  child: Column(
                    children: List.generate(destinations.length, (i) {
                      final d = destinations[i];
                      final selected = i == index;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: GestureDetector(
                          onTap: () => onIndex(i),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                            decoration: BoxDecoration(
                              color: selected ? p.cyan.withOpacity(0.12) : Colors.transparent,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: selected ? p.cyan.withOpacity(0.35) : Colors.transparent,
                              ),
                            ),
                            child: Column(
                              children: [
                                Icon(
                                  selected ? d.activeIcon : d.icon,
                                  size: 22,
                                  color: selected ? p.cyan : p.textSoft,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  d.label,
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  style: AppFonts.caption(
                                    size: 9.5,
                                    color: selected ? p.cyan : p.textSoft,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }),
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

// ------------------------------------------------------ command center ---

class _CommandCenter extends StatelessWidget {
  const _CommandCenter({
    required this.destinations,
    required this.index,
    required this.onIndex,
    required this.center,
    this.panel,
    this.onSearchChanged,
    this.searchHint,
  });

  final List<ShellDestination> destinations;
  final int index;
  final ValueChanged<int> onIndex;
  final Widget center;
  final Widget? panel;
  final ValueChanged<String>? onSearchChanged;
  final String? searchHint;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Row(
        children: [
          // — Colonne gauche : navigation, recherche, ligues, thème —
          SizedBox(
            width: 264,
            child: GlassContainer(
              margin: const EdgeInsets.fromLTRB(16, 16, 8, 16),
              padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(colors: [p.cyan, p.violet]),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Icon(Icons.radar, color: Colors.white, size: 22),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('PRED RADAR',
                                style: AppFonts.title(size: 15, weight: FontWeight.w800, color: p.textStrong)),
                            Text('Command Center',
                                style: AppFonts.caption(size: 10, color: p.textSoft)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (onSearchChanged != null)
                    TextField(
                      onChanged: onSearchChanged,
                      style: AppFonts.label(size: 12.5, color: p.textStrong),
                      decoration: InputDecoration(
                        hintText: searchHint ?? 'Rechercher une ligue, une équipe…',
                        hintStyle: AppFonts.caption(size: 11.5, color: p.textSoft),
                        prefixIcon: const Icon(Icons.search, size: 18),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      ),
                    ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: ListView(
                      children: List.generate(destinations.length, (i) {
                        final d = destinations[i];
                        final selected = i == index;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: _HoverableNavTile(
                            selected: selected,
                            onTap: () => onIndex(i),
                            icon: selected ? d.activeIcon : d.icon,
                            label: d.label,
                          ),
                        );
                      }),
                    ),
                  ),
                  const _ThemeSwitchTile(),
                ],
              ),
            ),
          ),
          // — Colonne centrale —
          Expanded(child: center),
          // — Colonne droite : analyse + alertes IA —
          if (panel != null)
            SizedBox(
              width: 384,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 16, 16, 16),
                child: panel,
              ),
            ),
        ],
      ),
    );
  }
}

class _HoverableNavTile extends StatefulWidget {
  const _HoverableNavTile({
    required this.selected,
    required this.onTap,
    required this.icon,
    required this.label,
  });

  final bool selected;
  final VoidCallback onTap;
  final IconData icon;
  final String label;

  @override
  State<_HoverableNavTile> createState() => _HoverableNavTileState();
}

class _HoverableNavTileState extends State<_HoverableNavTile> {
  double _hover = 0;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = widget.selected ? p.cyan : p.textSoft;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = 1),
      onExit: (_) => setState(() => _hover = 0),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: widget.selected
                ? p.cyan.withOpacity(0.12)
                : p.cyan.withOpacity(0.04 * _hover),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: widget.selected
                  ? p.cyan.withOpacity(0.35)
                  : Color.lerp(p.glassBorder, p.cyan, _hover * 0.35)!,
            ),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 19, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.label,
                  style: AppFonts.label(size: 13, weight: FontWeight.w700, color: color),
                ),
              ),
              if (widget.selected)
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(color: p.cyan, shape: BoxShape.circle, boxShadow: [
                    BoxShadow(color: p.cyan.withOpacity(0.8), blurRadius: 8),
                  ]),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThemeSwitchTile extends StatelessWidget {
  const _ThemeSwitchTile();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: p.cyan.withOpacity(0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.glassBorder),
      ),
      child: Row(
        children: [
          Icon(p.isDark ? Icons.dark_mode_outlined : Icons.light_mode_outlined, size: 18, color: p.amber),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              p.isDark ? 'Obsidian Glow' : 'Pure Crystal',
              style: AppFonts.label(size: 12, weight: FontWeight.w700, color: p.textStrong),
            ),
          ),
          const _ThemeToggleButton(),
        ],
      ),
    );
  }
}

/// Bouton de bascule de thème — accès direct depuis n'importe quel shell
/// via `ThemeScope.of(context)`.
class _ThemeToggleButton extends StatelessWidget {
  const _ThemeToggleButton();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return GestureDetector(
      onTap: () => ThemeScope.toggle(context),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        width: 52,
        height: 28,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: p.isDark ? p.violet.withOpacity(0.35) : p.cyan.withOpacity(0.3),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: (p.isDark ? p.violet : p.cyan).withOpacity(0.5)),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: p.isDark ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: p.isDark ? p.violet : p.cyan,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: (p.isDark ? p.violet : p.cyan).withOpacity(0.7),
                  blurRadius: 10,
                ),
              ],
            ),
            child: Icon(
              p.isDark ? Icons.nightlight_round : Icons.wb_sunny,
              size: 13,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

/// Accès au contrôleur de thème depuis l'arbre.
class ThemeScope extends InheritedWidget {
  const ThemeScope({super.key, required this.controller, required super.child});

  final dynamic controller; // ThemeController

  static void toggle(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ThemeScope>();
    scope?.controller.toggle();
  }

  /// Bascule instantanée vers le thème demandé (sans redémarrage).
  static void setMode(BuildContext context, bool dark) {
    final scope = context.dependOnInheritedWidgetOfExactType<ThemeScope>();
    scope?.controller.setMode(dark ? ThemeMode.dark : ThemeMode.light);
  }

  @override
  bool updateShouldNotify(ThemeScope oldWidget) => oldWidget.controller != controller;
}
