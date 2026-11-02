# Folio — архитектура и рабочий справочник

Главный документ проекта. Читается перед любой правкой; здесь же — как
запускать тесты на реальном телефоне и список граблей, на которые уже
наступали. Последняя ревизия: 2026-11-02.

Folio — офлайн-читалка документов для Android (PDF, DOCX, PPTX, TXT,
Markdown): бесплатная, без сети, со стеклянным (liquid glass) интерфейсом.

## 1. Структура `lib/`

```
lib/
  main.dart                     # глобальные обработчики ошибок, корень
  app/                          # FolioApp, корневой роутинг внешних открытий
  features/
    library/                    # каталог: сканер (isolate), репозиторий,
                                # контроллер, экран библиотеки
    reader/                     # экран чтения
      logic/                    # КОНТРАКТЫ: document_renderer_contract,
                                # reader_navigation, reader_search_state,
                                # reader_scrub_controller, chrome_visibility,
                                # reader_preloader, renderer_lifecycle
      widgets/                  # reader_screen (общая оболочка),
                                # reader_scrubber, reader_search_navigator,
                                # bindings/  ← ЕДИНСТВЕННОЕ место выбора
                                #   форматного адаптера (reader_binding_factory)
      pdf/  text/  office/      # форматные движки: renderer + view + surface
      word/ powerpoint/         # тонкие наследники office-базы
    settings/                   # folio_settings_*: blur/liquid motion, хранение
  shared/
    theme/                      # app_colors, app_text_styles, app_curves,
                                # app_durations, app_springs — ВСЁ оформление
                                # через эти токены, никаких сырых значений
    glass/                      # liquid glass: surface/, core/, widgets/
    persistence/                # atomic_file (без потери последнего файла),
                                # coalescing_drainer (один писатель)
    diagnostics/app_log.dart    # ЕДИНСТВЕННЫЙ логгер; пустой catch — баг
    selection/ widgets/ utils/  # выделение, лист-обёртки, утилиты
android/                        # Kotlin: OfficePlatformView (WebView-движок),
                                # assets/office/ — локальные HTML/JS ресурсы
```

Ключевые контракты (менять только вдумчиво, они держат всю оболочку):

- `DocumentRenderer` (`logic/document_renderer_contract.dart`) — владелец
  жизненного цикла документа и поиска. Плюс `ReaderSearchSnapshot get
  searchState` — производная проекция, не второе изменяемое состояние.
- `ReaderNavigation` / `ReaderNavigationSnapshot` (`logic/reader_navigation.dart`)
  — позиция и seek без знания форматов. `confirmedFraction == null` значит
  «не измерено», а не «начало документа». `Future` от seek = «команда
  поставлена», НЕ «кадр на экране».
- `ReaderBinding` / `ReaderBindingFactory` (`widgets/bindings/`) — UI-адаптер
  формата. Оболочка (reader_screen) не знает ни одного форматного класса;
  выбор типа разрешён только в фабрике и внутри форматных surfaces.
  Неизвестный тип = `StateError` (ошибка программирования, не продукт).
- `ReaderScrubController` — состояние scrub-жеста: ≤1 seek на кадр, 80 мс
  для тяжёлых форматов, при отпускании приземляется самый свежий палец.

Форматные различия, которые НЕ унифицировать: потоковый текст vs
непрерывный PDF vs страницы DOCX vs слайды PPTX. У PPTX нет скраббера —
это правило продукта, живёт в composition root (`supportsScrubbing`).

## 2. Стекло: правила, которые нельзя ломать

Проверено интеграционно на реальных устройствах; регрессии любых пунктов —
блокирующие (сценарии: `integration_test/all_glass_test.dart`):

1. Office монтируется через `initSurfaceAndroidView` (текстурная
   композиция). Принудительный `initExpensiveAndroidView` (Hybrid
   Composition) ломает шейдер foreground и запрещён.
2. Лупа Office рисуется во Flutter и сэмплирует текстуру документа.
   Возврат к Android window Magnifier снова ломает источник изображения.
3. В `adaptive_glass_foreground.frag` нет ручной GLES-инверсии Y; любая
   смена backend требует реального теста координат (был баг: белый глиф
   рисовался на тёмной половине наоборот).
4. Координаты масок/фона обновляются при композиции сцены (Flutter двигает
   retained layer без repaint) — не переносить обновления в paint.
5. Раскрывающийся morph имеет свой backdrop; общие blur-группы — только
   для неперекрывающихся поверхностей.
6. Нет CPU-чтения пикселей на кадр для выбора чёрного/белого — только
   per-control sample groups в шейдере.
7. Motion blur — фиксированное 5×5 ядро внутри шейдера поверх кэшированного
   альфа глифа; нативные Gaussian-проходы не возвращать.

## 3. Офлайн-движок Office: ограничения и решение

Текущий движок: OOXML → локальные HTML/JS (`android/app/src/main/assets/office/`)
→ WebView → текстурная композиция. ADR: `docs/adr/0001-office-rendering-strategy.md`
— замена не планируется, пока на текущем не проявятся реальные проблемы
(решение владельца 2026-11-02); скрининг кандидатов:
`docs/benchmarks/office-engine-comparison.md`. Ограничения вёрстки и матрица
совместимости: `docs/OFFICE_ENGINE_UPDATE.md`, `docs/OFFICE_COMPATIBILITY.md`.
Не объявлять полную поддержку OOXML; дефекты чинить по схеме
«fixture → failing test → fix → корпус».

## 4. Тесты

```bash
flutter analyze                 # ожидание: No issues found
flutter test                    # все юнит/виджет-тесты
# Office-движок (Python/Playwright, локальный Chromium):
python -m unittest discover -s tools/office_renderer_tests -p "test_*.py" -v
# Проверка шейдера (Windows: может понадобиться FOLIO_EGL_DIRECTORY):
python tools/adaptive_glass/check_shader.py
```

`check_source_integrity.py` — вспомогательный; НЕ заменяет analyzer/тесты.

## 5. Тесты на реальном телефоне

Подготовка: устройство видно (`adb devices`), отладка разрешена, **экран
горит и телефон никем не используется** (касания по экрану валят
integration-тесты — flutter_test печатает `No widgets found at <offset>`).
На время прогона: `adb shell svc power stayon true`, потом вернуть `false`.
Физический телефон обязателен: пропуски GPU-группы на хосте — норма
(`skip: !ui.ImageFilter.isShaderFilterSupported`).

### GPU-стекло на устройстве (быстрый регресс)

```bash
flutter test integration_test/all_glass_test.dart -d <device> \
  --no-uninstall --enable-impeller --dart-define=FOLIO_REQUIRE_GPU=true
```
Ожидание: все тесты зелёные; в логе `OFFICE_COMPOSITION ... hybrid=false`
(иначе сработал откат на Hybrid Composition — блокирующий регресс).

### Производительность (harness v2)

```bash
python tools/reader_benchmarks/generate_corpus.py        # детерминированный корпус
adb -s <device> push test/fixtures/reader_corpus.tar.gz-эквивалент  # см. ниже
flutter run --profile -d <device> integration_test/reader_performance_test.dart \
  --dart-define=FOLIO_PERF_CORPUS_DIR=/data/data/com.example.folio/files/folio_corpus
```

Процедура (проверено, отработано — не изобретать заново):

1. Корпус нельзя класть во внешний каталог: install стирает его, а на
   Android 17 (S25/API 37) путь вообще запрещён приложению (errno 13).
   Кладите во ВНУТРЕННИЙ каталог через run-as (сборка debuggable):
   ```bash
   adb push corpus.tar.gz /data/local/tmp/
   adb shell "run-as com.example.folio mkdir -p files/folio_corpus"
   adb shell "run-as com.example.folio cp /data/local/tmp/corpus.tar.gz files/corpus.tar.gz"
   adb shell "run-as com.example.folio tar xzf files/corpus.tar.gz -C files/folio_corpus --strip-components=1"
   ```
   Примечание: на некоторых устройствах (vivo/API 33) работает и внешний
   путь `/storage/emulated/0/Android/data/com.example.folio/files/...` —
   но внутренний работает всюду; `--strip-components=1` обязателен.
2. Harness сам ждёт корпус после запуска (`PERF_WAITING_FOR_CORPUS`, до
   3 минут): установщик стирает данные приложения, поэтому пуш идёт ПОСЛЕ
   старта.
3. Результат: `<corpusDir>/../perf_results.json` (забрать adb-ом) плюс
   `PERF_RESULT_LINE`-чанки в консоли (debugPrint не может нести одну
   длинную строку — не «чинить» обратно на один print).
4. Циклы памяти: `integration_test/reader_memory_cycles_test.dart` той же
   процедурой; PSS снимать по ВСЕМ процессам приложения (main +
   sandboxed WebView): `adb shell pidof com.example.folio ...` →
   `dumpsys meminfo <pid>` → сумма `TOTAL PSS`. Между прогонами разбег
   уровней PSS до ±12 % — это шум WebView/GPU, смотрите дрейф внутри
   прогона и парные раунды, а не одиночные числа.

### Что измерялось последний раз

`docs/benchmarks/reader-unified-results.md` (vivo Y33s и S25 Ultra,
profile; тег исходной точки `reader-baseline-20261101`). Пороги регрессии
и правила сравнения: `docs/benchmarks/protocol.md`.

## 6. Грабли (уже наступали — не повторять)

- **Git Bash на Windows конвертирует пути** вида `/data/...` в
  `C:/Program Files/Git/...`. Для adb-путей: `MSYS_NO_PATHCONV=1`.
- `flutter test --profile` **не существует**; численные прогоны — через
  `flutter run --profile` с integration-целью (или `flutter drive`,
  который переустанавливает приложение и стирает его данные).
- `grep` в этом окружении — ugrep: `\|` в BRE не работает, используйте
  `grep -E "a|b"` или python. `flutter` в скриптах — полный путь
  (`which flutter`), не полагайтесь на PATH внутри вложенных shell.
- `Directory.existsSync` на запрещённом пути Android 17 **бросает
  исключение**, а не возвращает false — оборачивайте в try/catch.
- Office-платформенный view создаётся только после `prepare` (сессии) —
  монтируйте его через `AnimatedBuilder(renderer, ...)`, как в проде;
  статичная сцена без слушателя = view никогда не создаётся.
- Детерминированные OOXML-фикстуры: пинуйте zip-времена (fixed ZipInfo)
  и `dcterms:created/modified` внутри встроенных XLSX-частей (python-pptx
  ставит wall-clock в обе стороны) — иначе SHA-256 плывут между прогонами.
- Первый gradle-сборке на новом дереве нормальны WARNING про
  `java.lang.System` restricted methods — не ошибка.
- Скипнутые GPU-тесты на хосте (`~11 skipped`) — ожидаемое поведение
  софтверного раннера, не чинить «на всякий случай».

## 7. Карта мелкой документации

| Документ | О чём |
| --- | --- |
| `docs/READER_QUALITY_STANDARD.md` | стандарт качества и приоритеты продукта (спека) |
| `docs/adr/0001-office-rendering-strategy.md` | решение по движкам Office + триггеры пересмотра |
| `docs/OFFICE_ENGINE_UPDATE.md`, `docs/OFFICE_COMPATIBILITY.md` | возможности и ограничения текущего Office-движка, матрица совместимости |
| `docs/benchmarks/protocol.md` | протокол сравнения и пороги регрессии |
| `docs/benchmarks/reader-unified-results.md` (+ JSON, PNG рядом) | фактические замены до/после, снимок реального окна |
| `docs/benchmarks/reader-baseline.md` | исходная точка (коммит, окружение, что покрыто) |
| `docs/benchmarks/office-engine-comparison.md` | скрининг кандидатов движков Office и статус сравнения |
| `tools/reader_benchmarks/README.md` | точные команды бенчмарков |
| `docs/superpowers/plans/` | исторические планы исполнения и их статус |
