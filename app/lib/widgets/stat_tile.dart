import 'package:flutter/material.dart';

/// Data for a single gradient stat tile. Pass to [StatStrip].
class StatTileData {
  final IconData icon;
  final String label;
  final String value;
  final String hint;
  final List<Color> colors;
  final VoidCallback? onTap;

  const StatTileData({
    required this.icon,
    required this.label,
    required this.value,
    required this.hint,
    required this.colors,
    this.onTap,
  });
}

/// A horizontal strip of [GradientStatTile] cards that lays itself out into
/// 1 / 2 / or 4 columns based on width.
class StatStrip extends StatelessWidget {
  final List<StatTileData> tiles;
  const StatStrip(this.tiles, {super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth >= 1100
          ? (tiles.length >= 4 ? 4 : tiles.length)
          : c.maxWidth >= 720
              ? 2
              : 1;
      final tileWidth = (c.maxWidth - (cols - 1) * 12) / cols;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final t in tiles)
            SizedBox(width: tileWidth, child: GradientStatTile(data: t)),
        ],
      );
    });
  }
}

/// Single gradient-backed stat tile with icon, label, big value, and a hint.
/// Designed to be visually loud — for use at the top of each tab.
class GradientStatTile extends StatelessWidget {
  final StatTileData data;
  const GradientStatTile({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final tile = AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: data.colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: data.colors.first.withValues(alpha: 0.25),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(data.icon, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  data.label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            data.value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 30,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            data.hint,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
    if (data.onTap == null) return tile;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: data.onTap,
        borderRadius: BorderRadius.circular(16),
        child: tile,
      ),
    );
  }
}

/// Convenience: a "section header" — large title + optional subtitle.
class SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  const SectionHeader({super.key, required this.title, this.subtitle, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleLarge),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!,
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}
