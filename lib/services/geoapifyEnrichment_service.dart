import 'package:cloud_firestore/cloud_firestore.dart';
import 'geoapify_service.dart';

// ─────────────────────────────────────────────────────────────────────────
// 🔧 Layer 1 OSM 诊断用——区分"没查到"背后的具体原因
// ─────────────────────────────────────────────────────────────────────────
class _OsmResolveResult {
  final List<String> types;
  final String? reason; // null = 成功；否则是失败原因代码
  _OsmResolveResult({required this.types, required this.reason});
}

class GeoapifyEnrichmentService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static const String _cacheCollection = 'geoapify_enrichment';

  // ─────────────────────────────────────────────────────────────────────────
  // 🎯 CONFIDENCE SYSTEM
  //
  // 每一层解析出来的结果可信度不一样，全部塞进同一个 List<String> 会导致
  // 二级分类看起来"很准"其实混了一堆瞎猜的。做法：
  //   1. 每层给出结果时同时给一个 confidence（0~1）
  //   2. 只有 confidence >= _confidenceThreshold 才会被写进最终返回结果
  //      （也就是只有够可信的才会被 UI 拿去做二级分类筛选）
  //   3. 没达标的，不会出现在返回的 types 里 —— 该地点仍然会正常出现在
  //      对应的 primary 分类（比如 Food）里，只是不会被塞进错的二级分类
  //   4. confidence 和 source 会一起写进 Firestore cache，方便以后做
  //      人工纠错 / 数据审计，不需要改动 UI 层也能追溯当初是怎么判断的
  // ─────────────────────────────────────────────────────────────────────────
  static const double _confidenceThreshold = 0.5;

  static const double _confidenceOsm    = 0.90; // 结构化 OSM tag，最可信
  static const double _confidenceOsmCorrected = 0.75; // OSM tag 跟地名冲突,被纠正后的结果——比纯 tag 低
  static const double _confidenceBrand  = 0.95; // 品牌白名单精确匹配，最可信
  static const double _confidenceKeyword = 0.45; // 关键词兜底，最不可信

  // ── Restaurant: cuisine → internal type ──────────────────────────────────
  static const Map<String, String> _cuisineToType = {
    'chinese':     'chinese_restaurant',
    'cantonese':   'chinese_restaurant',
    'dim_sum':     'chinese_restaurant',
    'noodle':      'chinese_restaurant',
    'malay':       'malaysian_restaurant',
    'malaysian':   'malaysian_restaurant',
    'indonesian':  'malaysian_restaurant',
    'indian':      'indian_restaurant',
    'japanese':    'japanese_restaurant',
    'sushi':       'japanese_restaurant',
    'ramen':       'japanese_restaurant',
    'korean':      'korean_restaurant',
    'western':     'western_restaurant',
    'american':    'american_restaurant',
    'italian':     'western_restaurant',
    'pizza':       'western_restaurant',
    'burger':      'western_restaurant',
    'steak_house': 'western_restaurant',
    'vietnamese':  'western_restaurant',
    'thai':        'western_restaurant',
    'coffee_shop': 'cafe',
    'coffee':      'cafe',
    'cafe':        'cafe',
    'dessert':     'dessert_shop',
    'ice_cream':   'ice_cream_shop',
    'bakery':      'bakery',
    'bubble_tea':  'dessert_shop',
  };


  // ─────────────────────────────────────────────────────────────────────────
  // 🆕 BRAND WHITELIST — 零成本、零网络请求、准确率接近 100%
  //
  // 马来西亚常见连锁店的地名几乎不会有歧义（比如名字里有 "KFC" 的地方
  // 几乎不可能不是西式快餐），所以用精确子字符串匹配就足够可信，不需要
  // 靠关键词猜。放在 OSM 之后、关键词兜底之前跑，能拦掉一大批地点。
  //
  // 按 primaryType 分组，避免跨分类误判（例如 shopping_mall 分类下的
  // "Aeon" 不会被拿去跟 restaurant 品牌表比对）。
  // ─────────────────────────────────────────────────────────────────────────
  static const Map<String, String> _brandToType_restaurant = {
    'kfc':                  'western_restaurant',
    'mcdonald':             'western_restaurant',
    'burger king':          'western_restaurant',
    'pizza hut':            'western_restaurant',
    'domino':               'western_restaurant',
    'secret recipe':        'western_restaurant',
    'nando':                'western_restaurant',
    'subway':               'western_restaurant',
    'a&w':                  'western_restaurant',
    'marrybrown':           'western_restaurant',
    'texas chicken':        'western_restaurant',
    'starbucks':            'cafe',
    'coffee bean':          'cafe',
    'old town white coffee':'cafe',
    'oldtown':              'cafe',
    'zus coffee':           'cafe',
    'san francisco coffee': 'cafe',
    'tealive':              'dessert_shop',
    'chatime':              'dessert_shop',
    'gong cha':             'dessert_shop',
    'xing fu tang':         'dessert_shop',
    'baskin robbins':       'ice_cream_shop',
    'haagen-dazs':          'ice_cream_shop',
    'häagen-dazs':          'ice_cream_shop',
    'sushi king':           'japanese_restaurant',
    'sakae sushi':          'japanese_restaurant',
    'ichiban boshi':        'japanese_restaurant',
    'genki sushi':          'japanese_restaurant',
    'kim gary':             'chinese_restaurant',
    'dragon-i':             'chinese_restaurant',
    // 🆕 怡保本地知名老字号——实测 log 里反复出现,加进白名单比等
    // Gemini/关键词猜靠谱（这些都是全城知名、几乎不会有歧义的招牌）
    'nam heong':            'cafe',           // 南香白咖啡，怡保白咖啡两大龙头之一
    'sin yoon loong':       'cafe',           // 新源隆白咖啡，怡保白咖啡两大龙头之一
    'chang jiang':          'cafe',           // 长江白咖啡
    'lou wong':             'chinese_restaurant', // 芽菜鸡名店
  };

  static const Map<String, String> _brandToType_shopping = {
    'aeon big':       'supermarket',
    'aeon mall':      'shopping_mall',
    'aeon':           'shopping_mall',
    'mydin':          'supermarket',
    'lotus':          'supermarket',
    'tesco':          'supermarket',
    'giant':          'supermarket',
    'econsave':       'supermarket',
    'jaya grocer':    'supermarket',
    'village grocer': 'supermarket',
    'guardian':       'pharmacy',
    'watsons':        'pharmacy',
    'caring pharmacy':'pharmacy',
    'alpro pharmacy': 'pharmacy',
    'uniqlo':         'clothing_store',
    'h&m':            'clothing_store',
    'zara':           'clothing_store',
    'padini':         'clothing_store',
    'senheng':        'electronics_store',
    'harvey norman':  'electronics_store',
    'courts':         'electronics_store',
  };

  static const Map<String, String> _brandToType_service = {
    'maybank':        'bank',
    'cimb':           'bank',
    'public bank':    'bank',
    'rhb':            'bank',
    'hong leong bank':'bank',
    'ambank':         'bank',
    'bank islam':     'bank',
    'bsn':            'bank',
    'pos malaysia':   'post_office',
    'poslaju':        'post_office',
  };

  static const Map<String, String> _brandToType_entertainment = {
    'gsc':               'movie_theater',
    'tgv':               'movie_theater',
    'mbo cinemas':       'movie_theater',
    'neway':             'karaoke',
    'redbox':            'karaoke',
    'red box':           'karaoke',
    'timezone':          'video_arcade',
    'sunway lagoon':     'amusement_park',
    'legoland':          'amusement_park',
    'celebrity fitness': 'fitness_center',
    'fitness first':     'fitness_center',
    'anytime fitness':   'fitness_center',
  };

  static Map<String, Map<String, String>> get _brandMapsByCategory => {
    'restaurant':    _brandToType_restaurant,
    'shopping_mall': _brandToType_shopping,
    'service':       _brandToType_service,
    'entertainment': _brandToType_entertainment,
  };

  // ─────────────────────────────────────────────────────────────────────────
  // PRIVATE: Extract valid Geoapify place_id from our internal id
  // Returns null if the id doesn't contain a valid place_id
  // ─────────────────────────────────────────────────────────────────────────
  static String? _extractRawPlaceId(String internalId) {
    // 'geo_osm_123456' → no valid place_id, skip OSM lookup
    if (internalId.startsWith('geo_osm_')) return null;

    // 'geo_3.13900_101.68690' → lat_lng fallback, no place_id
    if (internalId.startsWith('geo_')) {
      final candidate = internalId.replaceFirst('geo_', '');
      // Real Geoapify place_ids are long hex strings (>30 chars)
      // lat_lng ids look like '3.13900_101.68690' (short, contains underscore between two numbers)
      if (candidate.length < 30) return null;
      return candidate;
    }

    return null;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PUBLIC: Enrich a batch of Geoapify places (all 6 categories)
  //
  // 新顺序（准确率从高到低，越前面越先跑，跑到就不再往下）：
  //   Phase 0  缓存检查（只读，不碰 OSM/Brand）
  //   Layer 1  OSM 结构化 tag —— 免费、无配额限制，准确率最高，优先跑
  //   Layer 2  品牌白名单 —— 免费、无网络请求，命中即高置信度
  //   Layer 3  名字关键词 —— 最后兜底
  //   最后     按 confidence 阈值过滤 + 统一写缓存
  //
  // 🔧 原本还有一层 Gemini（排在品牌白名单之后），但实测多次撞
  // 429 限流、几乎没有产出结果，同时还拖慢整体耗时（等重试）、
  // 增加撞外层 35 秒 timeout 的风险，性价比太低，已经整层拿掉。
  //
  // 返回值只包含 confidence >= _confidenceThreshold 的结果；没达标的
  // 地点不会出现在返回的 Map 里（调用方应把它们当作"未分类"，仍归入
  // 对应 primary 分类展示，只是不提供二级筛选）。
  // ─────────────────────────────────────────────────────────────────────────
  static Future<Map<String, List<String>>> enrichPlaces(
    List<Map<String, String>> places,
  ) async {
    if (places.isEmpty) return {};

    // 最终返回给调用方的结果（只含达标的）
    final result = <String, List<String>>{};

    // 内部诊断信息，仅用于写缓存，不对外暴露
    final confidenceOf = <String, double>{};
    final sourceOf     = <String, String>{};

    // ── Phase 0: 只查缓存 ───────────────────────────────────────────────
    final needsClassification = <Map<String, String>>[];

    const cacheBatchSize = 20;
    for (int i = 0; i < places.length; i += cacheBatchSize) {
      final batch = places.skip(i).take(cacheBatchSize).toList();
      final cachedResults = await Future.wait(
        batch.map((p) => _checkCache(p['placeId']!)),
      );
      for (int j = 0; j < batch.length; j++) {
        final cached = cachedResults[j];
        if (cached != null) {
          result[batch[j]['placeId']!] = cached;
        } else {
          needsClassification.add(batch[j]);
        }
      }
    }

    print('🟣 缓存: ${result.length}/${places.length} 已解决, '
        '${needsClassification.length} 需要分类');

    if (needsClassification.isEmpty) {
      print('🟣 GeoapifyEnrichment final: ${result.length}/${places.length} '
          'places resolved（全部命中缓存）');
      return result;
    }

    // ── Layer 1: OSM 结构化 tag —— 免费，优先跑，能解决就不用麻烦后面几层 ──
    final needsBrand = <Map<String, String>>[];
    final osmFailReasons = <String, int>{}; // 诊断用：失败原因 → 次数

    // 批量并发数从 5 提到 10——254 个地点全靠 5 个一批、100ms 间隔跑下来
    // 容易拖到 30+ 秒，撞上调用方（NearbyPlacesService）外层的 35 秒
    // timeout，一旦撞上就会整批退化成纯关键词兜底，等于白做了这一层。
    const osmBatchSize = 10;
    for (int i = 0; i < needsClassification.length; i += osmBatchSize) {
      final batch = needsClassification.skip(i).take(osmBatchSize).toList();
      final osmResults = await Future.wait(
        batch.map((p) => _resolveOsmOnly(
          internalId:  p['placeId']!,
          primaryType: p['primaryType'] ?? '',
        )),
      );
      for (int j = 0; j < batch.length; j++) {
        final placeId     = batch[j]['placeId']!;
        final placeName   = batch[j]['placeName']   ?? '';
        final primaryType = batch[j]['primaryType'] ?? '';
        final osmResult    = osmResults[j];

        if (osmResult.types.isEmpty) {
          final reason = osmResult.reason ?? 'unknown';
          osmFailReasons[reason] = (osmFailReasons[reason] ?? 0) + 1;
          needsBrand.add(batch[j]);
          continue;
        }

        // 🔧 OSM tag 跟地名强烈冲突时做纠正（不是完全信任 tag）。
        // 实测案例：怡保火车站 OSM 上同时挂了 highway=bus_stop，被
        // 判成 bus_stop，但名字明确写着"Stesen KTM"。tag 冲突时，
        // 用置信度略低的 'osm_corrected' 来源，而不是原本的 0.90。
        final reconciled = _reconcileTransitNameConflict(placeName, osmResult.types);
        final wasCorrected = !_sameTypes(reconciled, osmResult.types);

        result[placeId]       = reconciled;
        confidenceOf[placeId] = wasCorrected ? _confidenceOsmCorrected : _confidenceOsm;
        sourceOf[placeId]     = wasCorrected ? 'osm_corrected' : 'osm';

        if (wasCorrected) {
          print('🟢🔧 Layer 1 (OSM,纠正): $placeName ($primaryType) '
              '${osmResult.types} → $reconciled（tag 跟地名冲突）');
        } else {
          print('🟢 Layer 1 (OSM): $placeName ($primaryType) → $reconciled');
        }
      }
      if (i + osmBatchSize < needsClassification.length) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }

    print('🟣 Layer 1 (OSM): 解决了 ${needsClassification.length - needsBrand.length}/'
        '${needsClassification.length}');
    if (osmFailReasons.isNotEmpty) {
      // 这行就是用来回答"到底是没有 OSM 数据，还是请求失败了"这个问题的：
      // no_raw_place_id  → 这个地点根本没有有效的 Geoapify place_id，
      //                     从头到尾没打过网络请求，纯粹是 ID 格式问题
      // fetch_returned_null / exception → 真的打了请求，但没拿到数据
      //                     （网络问题、API 限流/降速等）
      // no_raw_tags / tags_present_no_match → 请求成功，但 OSM 上
      //                     这个地点确实没有能用的 tag，是数据本身的问题
      print('🟣 Layer 1 失败原因分布: $osmFailReasons');
    }

    // ── Layer 2: 品牌白名单 —── 免费，无网络请求 ─────────────────────────
    final needsKeyword = <Map<String, String>>[];

    for (final place in needsBrand) {
      final placeId     = place['placeId']!;
      final placeName   = place['placeName']   ?? '';
      final primaryType = place['primaryType'] ?? '';

      final brandType = _matchBrand(placeName, primaryType);
      if (brandType != null) {
        result[placeId]       = [brandType];
        confidenceOf[placeId] = _confidenceBrand;
        sourceOf[placeId]     = 'brand';
        print('🔵 Layer 2 (Brand): $placeName ($primaryType) → $brandType');
      } else {
        needsKeyword.add(place);
      }
    }

    print('🟣 Layer 2 (Brand): 解决了 ${needsBrand.length - needsKeyword.length}/'
        '${needsBrand.length}');

    // ── Layer 3: 名字关键词兜底 ───────────────────────────────────────────
    for (final place in needsKeyword) {
      final placeId     = place['placeId']!;
      final placeName   = place['placeName']   ?? '';
      final primaryType = place['primaryType'] ?? '';

      final guessed = _guessByName(placeName, primaryType);
      if (guessed != null) {
        result[placeId]       = [guessed];
        confidenceOf[placeId] = _confidenceKeyword;
        sourceOf[placeId]     = 'keyword';
        print('🟡 Layer 3: $placeName ($primaryType) → $guessed');
      }
      // 猜不出来就不写入 result —— 该地点仍会正常显示在 primary 分类里，
      // 只是不会出现在任何二级分类筛选中
    }

    // ── 按 confidence 阈值过滤：低于阈值的不进最终结果 ───────────────────
    // （目前四层里最低是 keyword = 0.45 < 0.5，所以关键词猜出来的结果
    //  默认不会展示为具体二级分类——如果你想放宽，调整 _confidenceThreshold
    //  或 _confidenceKeyword 即可，不用改这段逻辑）
    final belowThreshold = <String>[];
    for (final entry in confidenceOf.entries) {
      if (entry.value < _confidenceThreshold) {
        belowThreshold.add(entry.key);
      }
    }
    for (final placeId in belowThreshold) {
      result.remove(placeId);
    }
    if (belowThreshold.isNotEmpty) {
      print('🟠 Confidence 过滤: ${belowThreshold.length} 个结果低于阈值 '
          '($_confidenceThreshold)，不计入二级分类');
    }

    // ── 统一写缓存（包含被阈值过滤掉的——写成空 types，允许下次重试） ────
    final cacheWrites = needsClassification.map((place) async {
      final placeId = place['placeId']!;
      final finalTypes = result[placeId] ?? <String>[];

      try {
        await _firestore.collection(_cacheCollection).doc(placeId).set({
          'types':      finalTypes,
          'confidence': confidenceOf[placeId], // may be null if totally unresolved
          'source':     sourceOf[placeId],      // may be null if totally unresolved
          'cachedAt':   FieldValue.serverTimestamp(),
        });
      } catch (e) {
        print('⚠️ Cache save failed for $placeId: $e');
      }
    });

    await Future.wait(cacheWrites);

    // ── 📊 本轮汇总——每层各解决了多少个、过滤掉多少个、完全没解出来多少个 ──
    // 这段只统计这次真正跑分类逻辑的 needsClassification，缓存命中的不算
    // 进来（缓存命中说明是之前某一轮跑出来的，不代表这次各层的真实表现）。
    final totalThisRun = needsClassification.length;
    int cOsm = 0, cOsmCorrected = 0, cBrand = 0, cKeyword = 0,
        cFiltered = 0, cUnresolved = 0;

    // primaryType → {source → count}，用来拆出"这次是不是靠 service/
    // transit 撑起来的"这种偏科问题，而不是只看一个笼统总百分比
    final byCategory = <String, Map<String, int>>{};

    for (final place in needsClassification) {
      final placeId     = place['placeId']!;
      final primaryType = place['primaryType'] ?? 'unknown';
      final wasFiltered = belowThreshold.contains(placeId);
      final src         = wasFiltered ? 'filtered' : (sourceOf[placeId] ?? 'unresolved');

      byCategory.putIfAbsent(primaryType, () => {});
      byCategory[primaryType]![src] = (byCategory[primaryType]![src] ?? 0) + 1;

      switch (src) {
        case 'filtered':      cFiltered++;      break;
        case 'osm':           cOsm++;           break;
        case 'osm_corrected': cOsmCorrected++;  break;
        case 'brand':         cBrand++;         break;
        case 'keyword':       cKeyword++;       break;
        default:              cUnresolved++;
      }
    }

    String pct(int n) => totalThisRun == 0 ? '0%' : '${(n / totalThisRun * 100).toStringAsFixed(1)}%';
    print('📊 ══════ 本轮分类汇总 (共 $totalThisRun 个新地点) ══════');
    print('📊 Layer 1 OSM         : $cOsm  (${pct(cOsm)})');
    print('📊 Layer 1 OSM(已纠正)  : $cOsmCorrected  (${pct(cOsmCorrected)})  — tag 跟地名冲突,confidence 降到 $_confidenceOsmCorrected');
    print('📊 Layer 2 Brand       : $cBrand  (${pct(cBrand)})');
    print('📊 Layer 3 Keyword (采纳,confidence≥$_confidenceThreshold): $cKeyword  (${pct(cKeyword)})');
    print('📊 Layer 3 Keyword (猜到但confidence不够,已过滤): $cFiltered  (${pct(cFiltered)})');
    print('📊 完全无法分类(三层都没猜出来): $cUnresolved  (${pct(cUnresolved)})');
    print('📊 进入最终二级分类的: ${cOsm + cOsmCorrected + cBrand}  '
        '(${pct(cOsm + cOsmCorrected + cBrand)})');
    print('📊 ─────────── 按 primary 分类拆解 ───────────');
    for (final entry in byCategory.entries) {
      final catTotal = entry.value.values.fold<int>(0, (a, b) => a + b);
      final catResolved = (entry.value['osm'] ?? 0) +
          (entry.value['osm_corrected'] ?? 0) +
          (entry.value['brand'] ?? 0);
      final catPct = catTotal == 0 ? '0%' : '${(catResolved / catTotal * 100).toStringAsFixed(1)}%';
      print('📊   ${entry.key.padRight(14)}: $catResolved/$catTotal 进入二级分类 ($catPct)  '
          '详情=${entry.value}');
    }
    print('📊 ═══════════════════════════════════════════');

    print('🟣 GeoapifyEnrichment final: ${result.length}/${places.length} places resolved');
    return result;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PRIVATE: 只查缓存。只有非空结果才算真正命中——空结果视为"上次没
  // 猜出来"，允许重新尝试（比如上次网络不稳定，或者这次品牌表刚好
  // 覆盖到了）。
  // ─────────────────────────────────────────────────────────────────────────
  static Future<List<String>?> _checkCache(String internalId) async {
    try {
      final cacheDoc = await _firestore
          .collection(_cacheCollection)
          .doc(internalId)
          .get();

      if (cacheDoc.exists) {
        final cachedTypes = (cacheDoc.data()?['types'] as List?)
            ?.map((e) => e.toString())
            .toList();
        if (cachedTypes != null && cachedTypes.isNotEmpty) {
          return cachedTypes;
        }
      }
    } catch (e) {
      print('⚠️ Cache check failed for $internalId: $e');
    }
    return null;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PRIVATE: 品牌白名单匹配（Layer 2）
  // 用 word-boundary 而不是纯 String.contains——避免像 "gsc"（Golden
  // Screen Cinemas）意外匹配到 "Bagsclub" 这种名字里恰好包含相同字母
  // 组合、但完全无关的地点。按 primaryType 分组比对，进一步避免跨分类
  // 误判（比如 shopping_mall 品牌表不会拿去跟 restaurant 类地点比对）。
  // ─────────────────────────────────────────────────────────────────────────
  static String? _matchBrand(String name, String primaryType) {
    final brandMap = _brandMapsByCategory[primaryType];
    if (brandMap == null) return null;

    final n = name.toLowerCase();
    for (final entry in brandMap.entries) {
      final pattern = RegExp(r'\b' + RegExp.escape(entry.key) + r'\b');
      if (pattern.hasMatch(n)) return entry.value;
    }
    return null;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PRIVATE: OSM tag 跟地名强烈冲突时的纠正（Layer 1 内部用）
  //
  // 实测发现的真实案例："Stesen KTM Ipoh"（怡保火车站）在 OSM 上被判成
  // bus_stop——大概率是同一个节点上同时挂了 railway 和 highway=bus_stop
  // 两种 tag，我们的 _resolveTypes 优先级判断漏检了 railway 那一支。
  //
  // 这里不是要推翻"信任结构化数据"这个原则，而是加一道兜底检查：如果
  // 地名本身有极强、无歧义的信号（"KTM"/"LRT"/"MRT"/"Stesen Keretapi"/
  // "Monorail"）却被判成公交类型，说明 tag 数据本身很可能有问题，此时
  // 用地名纠正，但把 confidence 降到 0.75（比纯 OSM tag 的 0.90 低，
  // 承认这已经掺了一部分名字推断），而不是继续标 0.90。
  //
  // 只处理 transit 类别、只处理"明显该是火车却被标成公交"这一种已知
  // 冲突模式——不做泛化猜测，避免引入新的误判。
  // ─────────────────────────────────────────────────────────────────────────
  static List<String> _reconcileTransitNameConflict(
    String placeName,
    List<String> osmTypes,
  ) {
    if (osmTypes.isEmpty) return osmTypes;

    final resolvedAsBusOnly =
        osmTypes.every((t) => t == 'bus_stop' || t == 'bus_station');
    if (!resolvedAsBusOnly) return osmTypes;

    final n = placeName.toLowerCase();
    final looksLikeTrain = n.contains('ktm')      ||
        n.contains('stesen keretapi')             ||
        n.contains('lrt')                         ||
        n.contains('mrt')                         ||
        n.contains('monorail');

    if (looksLikeTrain) return ['train_station'];
    return osmTypes;
  }

  static bool _sameTypes(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    final sa = a.toSet();
    final sb = b.toSet();
    return sa.length == sb.length && sa.containsAll(sb);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PRIVATE: OSM-only 解析（不做缓存检查——调用方已经查过了）
  //
  // 🔧 改成返回 _OsmResolveResult 而不是裸的 List<String>——空结果背后
  // 可能是好几种完全不同的原因（地点本来就没有 place_id、Geoapify
  // 详情接口没查到东西、查到了但没有相关 tag、有 tag 但对不上任何
  // 已知类型、或者网络请求直接报错），原来全部长得一样都是空列表，
  // 没法诊断"这批 OSM 覆盖率低到底是数据问题还是网络问题"。
  // ─────────────────────────────────────────────────────────────────────────
  static Future<_OsmResolveResult> _resolveOsmOnly({
    required String internalId,
    required String primaryType,
  }) async {
    if (primaryType.isEmpty) {
      return _OsmResolveResult(types: [], reason: 'no_primary_type');
    }

    final rawPlaceId = _extractRawPlaceId(internalId);
    if (rawPlaceId == null) {
      // 这个地点的 internalId 不是有效的 Geoapify place_id（比如是
      // geo_osm_ 开头，或者是 lat/lng 兜底 id）——根本没打网络请求，
      // 跟"查了但没查到"是完全不同的情况。
      return _OsmResolveResult(types: [], reason: 'no_raw_place_id');
    }

    try {
      final props = await GeoapifyService.fetchPlaceDetails(rawPlaceId);
      if (props == null) {
        return _OsmResolveResult(types: [], reason: 'fetch_returned_null');
      }

      final raw = (props['datasource'] as Map<String, dynamic>?)
          ?['raw'] as Map<String, dynamic>?;
      if (raw == null) {
        return _OsmResolveResult(types: [], reason: 'no_raw_tags');
      }

      final resolved = _resolveTypes(raw, primaryType);
      if (resolved.isEmpty) {
        return _OsmResolveResult(types: [], reason: 'tags_present_no_match');
      }
      return _OsmResolveResult(types: resolved, reason: null);
    } catch (e) {
      print('⚠️ OSM fallback failed for $internalId: $e');
      return _OsmResolveResult(types: [], reason: 'exception');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PRIVATE: Layer 3 — conservative name-based fallback (all 6 categories)
  // Only uses STRONG, unambiguous signal words — never generic terms
  // ─────────────────────────────────────────────────────────────────────────
  static String? _guessByName(String name, String primaryType) {
    final n = name.toLowerCase();

    switch (primaryType) {

      case 'restaurant': {
        if (n.contains('dim sum')      || n.contains('hong kong')  ||
            n.contains('canton')       || n.contains('claypot')    ||
            n.contains('wonton')       || n.contains('bak kut teh')||
            n.contains('char siew')    || n.contains('hokkien')    ||
            n.contains('teochew')      || n.contains('cantonese')) {
          return 'chinese_restaurant';
        }
        if (n.contains('sushi')        || n.contains('ramen')      ||
            n.contains('yakitori')     || n.contains('tempura')    ||
            n.contains('izakaya')      || n.contains('tonkatsu')   ||
            n.contains('udon')) {
          return 'japanese_restaurant';
        }
        if (n.contains('korean bbq')   || n.contains('kimchi')     ||
            n.contains('bibimbap')     || n.contains('k-bbq')) {
          return 'korean_restaurant';
        }
        if (n.contains('briyani')      || n.contains('biryani')    ||
            n.contains('tandoor')      || n.contains('roti canai') ||
            n.contains('banana leaf')  || n.contains('thali')      ||
            n.contains('mamak')        || n.contains('nasi kandar')) {
          return 'indian_restaurant';
        }
        if (n.contains('nasi lemak')   || n.contains('rendang')    ||
            n.contains('satay')        || n.contains('laksa')      ||
            n.contains('nasi padang')  || n.contains('masakan padang')) {
          return 'malaysian_restaurant';
        }
        if (n.contains('pizza')        || n.contains('burger')     ||
            n.contains('steakhouse')   || n.contains('steak house')) {
          return 'western_restaurant';
        }
        // 🆕 "white coffee"（白咖啡）/ "kopitiam" 在马来西亚语境下
        // 是很强的信号词，基本等同于咖啡店，不会有歧义
        if (n.contains('white coffee') || n.contains('kopitiam')) {
          return 'cafe';
        }
        return null;
      }

      case 'park': {
        if (n.contains('pantai')  || n.contains('beach'))           return 'beach';
        if (n.contains('bukit')   || n.contains('hill')   ||
            n.contains('trail')   || n.contains('hutan')  ||
            n.contains('forest'))                                    return 'hiking_area';
        if (n.contains('botanical') || n.contains('garden') ||
            n.contains('bunga'))                                     return 'botanical_garden';
        if (n.contains('museum')  || n.contains('muzium'))          return 'museum';
        if (n.contains('masjid')  || n.contains('mosque'))          return 'mosque';
        if (n.contains('tokong')  || n.contains('temple') ||
            n.contains('kuil'))                                      return 'hindu_temple';
        if (n.contains('gereja')  || n.contains('church') ||
            n.contains('cathedral'))                                 return 'church';
        if (n.contains('taman')   || n.contains('park'))            return 'park';
        return null;
      }

      case 'entertainment': {
        if (n.contains('cinema')  || n.contains('gsc') ||
            n.contains('tgv')     || n.contains('mbo'))             return 'movie_theater';
        if (n.contains('karaoke') || n.contains('neway') ||
            n.contains('red box'))                                   return 'karaoke';
        if (n.contains('bowling'))                                   return 'bowling_alley';
        if (n.contains('arcade')  || n.contains('esport') ||
            n.contains('gaming'))                                    return 'video_arcade';
        if (n.contains('gym')     || n.contains('fitness'))         return 'fitness_center';
        if (n.contains('spa')     || n.contains('massage'))         return 'spa';
        return null;
      }

      case 'shopping_mall': {
        if (n.contains('supermarket') || n.contains('mydin')  ||
            n.contains('aeon')        || n.contains('tesco')  ||
            n.contains('giant')       || n.contains('econsave')) {
          return 'supermarket';
        }
        if (n.contains('pharmacy')  || n.contains('farmasi') ||
            n.contains('guardian')  || n.contains('watsons') ||
            n.contains('caring')) {
          return 'pharmacy';
        }
        if (n.contains('mall')    || n.contains('plaza')  ||
            n.contains('square')  || n.contains('pavilion')) {
          return 'shopping_mall';
        }
        if (n.contains('pasar')   || n.contains('market') ||
            n.contains('bazaar')) {
          return 'market';
        }
        return null;
      }

      case 'transit': {
        if (n.contains('lrt')     || n.contains('mrt')    ||
            n.contains('ktm')     || n.contains('monorail')||
            n.contains('stesen')) {
          return 'subway_station';
        }
        if (n.contains('bus')     || n.contains('hentian')||
            n.contains('terminal')) {
          return 'bus_station';
        }
        if (n.contains('taxi')    || n.contains('grab'))   return 'taxi_stand';
        return null;
      }

      case 'service': {
        if (n.contains('hospital')    || n.contains('klinik') ||
            n.contains('clinic'))                                    return 'hospital';
        if (n.contains('maybank')     || n.contains('cimb')   ||
            n.contains('public bank') || n.contains('rhb')    ||
            n.contains('hong leong')  || n.contains('ambank')) {
          return 'bank';
        }
        if (n.contains('pos malaysia')|| n.contains('poslaju')||
            n.contains('post office'))                               return 'post_office';
        return null;
      }

      default:
        return null;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PRIVATE: Resolve OSM raw tags → internal types (Layer 1)
  // Uses key + value pattern to avoid ambiguity
  // ─────────────────────────────────────────────────────────────────────────
  static List<String> _resolveTypes(Map<String, dynamic> raw, String primaryType) {
    switch (primaryType) {

      case 'restaurant': {
        final cuisine = raw['cuisine']?.toString().toLowerCase().trim() ?? '';
        if (cuisine.isEmpty) return [];
        final types = <String>{};
        for (final part in cuisine.split(';').map((c) => c.trim())) {
          final mapped = _cuisineToType[part];
          if (mapped != null) types.add(mapped);
        }
        return types.toList();
      }

      case 'park': {
        final leisure  = raw['leisure']?.toString().toLowerCase()  ?? '';
        final natural  = raw['natural']?.toString().toLowerCase()  ?? '';
        final tourism  = raw['tourism']?.toString().toLowerCase()  ?? '';
        final historic = raw['historic']?.toString().toLowerCase() ?? '';
        final amenity  = raw['amenity']?.toString().toLowerCase()  ?? '';

        if (leisure == 'park')              return ['park'];
        if (leisure == 'garden')            return ['botanical_garden'];
        if (leisure == 'nature_reserve')    return ['national_park'];
        if (leisure == 'recreation_ground') return ['park'];
        if (natural == 'beach')             return ['beach'];
        if (natural == 'wood')              return ['hiking_area'];
        if (natural == 'forest')            return ['hiking_area'];
        if (tourism == 'attraction')        return ['tourist_attraction'];
        if (tourism == 'museum')            return ['museum'];
        if (tourism == 'gallery')           return ['art_gallery'];
        if (tourism == 'viewpoint')         return ['tourist_attraction'];
        if (historic == 'monument')         return ['monument'];
        if (historic == 'memorial')         return ['historical_landmark'];
        if (historic == 'castle')           return ['historical_landmark'];
        if (historic == 'ruins')            return ['historical_landmark'];
        if (historic == 'fort')             return ['historical_landmark'];
        if (amenity == 'place_of_worship')  return ['tourist_attraction'];
        return [];
      }

      case 'entertainment': {
        final amenity = raw['amenity']?.toString().toLowerCase() ?? '';
        final leisure = raw['leisure']?.toString().toLowerCase() ?? '';
        final tourism = raw['tourism']?.toString().toLowerCase() ?? '';

        if (amenity == 'cinema')            return ['movie_theater'];
        if (amenity == 'theatre')           return ['movie_theater'];
        if (amenity == 'nightclub')         return ['night_club'];
        if (amenity == 'casino')            return ['amusement_center'];
        if (amenity == 'bowling_alley')     return ['bowling_alley'];
        if (amenity == 'karaoke_box')       return ['karaoke'];
        if (leisure == 'amusement_arcade')  return ['video_arcade'];
        if (leisure == 'water_park')        return ['amusement_park'];
        if (leisure == 'fitness_centre')    return ['fitness_center'];
        if (leisure == 'sports_centre')     return ['sports_complex'];
        if (leisure == 'stadium')           return ['stadium'];
        if (leisure == 'swimming_pool')     return ['sports_complex'];
        if (leisure == 'spa')               return ['spa'];
        if (tourism == 'theme_park')        return ['amusement_park'];
        if (tourism == 'zoo')               return ['amusement_park'];
        if (tourism == 'aquarium')          return ['amusement_park'];
        return [];
      }

      case 'shopping_mall': {
        final shop    = raw['shop']?.toString().toLowerCase()    ?? '';
        final amenity = raw['amenity']?.toString().toLowerCase() ?? '';

        if (shop == 'mall')                 return ['shopping_mall'];
        if (shop == 'supermarket')          return ['supermarket'];
        if (shop == 'convenience')          return ['convenience_store'];
        if (shop == 'department_store')     return ['department_store'];
        if (shop == 'clothes')              return ['clothing_store'];
        if (shop == 'shoes')                return ['shoe_store'];
        if (shop == 'electronics')          return ['electronics_store'];
        if (shop == 'mobile_phone')         return ['electronics_store'];
        if (shop == 'computer')             return ['electronics_store'];
        if (shop == 'books')                return ['book_store'];
        if (shop == 'pharmacy')             return ['pharmacy'];
        if (shop == 'chemist')              return ['pharmacy'];
        if (shop == 'marketplace')          return ['market'];
        if (shop == 'grocery')              return ['grocery_store'];
        if (shop == 'hardware')             return ['department_store'];
        if (shop == 'furniture')            return ['department_store'];
        if (shop == 'jewelry')              return ['clothing_store'];
        if (shop == 'sports')               return ['department_store'];
        if (amenity == 'marketplace')       return ['market'];
        if (amenity == 'pharmacy')          return ['pharmacy'];
        return [];
      }

      case 'transit': {
        final railway = raw['railway']?.toString().toLowerCase()          ?? '';
        final highway = raw['highway']?.toString().toLowerCase()          ?? '';
        final amenity = raw['amenity']?.toString().toLowerCase()          ?? '';
        final pt      = raw['public_transport']?.toString().toLowerCase() ?? '';

        if (railway == 'station')           return ['train_station'];
        if (railway == 'halt')              return ['train_station'];
        if (railway == 'tram_stop')         return ['light_rail_station'];
        if (railway == 'subway_entrance')   return ['subway_station'];
        if (highway == 'bus_stop')          return ['bus_stop'];
        if (amenity == 'bus_station')       return ['bus_station'];
        if (amenity == 'ferry_terminal')    return ['transit_station'];
        if (amenity == 'taxi')              return ['taxi_stand'];
        if (pt == 'station')                return ['transit_station'];
        if (pt == 'stop_position')          return ['transit_station'];
        if (pt == 'platform')               return ['transit_station'];
        return [];
      }

      case 'service': {
        final amenity    = raw['amenity']?.toString().toLowerCase()    ?? '';
        final healthcare = raw['healthcare']?.toString().toLowerCase() ?? '';

        if (amenity == 'hospital')          return ['hospital'];
        if (amenity == 'clinic')            return ['medical_clinic'];
        if (amenity == 'doctors')           return ['doctor'];
        if (amenity == 'dentist')           return ['medical_clinic'];
        if (amenity == 'pharmacy')          return ['pharmacy'];
        if (amenity == 'bank')              return ['bank'];
        if (amenity == 'atm')               return ['atm'];
        if (amenity == 'post_office')       return ['post_office'];
        if (healthcare == 'hospital')       return ['hospital'];
        if (healthcare == 'clinic')         return ['medical_clinic'];
        if (healthcare == 'pharmacy')       return ['pharmacy'];
        return [];
      }

      default:
        return [];
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PRIVATE: Helpers
  // ─────────────────────────────────────────────────────────────────────────
  static String _categoryLabel(String primaryType) {
    switch (primaryType) {
      case 'restaurant':    return 'Food & Restaurants';
      case 'park':          return 'Nature & Attractions';
      case 'entertainment': return 'Entertainment';
      case 'shopping_mall': return 'Shopping';
      case 'transit':       return 'Public Transport';
      case 'service':       return 'Services';
      default:              return primaryType;
    }
  }
}