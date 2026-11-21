import 'package:duanju_app/danmaku_emoji.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses upstream named danmaku emoji into visible glyphs', () {
    expect(hasDanmakuEmoji('太好看了[笑]'), isTrue);
    final segments = parseDanmakuSegments('太好看了[笑]!');
    expect(segments, hasLength(3));
    expect(segments.first.text, '太好看了');
    expect(segments[1].isEmoji, isTrue);
    expect(segments[1].asset, isNotEmpty);
    expect(segments.last.text, '!');
  });

  test('keeps unknown bracket text as ordinary danmaku text', () {
    expect(hasDanmakuEmoji('测试[未知表情]'), isFalse);
    final segments = parseDanmakuSegments('测试[未知表情]');
    expect(segments, hasLength(1));
    expect(segments.single.text, '测试[未知表情]');
  });
}
