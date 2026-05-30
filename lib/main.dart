import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('zh_CN');
  if (!kIsWeb) {
    await Hive.initFlutter();
  }
  await NotificationService.instance.init();
  final appState = await AppState.create();
  await NotificationService.instance.syncPracticeReminders(
    appState.reminderSlots,
  );
  runApp(TaoistApp(state: appState));
}

class AppColors {
  static const Color paperBg = Color(0xFFF9F6F0);
  static const Color bambooGreen = Color(0xFF2C3E35);
  static const Color ancientGold = Color(0xFFA88243);
  static const Color inkGrey = Color(0xFF757575);
  static const Color demonRed = Color(0xFF8B3A3A);
  static const Color cinnabar = Color(0xFFC45F48);
  static const Color jade = Color(0xFF5F8E6D);
  static const Color nightInk = Color(0xFF202820);
  static const Color cardBg = Color(0xFFF1EDE4);
}

String _dateKey(DateTime date) {
  final normalized = DateUtils.dateOnly(date);
  return normalized.toIso8601String().split('T').first;
}

Map<String, dynamic> _stringDynamicMap(Object? value) {
  if (value is Map) {
    return value.map((key, mapValue) => MapEntry(key.toString(), mapValue));
  }
  return <String, dynamic>{};
}

List<Map<String, dynamic>> _mapList(Object? value) {
  if (value is List) {
    return value.map((item) => _stringDynamicMap(item)).toList();
  }
  return <Map<String, dynamic>>[];
}

const List<String> _taskTypes = ['日程', '习惯'];
const List<String> _taskDifficulties = ['人阶', '地阶', '天阶'];
const List<String> _taskQuadrants = [
  '天劫降临(重要且紧急)',
  '仙道根基(重要不紧急)',
  '红尘俗务(紧急不重要)',
  '因果业障(不重要不紧急)',
];

String _defaultQuadrantForType(String type) {
  return type == '习惯' ? '仙道根基(重要不紧急)' : '天劫降临(重要且紧急)';
}

String _safeTaskType(Object? value) {
  final text = value?.toString();
  return _taskTypes.contains(text) ? text! : '日程';
}

String _safeDifficulty(Object? value) {
  final text = value?.toString();
  return _taskDifficulties.contains(text) ? text! : '人阶';
}

String _safeQuadrant(Object? value, String type) {
  final text = value?.toString();
  return _taskQuadrants.contains(text) ? text! : _defaultQuadrantForType(type);
}

int _quadrantWeight(String quadrant) {
  if (quadrant.contains('天劫')) return 4;
  if (quadrant.contains('根基')) return 3;
  if (quadrant.contains('俗务')) return 2;
  return 1;
}

String _quadrantShortName(String quadrant) {
  final marker = quadrant.indexOf('(');
  return marker == -1 ? quadrant : quadrant.substring(0, marker);
}

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const AndroidNotificationChannel _practiceChannel =
      AndroidNotificationChannel(
        'daily_practice',
        '每日功法提醒',
        description: '用于提醒每日功法、晨起吐纳与子时静修',
        importance: Importance.high,
      );

  Future<void> init() async {
    if (kIsWeb) return;

    tz.initializeTimeZones();
    try {
      final timeZoneInfo = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(timeZoneInfo.identifier));
    } catch (_) {
      tz.setLocalLocation(tz.UTC);
    }

    const androidSettings = AndroidInitializationSettings(
      '@drawable/ic_stat_notification',
    );
    const iosSettings = DarwinInitializationSettings();
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );
    await _plugin.initialize(settings: settings);

    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidPlugin?.createNotificationChannel(_practiceChannel);
    await androidPlugin?.requestNotificationsPermission();
    await androidPlugin?.requestExactAlarmsPermission();
  }

  Future<void> syncPracticeReminders(List<Map<String, dynamic>> slots) async {
    if (kIsWeb) return;

    for (var index = 0; index < slots.length; index++) {
      final slot = slots[index];
      final enabled = slot['enabled'] == true;
      if (enabled) {
        await schedulePracticeReminder(index, slot);
      } else {
        await cancelPracticeReminder(index);
      }
    }
  }

  Future<void> schedulePracticeReminder(
    int index,
    Map<String, dynamic> slot,
  ) async {
    if (kIsWeb) return;

    final hour = (slot['hour'] as num?)?.toInt() ?? 7;
    final minute = (slot['minute'] as num?)?.toInt() ?? 0;
    final name = slot['name']?.toString() ?? '每日功法';
    final scheduledDate = _nextTime(hour, minute);

    const androidDetails = AndroidNotificationDetails(
      'daily_practice',
      '每日功法提醒',
      channelDescription: '用于提醒每日功法、晨起吐纳与子时静修',
      importance: Importance.high,
      priority: Priority.high,
      icon: 'ic_stat_notification',
    );
    const details = NotificationDetails(
      android: androidDetails,
      iOS: DarwinNotificationDetails(),
    );

    await _plugin.zonedSchedule(
      id: 1000 + index,
      title: '该运转周天了',
      body: '$name 已至，完成今日功法可增修为与功德。',
      scheduledDate: scheduledDate,
      notificationDetails: details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
      payload: 'daily_practice_$index',
    );
  }

  Future<void> cancelPracticeReminder(int index) {
    if (kIsWeb) return Future<void>.value();

    return _plugin.cancel(id: 1000 + index);
  }

  tz.TZDateTime _nextTime(int hour, int minute) {
    final now = tz.TZDateTime.now(tz.local);
    var scheduled = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      hour,
      minute,
    );
    if (!scheduled.isAfter(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }
    return scheduled;
  }
}

class AppState extends ChangeNotifier {
  AppState._(this._box);

  static const String _stateKey = 'state';
  final Box<dynamic>? _box;

  String realm = '练气期一层';
  int cultivation = 120;
  int maxCultivation = 500;
  int merit = 60;
  int innerDemons = 2;
  String todayKey = _dateKey(DateTime.now());

  List<Map<String, dynamic>> todayTasks = [
    {
      'title': '晨起打坐吐纳',
      'type': '习惯',
      'done': false,
      'difficulty': '人阶',
      'quadrant': '仙道根基(重要不紧急)',
    },
    {
      'title': '研读玉简 (阅读30分钟)',
      'type': '习惯',
      'done': false,
      'difficulty': '人阶',
      'quadrant': '仙道根基(重要不紧急)',
    },
    {
      'title': '了结尘缘 (解决核心工作任务)',
      'type': '日程',
      'done': false,
      'difficulty': '地阶',
      'quadrant': '天劫降临(重要且紧急)',
    },
  ];

  List<Map<String, dynamic>> goals = [
    {
      'title': '破境筑基 (上线App第一版)',
      'isExpanded': true,
      'subTasks': [
        {'title': '构建UI原型骨架', 'done': true},
        {'title': '接入本地持久化数据库', 'done': false},
        {'title': '打包测试APK并调优', 'done': false},
      ],
    },
    {
      'title': '研习高深功法 (读完一本心学书籍)',
      'isExpanded': false,
      'subTasks': [
        {'title': '阅读前三章并写内观笔记', 'done': false},
        {'title': '生活实践知行合一', 'done': false},
      ],
    },
  ];

  List<Map<String, dynamic>> rewards = [
    {'title': '饮灵茶一杯 (喝奶茶)', 'cost': 30},
    {'title': '幻境游玩半时辰 (玩游戏1小时)', 'cost': 50},
    {'title': '入市补给法器 (买一件小物)', 'cost': 80},
  ];

  List<Map<String, dynamic>> reminderSlots = [
    {'name': '子时静修', 'hour': 23, 'minute': 0, 'enabled': false},
    {'name': '晨起吐纳', 'hour': 6, 'minute': 30, 'enabled': false},
    {'name': '午间调息', 'hour': 12, 'minute': 15, 'enabled': false},
  ];

  Map<String, Map<String, int>> history = {
    _dateKey(DateTime.now().subtract(const Duration(days: 6))): {
      'completed': 2,
      'total': 3,
      'focusMinutes': 25,
    },
    _dateKey(DateTime.now().subtract(const Duration(days: 5))): {
      'completed': 3,
      'total': 3,
      'focusMinutes': 50,
    },
    _dateKey(DateTime.now().subtract(const Duration(days: 4))): {
      'completed': 1,
      'total': 3,
      'focusMinutes': 0,
    },
    _dateKey(DateTime.now().subtract(const Duration(days: 3))): {
      'completed': 3,
      'total': 3,
      'focusMinutes': 75,
    },
    _dateKey(DateTime.now().subtract(const Duration(days: 2))): {
      'completed': 2,
      'total': 3,
      'focusMinutes': 25,
    },
    _dateKey(DateTime.now().subtract(const Duration(days: 1))): {
      'completed': 3,
      'total': 3,
      'focusMinutes': 25,
    },
  };

  static Future<AppState> create() async {
    if (kIsWeb) {
      final state = AppState._(null);
      state._rolloverIfNeeded();
      return state;
    }

    final box = await Hive.openBox<dynamic>('xiuxian_state');
    final state = AppState._(box);
    state._hydrate();
    state._rolloverIfNeeded();
    unawaited(state._save(notify: false));
    return state;
  }

  int get completedToday =>
      todayTasks.where((task) => task['done'] == true).length;
  int get totalToday => todayTasks.length;
  double get todayRate => totalToday == 0 ? 0 : completedToday / totalToday;

  int get weeklyFocusMinutes {
    final now = DateUtils.dateOnly(DateTime.now());
    var total = 0;
    for (var i = 0; i < 7; i++) {
      final entry = history[_dateKey(now.subtract(Duration(days: i)))];
      total += entry?['focusMinutes'] ?? 0;
    }
    return total;
  }

  double get weeklyCompletionRate {
    final now = DateUtils.dateOnly(DateTime.now());
    var completed = 0;
    var total = 0;
    for (var i = 0; i < 7; i++) {
      final entry = history[_dateKey(now.subtract(Duration(days: i)))];
      completed += entry?['completed'] ?? 0;
      total += entry?['total'] ?? 0;
    }
    return total == 0 ? todayRate : completed / total;
  }

  int completionPercentFor(DateTime date) {
    final entry = history[_dateKey(date)];
    if (entry == null) return 0;
    final total = entry['total'] ?? 0;
    if (total == 0) return 0;
    return (((entry['completed'] ?? 0) / total) * 100)
        .round()
        .clamp(0, 100)
        .toInt();
  }

  void markTaskDone(int index) {
    if (index < 0 || index >= todayTasks.length) return;
    final task = todayTasks[index];
    if (task['done'] == true) return;

    task['done'] = true;
    cultivation += switch (_safeDifficulty(task['difficulty'])) {
      '天阶' => 90,
      '地阶' => 60,
      _ => 40,
    };
    merit += _safeTaskType(task['type']) == '习惯' ? 10 : 15;
    _normalizeRealm();
    _save();
  }

  void addTodayTask(
    String title, {
    String type = '日程',
    String difficulty = '人阶',
    String? quadrant,
  }) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    final safeType = _safeTaskType(type);
    todayTasks.add({
      'title': trimmed,
      'type': safeType,
      'done': false,
      'difficulty': _safeDifficulty(difficulty),
      'quadrant': _safeQuadrant(quadrant, safeType),
    });
    _save();
  }

  void updateTodayTask(
    int index, {
    required String title,
    required String type,
    required String difficulty,
    required String quadrant,
  }) {
    if (index < 0 || index >= todayTasks.length) return;
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    final safeType = _safeTaskType(type);
    todayTasks[index] = {
      ...todayTasks[index],
      'title': trimmed,
      'type': safeType,
      'difficulty': _safeDifficulty(difficulty),
      'quadrant': _safeQuadrant(quadrant, safeType),
    };
    _save();
  }

  void deleteTodayTask(int index) {
    if (index < 0 || index >= todayTasks.length) return;
    todayTasks.removeAt(index);
    _save();
  }

  void toggleGoalExpansion(int index, bool value) {
    if (index < 0 || index >= goals.length) return;
    goals[index]['isExpanded'] = value;
    _save();
  }

  void toggleSubTask(int goalIndex, int subIndex, bool value) {
    if (goalIndex < 0 || goalIndex >= goals.length) return;
    final subTasks = _mapList(goals[goalIndex]['subTasks']);
    if (subIndex < 0 || subIndex >= subTasks.length) return;

    final wasDone = subTasks[subIndex]['done'] == true;
    subTasks[subIndex]['done'] = value;
    goals[goalIndex]['subTasks'] = subTasks;
    if (value && !wasDone) {
      cultivation += 20;
      merit += 5;
    }
    _normalizeRealm();
    _save();
  }

  void addGoal(String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    goals.add({
      'title': trimmed,
      'isExpanded': true,
      'subTasks': <Map<String, dynamic>>[],
    });
    _save();
  }

  void addSubTask(int goalIndex, String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty || goalIndex < 0 || goalIndex >= goals.length) return;
    final subTasks = _mapList(goals[goalIndex]['subTasks']);
    subTasks.add({'title': trimmed, 'done': false});
    goals[goalIndex]['subTasks'] = subTasks;
    goals[goalIndex]['isExpanded'] = true;
    _save();
  }

  void completeFocusSession({int minutes = 25}) {
    cultivation += 60;
    merit += 15;
    final current =
        history[todayKey] ??
        {'completed': completedToday, 'total': totalToday, 'focusMinutes': 0};
    current['focusMinutes'] = (current['focusMinutes'] ?? 0) + minutes;
    history[todayKey] = current;
    _normalizeRealm();
    _save();
  }

  void removeDemon() {
    if (innerDemons <= 0 || merit < 20) return;
    innerDemons -= 1;
    merit -= 20;
    _save();
  }

  void redeemReward(int index) {
    if (index < 0 || index >= rewards.length) return;
    final cost = (rewards[index]['cost'] as num?)?.toInt() ?? 0;
    if (merit < cost) return;
    merit -= cost;
    _save();
  }

  Future<void> setReminderEnabled(int index, bool enabled) async {
    if (index < 0 || index >= reminderSlots.length) return;
    reminderSlots[index]['enabled'] = enabled;
    await _save();
    if (enabled) {
      await NotificationService.instance.schedulePracticeReminder(
        index,
        reminderSlots[index],
      );
    } else {
      await NotificationService.instance.cancelPracticeReminder(index);
    }
  }

  Future<void> setReminderTime(int index, TimeOfDay time) async {
    if (index < 0 || index >= reminderSlots.length) return;
    reminderSlots[index]['hour'] = time.hour;
    reminderSlots[index]['minute'] = time.minute;
    reminderSlots[index]['enabled'] = true;
    await _save();
    await NotificationService.instance.schedulePracticeReminder(
      index,
      reminderSlots[index],
    );
  }

  void _hydrate() {
    final box = _box;
    if (box == null) return;

    final snapshot = _stringDynamicMap(box.get(_stateKey));
    if (snapshot.isEmpty) return;

    realm = snapshot['realm']?.toString() ?? realm;
    cultivation = (snapshot['cultivation'] as num?)?.toInt() ?? cultivation;
    maxCultivation =
        (snapshot['maxCultivation'] as num?)?.toInt() ?? maxCultivation;
    merit = (snapshot['merit'] as num?)?.toInt() ?? merit;
    innerDemons = (snapshot['innerDemons'] as num?)?.toInt() ?? innerDemons;
    todayKey = snapshot['todayKey']?.toString() ?? todayKey;

    final loadedTasks = _mapList(snapshot['todayTasks']);
    if (loadedTasks.isNotEmpty) {
      todayTasks = loadedTasks.map((task) {
        final type = _safeTaskType(task['type']);
        return {
          ...task,
          'type': type,
          'done': task['done'] == true,
          'difficulty': _safeDifficulty(task['difficulty']),
          'quadrant': _safeQuadrant(task['quadrant'], type),
        };
      }).toList();
    }
    final loadedGoals = _mapList(snapshot['goals']);
    if (loadedGoals.isNotEmpty) goals = loadedGoals;
    final loadedRewards = _mapList(snapshot['rewards']);
    if (loadedRewards.isNotEmpty) rewards = loadedRewards;
    final loadedSlots = _mapList(snapshot['reminderSlots']);
    if (loadedSlots.isNotEmpty) reminderSlots = loadedSlots;

    final loadedHistory = _stringDynamicMap(snapshot['history']);
    if (loadedHistory.isNotEmpty) {
      history = loadedHistory.map((key, value) {
        final entry = _stringDynamicMap(value);
        return MapEntry(key, {
          'completed': (entry['completed'] as num?)?.toInt() ?? 0,
          'total': (entry['total'] as num?)?.toInt() ?? 0,
          'focusMinutes': (entry['focusMinutes'] as num?)?.toInt() ?? 0,
        });
      });
    }
  }

  void _rolloverIfNeeded() {
    final currentKey = _dateKey(DateTime.now());
    if (todayKey == currentKey) {
      _updateTodayHistory();
      return;
    }

    _updateTodayHistory();
    todayKey = currentKey;
    for (final task in todayTasks) {
      task['done'] = false;
    }
    _updateTodayHistory();
  }

  void _normalizeRealm() {
    const realms = ['练气期一层', '练气期二层', '练气期三层', '筑基初期', '筑基中期', '金丹初成'];
    while (cultivation >= maxCultivation) {
      cultivation -= maxCultivation;
      final index = realms.indexOf(realm);
      realm = realms[(index + 1).clamp(0, realms.length - 1).toInt()];
      maxCultivation = (maxCultivation * 1.35).round();
      merit += 30;
      innerDemons += 1;
      if (realm == realms.last) break;
    }
  }

  void _updateTodayHistory() {
    final current =
        history[todayKey] ??
        {'completed': 0, 'total': totalToday, 'focusMinutes': 0};
    history[todayKey] = {
      'completed': completedToday,
      'total': totalToday,
      'focusMinutes': current['focusMinutes'] ?? 0,
    };
  }

  Future<void> _save({bool notify = true}) async {
    _updateTodayHistory();
    final box = _box;
    if (box != null) {
      await box.put(_stateKey, {
        'realm': realm,
        'cultivation': cultivation,
        'maxCultivation': maxCultivation,
        'merit': merit,
        'innerDemons': innerDemons,
        'todayKey': todayKey,
        'todayTasks': todayTasks,
        'goals': goals,
        'rewards': rewards,
        'reminderSlots': reminderSlots,
        'history': history,
      });
    }
    if (notify) notifyListeners();
  }
}

class TaoistApp extends StatelessWidget {
  const TaoistApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        return MaterialApp(
          title: '天道酬勤',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            scaffoldBackgroundColor: AppColors.paperBg,
            colorScheme: ColorScheme.fromSeed(
              seedColor: AppColors.bambooGreen,
              primary: AppColors.bambooGreen,
              secondary: AppColors.ancientGold,
              surface: AppColors.paperBg,
            ),
            appBarTheme: const AppBarTheme(
              backgroundColor: AppColors.paperBg,
              elevation: 0,
              centerTitle: true,
              titleTextStyle: TextStyle(
                color: AppColors.bambooGreen,
                fontSize: 18,
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
              ),
              iconTheme: IconThemeData(color: AppColors.bambooGreen),
            ),
            bottomNavigationBarTheme: const BottomNavigationBarThemeData(
              backgroundColor: AppColors.paperBg,
              selectedItemColor: AppColors.ancientGold,
              unselectedItemColor: AppColors.inkGrey,
              type: BottomNavigationBarType.fixed,
            ),
          ),
          home: MainContainer(state: state),
        );
      },
    );
  }
}

class MainContainer extends StatefulWidget {
  const MainContainer({super.key, required this.state});

  final AppState state;

  @override
  State<MainContainer> createState() => _MainContainerState();
}

class _MainContainerState extends State<MainContainer> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomeCaveView(state: widget.state),
      GoalsView(state: widget.state),
      StatsView(state: widget.state),
      SanctuaryView(state: widget.state),
    ];

    return Scaffold(
      body: SafeArea(child: pages[_currentIndex]),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home_outlined),
            activeIcon: Icon(Icons.home),
            label: '洞府今日',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.layers_outlined),
            activeIcon: Icon(Icons.layers),
            label: '宏愿拆解',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.insights_outlined),
            activeIcon: Icon(Icons.insights),
            label: '天道统计',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.self_improvement_outlined),
            activeIcon: Icon(Icons.self_improvement),
            label: '定心闭关',
          ),
        ],
      ),
    );
  }
}

class HomeCaveView extends StatelessWidget {
  const HomeCaveView({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final taskEntries =
        List.generate(
          state.todayTasks.length,
          (index) => MapEntry(index, state.todayTasks[index]),
        )..sort((a, b) {
          final aType = _safeTaskType(a.value['type']);
          final bType = _safeTaskType(b.value['type']);
          final aQuadrant = _safeQuadrant(a.value['quadrant'], aType);
          final bQuadrant = _safeQuadrant(b.value['quadrant'], bType);
          return _quadrantWeight(
            bQuadrant,
          ).compareTo(_quadrantWeight(aQuadrant));
        });

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _RealmPanel(state: state),
        const SizedBox(height: 18),
        const Text(
          '今日缘起日程',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: AppColors.bambooGreen,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 10),
        ...taskEntries.map((entry) {
          final index = entry.key;
          final item = entry.value;
          final type = _safeTaskType(item['type']);
          final difficulty = _safeDifficulty(item['difficulty']);
          final quadrant = _safeQuadrant(item['quadrant'], type);
          final qColor = _quadrantColor(quadrant);
          return Dismissible(
            key: ValueKey('today-task-$index-${item['title']}-${item['done']}'),
            direction: DismissDirection.endToStart,
            confirmDismiss: (_) => _confirmDeleteTask(
              context,
              item['title']?.toString() ?? '这件功课',
            ),
            onDismissed: (_) => state.deleteTodayTask(index),
            background: Container(
              margin: const EdgeInsets.symmetric(vertical: 6),
              padding: const EdgeInsets.symmetric(horizontal: 18),
              alignment: Alignment.centerRight,
              decoration: BoxDecoration(
                color: AppColors.demonRed,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.delete_outline, color: Colors.white),
            ),
            child: Card(
              elevation: 0,
              color: Colors.white.withValues(alpha: 0.72),
              margin: const EdgeInsets.symmetric(vertical: 6),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(color: qColor.withValues(alpha: 0.35)),
              ),
              child: ListTile(
                onTap: () => _showTaskDialog(context, index: index),
                leading: _BaguaBadge(label: type),
                title: Text(
                  item['title']?.toString() ?? '',
                  style: TextStyle(
                    color: item['done'] == true
                        ? AppColors.inkGrey
                        : AppColors.bambooGreen,
                    decoration: item['done'] == true
                        ? TextDecoration.lineThrough
                        : null,
                  ),
                ),
                subtitle: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    _TaskMetaChip(
                      label: difficulty,
                      color: AppColors.ancientGold,
                    ),
                    _TaskMetaChip(
                      label: _quadrantShortName(quadrant),
                      color: qColor,
                    ),
                  ],
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '编辑',
                      icon: const Icon(
                        Icons.edit_outlined,
                        color: AppColors.inkGrey,
                      ),
                      onPressed: () => _showTaskDialog(context, index: index),
                    ),
                    IconButton(
                      tooltip: '打卡',
                      icon: Icon(
                        item['done'] == true
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        color: AppColors.ancientGold,
                      ),
                      onPressed: item['done'] == true
                          ? null
                          : () => state.markTaskDone(index),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => _showTaskDialog(context),
          icon: const Icon(Icons.add_task),
          label: const Text('添一件今日功课'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.bambooGreen,
          ),
        ),
        const SizedBox(height: 18),
        _ReminderPanel(state: state),
      ],
    );
  }

  Future<void> _showTaskDialog(BuildContext context, {int? index}) async {
    final editing = index != null;
    final task = editing ? state.todayTasks[index] : null;
    final initialType = _safeTaskType(task?['type']);
    final controller = TextEditingController(
      text: task?['title']?.toString() ?? '',
    );
    var type = initialType;
    var difficulty = _safeDifficulty(task?['difficulty']);
    var quadrant = _safeQuadrant(task?['quadrant'], initialType);
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(editing ? '编辑今日功课' : '新增今日功课'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: controller,
                    autofocus: true,
                    decoration: const InputDecoration(hintText: '例如：整理修行笔记'),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: type,
                    decoration: const InputDecoration(labelText: '类别'),
                    items: _taskTypes
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text(value),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      setDialogState(() {
                        final nextType = value ?? type;
                        if (nextType != type &&
                            quadrant == _defaultQuadrantForType(type)) {
                          quadrant = _defaultQuadrantForType(nextType);
                        }
                        type = nextType;
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: difficulty,
                    decoration: const InputDecoration(labelText: '难度'),
                    items: _taskDifficulties
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text(value),
                          ),
                        )
                        .toList(),
                    onChanged: (value) =>
                        setDialogState(() => difficulty = value ?? difficulty),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: quadrant,
                    decoration: const InputDecoration(labelText: '四象限'),
                    items: _taskQuadrants
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text(
                              value,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (value) =>
                        setDialogState(() => quadrant = value ?? quadrant),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
    final title = controller.text;
    controller.dispose();
    if (saved != true) return;
    if (editing) {
      state.updateTodayTask(
        index,
        title: title,
        type: type,
        difficulty: difficulty,
        quadrant: quadrant,
      );
    } else {
      state.addTodayTask(
        title,
        type: type,
        difficulty: difficulty,
        quadrant: quadrant,
      );
    }
  }

  Future<bool> _confirmDeleteTask(BuildContext context, String title) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('删除今日功课'),
          content: Text('确定删除“$title”吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.demonRed,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    return confirmed == true;
  }

  Color _quadrantColor(String quadrant) {
    if (quadrant.contains('天劫')) return AppColors.demonRed;
    if (quadrant.contains('根基')) return AppColors.bambooGreen;
    if (quadrant.contains('俗务')) return AppColors.ancientGold;
    return AppColors.inkGrey;
  }
}

class _TaskMetaChip extends StatelessWidget {
  const _TaskMetaChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _RealmPanel extends StatelessWidget {
  const _RealmPanel({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: AppColors.ancientGold.withValues(alpha: 0.25),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const _BaguaDisc(),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      state.realm,
                      style: const TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.bold,
                        color: AppColors.bambooGreen,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '今日完成 ${state.completedToday}/${state.totalToday}',
                      style: const TextStyle(
                        color: AppColors.inkGrey,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                '功德 ${state.merit}\n心魔 ${state.innerDemons}',
                textAlign: TextAlign.right,
                style: const TextStyle(
                  color: AppColors.ancientGold,
                  fontWeight: FontWeight.bold,
                  height: 1.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '灵气凝聚',
                style: TextStyle(color: AppColors.inkGrey, fontSize: 12),
              ),
              Text(
                '${state.cultivation}/${state.maxCultivation}',
                style: const TextStyle(
                  color: AppColors.bambooGreen,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: (state.cultivation / state.maxCultivation)
                .clamp(0, 1)
                .toDouble(),
            backgroundColor: Colors.white,
            color: AppColors.ancientGold,
            minHeight: 7,
            borderRadius: BorderRadius.circular(99),
          ),
        ],
      ),
    );
  }
}

class _BaguaDisc extends StatelessWidget {
  const _BaguaDisc();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 54,
      height: 54,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.bambooGreen,
        border: Border.all(color: AppColors.ancientGold, width: 2),
      ),
      child: const Center(
        child: Text(
          '☯\n乾坤',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.paperBg,
            fontSize: 12,
            height: 1.1,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

class _BaguaBadge extends StatelessWidget {
  const _BaguaBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final isHabit = label == '习惯';
    return Container(
      width: 46,
      height: 46,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isHabit ? AppColors.bambooGreen : AppColors.cardBg,
        border: Border.all(color: AppColors.ancientGold.withValues(alpha: 0.6)),
      ),
      child: Text(
        isHabit ? '巽\n$label' : '坤\n$label',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: isHabit ? Colors.white : AppColors.ancientGold,
          fontSize: 10,
          height: 1.15,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _ReminderPanel extends StatelessWidget {
  const _ReminderPanel({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.notifications_active_outlined,
                size: 18,
                color: AppColors.ancientGold,
              ),
              SizedBox(width: 8),
              Text(
                '每日功法提醒',
                style: TextStyle(
                  color: AppColors.bambooGreen,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...List.generate(state.reminderSlots.length, (index) {
            final slot = state.reminderSlots[index];
            final hour = (slot['hour'] as num?)?.toInt() ?? 0;
            final minute = (slot['minute'] as num?)?.toInt() ?? 0;
            final label =
                '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(
                slot['name']?.toString() ?? '提醒',
                style: const TextStyle(color: AppColors.bambooGreen),
              ),
              subtitle: Text(
                label,
                style: const TextStyle(color: AppColors.inkGrey),
              ),
              leading: const Icon(
                Icons.access_time,
                color: AppColors.ancientGold,
              ),
              trailing: Switch(
                value: slot['enabled'] == true,
                activeThumbColor: AppColors.ancientGold,
                onChanged: (value) =>
                    unawaited(state.setReminderEnabled(index, value)),
              ),
              onTap: () async {
                final picked = await showTimePicker(
                  context: context,
                  initialTime: TimeOfDay(hour: hour, minute: minute),
                  builder: (context, child) {
                    return Theme(
                      data: Theme.of(context).copyWith(
                        colorScheme: Theme.of(
                          context,
                        ).colorScheme.copyWith(primary: AppColors.bambooGreen),
                      ),
                      child: child!,
                    );
                  },
                );
                if (picked != null) {
                  await state.setReminderTime(index, picked);
                }
              },
            );
          }),
        ],
      ),
    );
  }
}

class GoalsView extends StatelessWidget {
  const GoalsView({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('宏愿与因果拆解')),
      floatingActionButton: FloatingActionButton(
        backgroundColor: AppColors.bambooGreen,
        foregroundColor: Colors.white,
        onPressed: () => _showGoalDialog(context),
        child: const Icon(Icons.add),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: state.goals.length,
        itemBuilder: (context, index) {
          final goal = state.goals[index];
          final subTasks = _mapList(goal['subTasks']);
          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.cardBg),
            ),
            child: ExpansionTile(
              initiallyExpanded: goal['isExpanded'] == true,
              onExpansionChanged: (value) =>
                  state.toggleGoalExpansion(index, value),
              title: Text(
                goal['title']?.toString() ?? '',
                style: const TextStyle(
                  color: AppColors.bambooGreen,
                  fontWeight: FontWeight.bold,
                ),
              ),
              subtitle: Text(
                '因果 ${subTasks.where((item) => item['done'] == true).length}/${subTasks.length}',
                style: const TextStyle(color: AppColors.inkGrey),
              ),
              leading: const Icon(
                Icons.auto_awesome,
                color: AppColors.ancientGold,
                size: 18,
              ),
              children: [
                for (var subIndex = 0; subIndex < subTasks.length; subIndex++)
                  CheckboxListTile(
                    title: Text(
                      subTasks[subIndex]['title']?.toString() ?? '',
                      style: TextStyle(
                        color: subTasks[subIndex]['done'] == true
                            ? AppColors.inkGrey
                            : AppColors.bambooGreen,
                      ),
                    ),
                    value: subTasks[subIndex]['done'] == true,
                    activeColor: AppColors.ancientGold,
                    onChanged: (value) =>
                        state.toggleSubTask(index, subIndex, value ?? false),
                  ),
                TextButton.icon(
                  onPressed: () => _showSubTaskDialog(context, index),
                  icon: const Icon(Icons.add_circle_outline, size: 18),
                  label: const Text('添一段因果'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.ancientGold,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _showGoalDialog(BuildContext context) async {
    final controller = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('立下宏愿'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: '例如：三个月内完成第一版上线'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (title != null) state.addGoal(title);
  }

  Future<void> _showSubTaskDialog(BuildContext context, int goalIndex) async {
    final controller = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('添一段因果'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: '例如：完成登录页与本地存储'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (title != null) state.addSubTask(goalIndex, title);
  }
}

class StatsView extends StatefulWidget {
  const StatsView({super.key, required this.state});

  final AppState state;

  @override
  State<StatsView> createState() => _StatsViewState();
}

class _StatsViewState extends State<StatsView> {
  CalendarFormat _calendarFormat = CalendarFormat.month;
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return Scaffold(
      appBar: AppBar(title: const Text('天道运转总结')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.cardBg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: TableCalendar<Map<String, int>>(
              locale: 'zh_CN',
              firstDay: DateTime.utc(2024),
              lastDay: DateTime.utc(2035, 12, 31),
              focusedDay: _focusedDay,
              calendarFormat: _calendarFormat,
              selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
              availableCalendarFormats: const {
                CalendarFormat.month: '月',
                CalendarFormat.twoWeeks: '双周',
                CalendarFormat.week: '周',
              },
              eventLoader: (day) {
                final percent = state.completionPercentFor(day);
                return percent == 0
                    ? []
                    : [state.history[_dateKey(day)] ?? <String, int>{}];
              },
              onDaySelected: (selectedDay, focusedDay) {
                setState(() {
                  _selectedDay = selectedDay;
                  _focusedDay = focusedDay;
                });
              },
              onFormatChanged: (format) =>
                  setState(() => _calendarFormat = format),
              onPageChanged: (focusedDay) => _focusedDay = focusedDay,
              headerStyle: const HeaderStyle(
                titleCentered: true,
                formatButtonShowsNext: false,
                titleTextStyle: TextStyle(
                  color: AppColors.bambooGreen,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
                formatButtonDecoration: BoxDecoration(
                  color: AppColors.bambooGreen,
                  borderRadius: BorderRadius.all(Radius.circular(6)),
                ),
                formatButtonTextStyle: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                ),
                leftChevronIcon: Icon(
                  Icons.chevron_left,
                  color: AppColors.ancientGold,
                ),
                rightChevronIcon: Icon(
                  Icons.chevron_right,
                  color: AppColors.ancientGold,
                ),
              ),
              daysOfWeekStyle: const DaysOfWeekStyle(
                weekdayStyle: TextStyle(
                  color: AppColors.inkGrey,
                  fontWeight: FontWeight.bold,
                ),
                weekendStyle: TextStyle(
                  color: AppColors.demonRed,
                  fontWeight: FontWeight.bold,
                ),
              ),
              calendarStyle: CalendarStyle(
                outsideDaysVisible: false,
                todayDecoration: BoxDecoration(
                  color: AppColors.ancientGold.withValues(alpha: 0.35),
                  shape: BoxShape.circle,
                ),
                selectedDecoration: const BoxDecoration(
                  color: AppColors.bambooGreen,
                  shape: BoxShape.circle,
                ),
                weekendTextStyle: const TextStyle(color: AppColors.demonRed),
                defaultTextStyle: const TextStyle(color: AppColors.bambooGreen),
                markersMaxCount: 1,
                markerDecoration: const BoxDecoration(
                  color: AppColors.ancientGold,
                  shape: BoxShape.circle,
                ),
              ),
              calendarBuilders: CalendarBuilders<Map<String, int>>(
                markerBuilder: (context, day, events) {
                  final percent = state.completionPercentFor(day);
                  if (percent == 0) return null;
                  final color = percent >= 80
                      ? AppColors.jade
                      : percent >= 50
                      ? AppColors.ancientGold
                      : AppColors.cinnabar;
                  return Positioned(
                    bottom: 6,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                          ),
                        ),
                        if (percent == 100) ...[
                          const SizedBox(width: 3),
                          Container(
                            width: 4,
                            height: 4,
                            decoration: const BoxDecoration(
                              color: AppColors.bambooGreen,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 18),
          _StatsSummary(state: state),
        ],
      ),
    );
  }
}

class _StatsSummary extends StatelessWidget {
  const _StatsSummary({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final rate = (state.weeklyCompletionRate * 100).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '修行统计',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: AppColors.bambooGreen,
          ),
        ),
        const SizedBox(height: 12),
        _buildStatRow(
          '本周闭关入定',
          '${state.weeklyFocusMinutes} 分钟',
          state.weeklyFocusMinutes / 180,
        ),
        _buildStatRow('因果了结率', '$rate %', rate / 100),
        _buildStatRow(
          '今日功课完成',
          '${(state.todayRate * 100).round()} %',
          state.todayRate,
        ),
      ],
    );
  }

  Widget _buildStatRow(String label, String value, double progress) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: const TextStyle(color: AppColors.inkGrey)),
              Text(
                value,
                style: const TextStyle(
                  color: AppColors.bambooGreen,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: progress.clamp(0, 1).toDouble(),
            backgroundColor: AppColors.cardBg,
            color: AppColors.ancientGold,
            minHeight: 6,
            borderRadius: BorderRadius.circular(99),
          ),
        ],
      ),
    );
  }
}

class SanctuaryView extends StatefulWidget {
  const SanctuaryView({super.key, required this.state});

  final AppState state;

  @override
  State<SanctuaryView> createState() => _SanctuaryViewState();
}

class _SanctuaryViewState extends State<SanctuaryView> {
  static const int _sessionSeconds = 25 * 60;
  Timer? _timer;
  bool _isFocusing = false;
  int _remainingSeconds = _sessionSeconds;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _toggleFocus() {
    if (_isFocusing) {
      _finishFocus();
      return;
    }

    setState(() {
      _isFocusing = true;
      _remainingSeconds = _sessionSeconds;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_remainingSeconds <= 1) {
        _finishFocus();
      } else {
        setState(() => _remainingSeconds -= 1);
      }
    });
  }

  void _finishFocus() {
    _timer?.cancel();
    if (!_isFocusing) return;
    setState(() {
      _isFocusing = false;
      _remainingSeconds = _sessionSeconds;
    });
    widget.state.completeFocusSession();
  }

  @override
  Widget build(BuildContext context) {
    final minutes = (_remainingSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (_remainingSeconds % 60).toString().padLeft(2, '0');
    return Scaffold(
      appBar: AppBar(title: const Text('定心冥想与藏宝阁')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.cardBg),
            ),
            child: Column(
              children: [
                Icon(
                  _isFocusing ? Icons.hourglass_top : Icons.self_improvement,
                  size: 58,
                  color: AppColors.ancientGold,
                ),
                const SizedBox(height: 10),
                Text(
                  _isFocusing ? '真气运转，万念归一' : '灵台清静，方能入定',
                  style: const TextStyle(
                    color: AppColors.bambooGreen,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '$minutes:$seconds',
                  style: const TextStyle(
                    color: AppColors.nightInk,
                    fontSize: 44,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: _isFocusing
                        ? AppColors.demonRed
                        : AppColors.bambooGreen,
                  ),
                  onPressed: _toggleFocus,
                  icon: Icon(_isFocusing ? Icons.stop : Icons.play_arrow),
                  label: Text(_isFocusing ? '提前出关并结算' : '开始闭关香'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _DemonPanel(state: widget.state)),
              const SizedBox(width: 12),
              Expanded(child: _RewardPanel(state: widget.state)),
            ],
          ),
        ],
      ),
    );
  }
}

class _DemonPanel extends StatelessWidget {
  const _DemonPanel({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          const Icon(Icons.blur_circular, color: AppColors.demonRed),
          const SizedBox(height: 6),
          const Text(
            '法阵消魔',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: AppColors.demonRed,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '心魔 ${state.innerDemons}',
            style: const TextStyle(fontSize: 12, color: AppColors.inkGrey),
          ),
          const SizedBox(height: 12),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.demonRed,
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            onPressed: state.innerDemons > 0 && state.merit >= 20
                ? state.removeDemon
                : null,
            child: const Text('扣20功德', style: TextStyle(fontSize: 11)),
          ),
        ],
      ),
    );
  }
}

class _RewardPanel extends StatelessWidget {
  const _RewardPanel({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          const Icon(Icons.card_giftcard, color: AppColors.ancientGold),
          const SizedBox(height: 6),
          const Text(
            '藏宝阁',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: AppColors.ancientGold,
            ),
          ),
          const SizedBox(height: 8),
          ...List.generate(state.rewards.length, (index) {
            final reward = state.rewards[index];
            final cost = (reward['cost'] as num?)?.toInt() ?? 0;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.ancientGold,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                onPressed: state.merit >= cost
                    ? () => state.redeemReward(index)
                    : null,
                child: Text(
                  '${reward['title']} ($cost)',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 10),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}
