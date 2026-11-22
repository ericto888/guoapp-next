import 'package:duanju_app/category_filter_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses a dynamic multidimensional selector panel', () {
    final panel = CategoryFilterPanel.fromJson({
      'genre': 'short_play',
      'rows': [
        {
          'type': 'theme',
          'name': '题材',
          'selectionType': 1,
          'items': [
            {'id': '1001', 'name': '甜宠'},
            {'id': '1002', 'name': '悬疑'},
          ],
        },
        {
          'type': 'year',
          'name': '年代',
          'selectionType': 2,
          'items': [
            {'id': '2025', 'name': '2025'},
          ],
        },
      ],
    });

    expect(panel.genre, 'short_play');
    expect(panel.rows, hasLength(2));
    expect(panel.rows.first.singleChoice, isFalse);
    expect(panel.rows.last.singleChoice, isTrue);
    expect(panel.validItemIds, {'1001', '1002', '2025'});
  });

  test('parses paged result cursor without owning the Drama model', () {
    final page = CategoryFilterPage.fromJson({
      'items': [
        {'id': 'drama-1', 'title': '测试短剧'},
      ],
      'hasMore': true,
      'nextOffset': '12',
      'sessionId': 'session-1',
    });

    expect(page.items.single['id'], 'drama-1');
    expect(page.hasMore, isTrue);
    expect(page.nextOffset, 12);
    expect(page.sessionId, 'session-1');
  });
}
