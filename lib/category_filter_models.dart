class CategoryFilterItem {
  const CategoryFilterItem({required this.id, required this.name});

  factory CategoryFilterItem.fromJson(Map<String, dynamic> json) =>
      CategoryFilterItem(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
      );

  final String id;
  final String name;
}

class CategoryFilterRow {
  const CategoryFilterRow({
    required this.type,
    required this.name,
    required this.selectionType,
    required this.items,
  });

  factory CategoryFilterRow.fromJson(Map<String, dynamic> json) =>
      CategoryFilterRow(
        type: json['type']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        selectionType: _categoryFilterInt(json['selectionType']),
        items: [
          for (final value in json['items'] as List? ?? const [])
            if (value is Map)
              CategoryFilterItem.fromJson(Map<String, dynamic>.from(value)),
        ],
      );

  final String type;
  final String name;

  /// 红果接口的 selection_type：2 表示单选，其余按多选处理。
  final int selectionType;
  final List<CategoryFilterItem> items;

  bool get singleChoice => selectionType == 2;
}

class CategoryFilterPanel {
  const CategoryFilterPanel({required this.genre, required this.rows});

  factory CategoryFilterPanel.fromJson(Map<String, dynamic> json) =>
      CategoryFilterPanel(
        genre: json['genre']?.toString() ?? '',
        rows: [
          for (final value in json['rows'] as List? ?? const [])
            if (value is Map)
              CategoryFilterRow.fromJson(Map<String, dynamic>.from(value)),
        ],
      );

  final String genre;
  final List<CategoryFilterRow> rows;

  Set<String> get validItemIds => {
    for (final row in rows)
      for (final item in row.items) item.id,
  };
}

class CategoryFilterPage {
  const CategoryFilterPage({
    required this.items,
    required this.hasMore,
    required this.nextOffset,
    required this.sessionId,
  });

  factory CategoryFilterPage.fromJson(Map<String, dynamic> json) =>
      CategoryFilterPage(
        items: [
          for (final value in json['items'] as List? ?? const [])
            if (value is Map) Map<String, dynamic>.from(value),
        ],
        hasMore: json['hasMore'] == true,
        nextOffset: _categoryFilterInt(json['nextOffset']),
        sessionId: json['sessionId']?.toString() ?? '',
      );

  /// 原始剧集 JSON 由现有 Drama.fromJson 解析，避免复制剧集模型。
  final List<Map<String, dynamic>> items;
  final bool hasMore;
  final int nextOffset;
  final String sessionId;
}

int _categoryFilterInt(dynamic value) {
  if (value is int) return value;
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
