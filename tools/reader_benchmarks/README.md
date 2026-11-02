# Reader benchmarks — процедуры запуска

Точные команды измерений ридера (harness v2). Всё выполняется из корня
проекта; `<device>` — фактический ID устройства (`flutter devices`).
Численные выводы — только в profile/release на физическом устройстве
(см. `docs/benchmarks/protocol.md`).

## 0. Подготовка корпуса на устройстве

```bash
python tools/reader_benchmarks/generate_corpus.py     # корпус + manifest
tar czf corpus.tar.gz -C test/fixtures reader_corpus  # артефакт для пуша
adb -s <device> push corpus.tar.gz /data/local/tmp/
```

Корпус кладётся во ВНУТРЕННИЙ каталог приложения через `run-as`
(сборка integration-теста debuggable). Почему не внешний: install стирает
его содержимое, а на Android 17 путь
`/storage/emulated/0/Android/data/<pkg>` запрещён приложению даже на
чтение (errno 13). Внутренний путь работает на всех проверенных
устройствах; `--strip-components=1` обязателен (в архиве верхний каталог
`reader_corpus/`).

## 1. Замеры открытия и кадров (harness v2)

Проверенная процедура (выводы 2026-11-01/02):

1. `flutter test --profile` не существует; численные прогоны идут через
   `flutter run --profile` с integration-целью (`flutter drive` тоже
   работает, но переустанавливает приложение и стирает его данные).
2. Harness печатает `PERF_WAITING_FOR_CORPUS <dir>` и ждёт корпус до
   3 минут — пушите архив ПОСЛЕ запуска приложения:
   ```bash
   flutter run --profile -d <device> integration_test/reader_performance_test.dart \
     --dart-define=FOLIO_PERF_CORPUS_DIR=/data/data/com.example.folio/files/folio_corpus
   # после запуска приложения:
   adb -s <device> shell "run-as com.example.folio mkdir -p files/folio_corpus"
   adb -s <device> shell "run-as com.example.folio cp /data/local/tmp/corpus.tar.gz files/corpus.tar.gz"
   adb -s <device> shell "run-as com.example.folio tar xzf files/corpus.tar.gz -C files/folio_corpus --strip-components=1"
   ```
3. Экран устройства должен гореть, а телефон — никем не использоваться:
   касания по экрану валят integration-тесты, а потухший экран — «Lost
   connection». На время прогона: `adb shell svc power stayon true`,
   после — вернуть `false`.
4. Офлайн-движок в harness монтируется через `AnimatedBuilder(renderer)`,
   как в проде: view создаётся только после `prepare`. Без слушателя
   сцена не перестроится и Office никогда не станет `ready`.

Что измеряется на каждый из 8 файлов корпуса: 1 fresh-process cold
+ 10 cache-warm повторов, 3 с settle-окно и 10 с управляемое окно
(свипы seek/scroll через те же API рендереров, что вызывают продовые
навигационные адаптеры). Отчёт: UI/raster p50/p95/p99 и доля кадров сверх
бюджетов 16,67/8,33 мс, отдельно для settle и driven окон.

- Артефакт: `perf_results.json` в каталоге рядом с корпусом на устройстве
  (забрать через `run-as ... cat files/perf_results.json`); дублируется в
  консоль построчно как `PERF_RESULT_LINE <chunk>` — цельный JSON собрать
  конкатенацией чанков.

## 2. Память (PSS) — циклы открытия/закрытия

```bash
flutter run --profile -d <device> integration_test/reader_memory_cycles_test.dart \
  --dart-define=FOLIO_PERF_CORPUS_DIR=/data/data/com.example.folio/files/folio_corpus
# та же раскладка корпуса (раздел 1), затем во время прогона:
adb -s <device> shell pidof com.example.folio com.example.folio:sandboxed_process0
adb -s <device> shell dumpsys meminfo <pid>
```

Тест выполняет 20 циклов открытия/закрытия на каждый файл
(`docx_big_images.docx`, `text_searchable_24p.pdf`). Фиксировать: сумму
`TOTAL PSS` по всем процессам приложения (main + WebView renderer);
уровни PSS между прогонами гуляют до ±12 % — оценивайте дрейф внутри
прогона и парные раунды до/после, а не одиночные числа.

## 3. FrameTimeline / Perfetto для native/WebView-части

```bash
adb -s <device> shell perfetto -o /data/misc/perfetto-traces/folio.pftrace \
  -t 20s sched freq gfx view wm am input res
adb -s <device> pull /data/misc/perfetto-traces/folio.pftrace
```

Flutter `FrameTiming` не покрывает WebView; presentation-часть смотрится в
Perfetto отдельно и не складывается с UI/raster механически.

## 4. Что фиксировать в каждом отчёте

Устройство, refresh rate, Android/WebView/Flutter версии, режим сборки,
SHA коммита и lockfile, сырые данные (`perf_results.json` / PERF_RESULT_LINE
чанки, dumpsys вывод, pftrace), доля пропущенных кадров. Эмуляторные прогоны
помечаются «эмулятор» и не сравниваются с телефонными числами.

## 5. Воспроизводимость исходной версии

Базовая точка фиксируется git-тегом на коммите baseline (см.
`docs/benchmarks/reader-baseline.md`); исходная версия воспроизводится
отдельным checkout по тегу, без отката рабочего дерева.
