import 'package:flutter/material.dart';

/// 通用书籍列表项
class BookTile extends StatelessWidget {
  final String name;
  final String author;
  final String coverUrl;
  final String? subtitle;
  final String? progress;
  final VoidCallback? onTap;
  final Widget? trailing;

  const BookTile({
    super.key,
    required this.name,
    required this.author,
    this.coverUrl = '',
    this.subtitle,
    this.progress,
    this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Cover(coverUrl: coverUrl, name: name),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(
                    [
                      if (author.isNotEmpty) author,
                      if (subtitle != null && subtitle!.isNotEmpty) subtitle!,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                  ),
                  if (progress != null && progress!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(progress!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                  ],
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

class _Cover extends StatelessWidget {
  final String coverUrl;
  final String name;
  const _Cover({required this.coverUrl, required this.name});

  @override
  Widget build(BuildContext context) {
    const w = 48.0, h = 64.0;
    if (coverUrl.isEmpty || (!coverUrl.startsWith('http'))) {
      return _placeholder(w, h);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Image.network(
        coverUrl,
        width: w,
        height: h,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _placeholder(w, h),
        loadingBuilder: (_, child, prog) => prog == null ? child : _placeholder(w, h),
      ),
    );
  }

  Widget _placeholder(double w, double h) {
    return Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: const Color(0xFF2E7D5B).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      alignment: Alignment.center,
      child: Text(
        name.length <= 2 ? name : name.substring(0, 2),
        style: const TextStyle(fontSize: 14, color: Color(0xFF2E7D5B), fontWeight: FontWeight.bold),
      ),
    );
  }
}
