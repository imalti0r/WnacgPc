/// 数据模型
library;

class Category {
  final int id;
  final String name;
  const Category(this.id, this.name);
}

/// 首页/列表页中的画廊条目
class GalleryItem {
  final String aid; // 详情页 id，如 382210
  final String title;
  final String coverUrl;
  final int? imageCount; // "158張圖片"
  final String? date; // "2026-09-06"

  const GalleryItem({
    required this.aid,
    required this.title,
    required this.coverUrl,
    this.imageCount,
    this.date,
  });

  String get detailUrl => '/photos-index-aid-$aid.html';

  Map<String, dynamic> toJson() => {
        'aid': aid,
        'title': title,
        'cover': coverUrl,
        'count': imageCount,
        'date': date,
      };

  factory GalleryItem.fromJson(Map<String, dynamic> j) => GalleryItem(
        aid: j['aid'] as String,
        title: (j['title'] ?? '') as String,
        coverUrl: (j['cover'] ?? '') as String,
        imageCount: j['count'] as int?,
        date: j['date'] as String?,
      );

  @override
  bool operator ==(Object other) => other is GalleryItem && other.aid == aid;

  @override
  int get hashCode => aid.hashCode;
}

/// 详情页数据
class GalleryDetail {
  final String aid;
  final String title;
  final String coverUrl;
  final List<String> categories; // 韓漫／漢化
  final int pages; // 頁數：1813P
  final List<String> tags;
  final String description;
  final String uploader;

  const GalleryDetail({
    required this.aid,
    required this.title,
    required this.coverUrl,
    this.categories = const [],
    this.pages = 0,
    this.tags = const [],
    this.description = '',
    this.uploader = '',
  });
}

/// 阅读器中的一页图片
class ReaderImage {
  final String url;
  final String caption;
  const ReaderImage(this.url, [this.caption = '']);
}

