/// 「落到某一章时要停在末页」的待处理意图。
///
/// 必须带章号：翻页时请求的是上一章，而那次加载随时会被后来的跳章顶掉。
/// 用单个 bool 的话意图会一直挂着，等下一章节奏性落地时被误消费——
/// 用户点「下一章」却落到新章的末页。
class LastPageIntent {
  int _forChapter = -1;

  void request(int chapter) => _forChapter = chapter;

  void clear() => _forChapter = -1;

  /// 落在请求的那一章才算数；落到别的章说明这次加载已把原意图顶掉了，顺手作废。
  /// 不消费，同一章随后的 build 还要再读一次（见 [take]）。
  bool matches(int chapter) {
    if (_forChapter != chapter) {
      clear();
      return false;
    }
    return _forChapter >= 0;
  }

  /// 读一次并作废：只有第一次 build 会因此跳到末页。
  bool take(int chapter) {
    final hit = matches(chapter);
    clear();
    return hit;
  }
}
