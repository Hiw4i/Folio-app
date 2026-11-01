# Reader benchmarks — процедуры запуска

Точные команды измерений ридера. Всё выполняется из корня проекта;
`<device>` — фактический ID устройства (`flutter devices`). Численные
выводы — только в profile/release на физическом устройстве (см.
`docs/benchmarks/protocol.md`).

## 0. Подготовка корпуса на устройстве

```bash
python tools/reader_benchmarks/generate_corpus.py   # детерминированный корпус + manifest
adb -s <device> push test/fixtures/reader_corpus /data/local/tmp/folio_corpus
```

## 1. Исходные замеры открытия и кадров (v1 harness)

```bash
flutter test integration_test/reader_performance_test.dart -d <device> --profile \
  --dart-define=FOLIO_PERF_CORPUS_DIR=/data/local/tmp/folio_corpus
```

- В консоли ищется строка `PERF_RESULTS {json}` — это артефакт отчёта;
  сохранить её в `docs/benchmarks/` рядом с отчётом прогона.
- Файл измеряет: холодное открытие (готовность форматного view), окно
  FrameTiming 3 с после готовности (UI/raster p50/p95/p99, доля кадров сверх
  бюджетов 16,67/8,33 мс) и 3 повторных открытия того же файла.
- PSS и FrameTimeline в harness не входят — снимаются внешне (ниже).

## 2. Память (PSS) — внешняя процедура

```bash
# до цикла
adb -s <device> shell pidof com.example.folio
# цикл 20 открытий/закрытий выполняется вручную или отдельным сценарием
adb -s <device> shell dumpsys meminfo com.example.folio
```

Фиксировать: Total PSS всех процессов приложения, включая WebView renderer
(`com.example.folio:sandboxed_process*` / `privileged_process`).

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
SHA коммита и lockfile, сырые данные (PERF_RESULTS строка, dumpsys вывод,
pftrace), доля пропущенных кадров. Эмуляторные прогоны помечаются
«эмулятор» и не сравниваются с телефонными числами.

## 5. Воспроизводимость исходной версии

Базовая точка фиксируется git-тегом на коммите baseline (см.
`docs/benchmarks/reader-baseline.md`); исходная версия воспроизводится
отдельным checkout по тегу, без отката рабочего дерева.
