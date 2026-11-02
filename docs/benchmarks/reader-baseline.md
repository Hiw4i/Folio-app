# Reader baseline — воспроизводимая исходная точка

Дата: 2026-11-01. Исполнитель: агентская сессия плана
`docs/superpowers/plans/2026-11-01-reader-quality-handoff.md` (Задача 1).
Всё, что не проверено, помечено «не оценено» — эти строки не являются
обещаниями и не могут цитироваться как результаты.

## Окружение и исходное состояние

| Параметр | Значение |
| --- | --- |
| Git HEAD | `3fdec401bf9d3616752c6466b1fd382a4fc1d8fd` (совпадает с планом) |
| Ветка | `main` |
| Flutter / Dart | 3.47.7 stable / Dart 3.13.5 (DevTools 2.60.0) |
| Приложение | `pubspec.yaml` version `0.1.0+2` |
| pubspec.lock | sha256 `47413c20a3d1fe7f…` (полный hash в git-истории этого коммита) |
| Хост-машина | Windows 10.0.26300 x64 |
| Устройство | **SM S938B (Galaxy S25 Ultra) • R5CY50XFP3Z • android-arm64 • Android 17 (API 37)** — физическое, подключено в ходе Задачи 1 |
| Эмуляторы (не использовались для выводов) | Medium_Phone_API_36.1, Pixel_10_Pro, S25_ultra (AVD) |
| Незакоммиченное при старте | только `docs/READER_QUALITY_STANDARD.md` (спека) и сам план; продуктового WIP нет |

## Команды и результаты

| Команда | Результат |
| --- | --- |
| `flutter analyze` | **No issues found!** (76 s) |
| `flutter test` | **All tests passed! — 470 passed, 11 skipped** (~42 s) |
| `flutter test integration_test/all_glass_test.dart -d R5CY50XFP3Z --enable-impeller --no-uninstall --dart-define=FOLIO_REQUIRE_GPU=true` | **All tests passed! — 14 passed** (12 Flutter-backdrop + DOCX + PPTX, ~44 s) |

### Причина 11 пропусков

Все пропуски — группа GPU-тестов `test/shared/glass/adaptive_glass_gpu_test.dart`
с условием `skip: !ui.ImageFilter.isShaderFilterSupported`. На хосте Windows
тест-раннер не поднимает Impeller-бэкенд с шейдерами, поэтому на хосте эти
тесты честно пропускаются и выполняются только на GPU-раннере (устройство,
флаг `--enable-impeller`, при необходимости `FOLIO_EGL_DIRECTORY` по
инструкции harness). Это не скрытые падения: тот же файл на устройстве
выполняется полностью в рамках `all_glass_test.dart`.

## GPU-набор на устройстве (реальный Office + Impeller)

`integration_test/all_glass_test.dart` объединяет `test/shared/glass/adaptive_glass_gpu_test.dart`
(Flutter-backdrop: цвет по фону, полный контур глифа, настоящее размытие,
независимая адаптация соседних объектов) и `integration_test/office_glass_test.dart`
(реальные DOCX и PPTX через нативный движок → Android WebView → текстурная
композиция → Flutter-стекло).

Автоматически фиксируются на устройстве:

- Текстурная композиция: `AndroidViewSurface.controller.requiresViewComposition == false`
  для обоих форматов (тихий откат на отдельные native-поверхности считается провалом).
- Backdrop содержит реальные пиксели документа; стекло реально смягчает
  полосы нативного документа (дисперсия полосы падает ≥2×).
- Независимая адаптация цвета по объектам: белый и чёрный глифы читаются в
  обеих половинах области контрола над светлой/тёмной частью документа.
- Меню morph: циклы open/close с сохранением читаемости глифа на каждом шаге.
- Реальный selection API против настоящего OOXML DOM: `selectAll` → оверлей,
  события ручек → лупа с пикселями Office; лупа исчезает при
  inactive и не возвращается до resumed; Copy кладёт текст выделения в буфер.

Результат прогона (2026-11-01, debug-сборка на устройстве): **14/14 passed**.
Журнал `OFFICE_COMPOSITION`: `docx hybrid=false texture=0`,
`pptx hybrid=false texture=1` — оба формата в текстурной композиции.

## Чего базовые автоматические проверки НЕ покрывают (честно)

- Поиск по документу, scrub, PPTX taps на устройстве — в `all_glass_test`
  не входят; это сценарии ручной проверки/будущих integration-тестов Задачи 7.
- Первая страница, память, UI/raster frame times — не измерялись в Задаче 1;
  протокол и инструмент появляются в Задачах 2 и 8.
- Второй класс устройств (слабый телефон) — недоступен, отмечено как пробел.
- Аппаратные выводы о плавности/памяти исходной версии — «не оценено» до
  Задачи 8; этот baseline не даёт права заявлять производительность.

## Исправления, зафиксированные как регрессионные требования

Из правил стекла (`docs/ARCHITECTURE.md` §2) и §2 плана — нельзя потерять при рефакторинге:

1. Office использует `initSurfaceAndroidView` и проверенную текстурную
   композицию; принудительный `initExpensiveAndroidView` запрещён.
2. Лупа Office рисуется во Flutter; возврат к Android window Magnifier
   поверх offscreen-текстуры ломает источник изображения.
3. В `adaptive_glass_foreground.frag` нет ручной GLES-инверсии Y; смена
   backend требует реального теста координат.
4. Координаты маски обновляются при композиции сцены (включая движение
   сохранённого слоя); верх/низ иконки не обрезаются.
5. Общий backdrop применяется только к совместимым неперекрывающимся
   поверхностям; раскрывающийся morph использует собственный backdrop.
6. В рабочем пути нет CPU-снимка экрана/чтения пикселей на каждом кадре
   для выбора чёрного/белого цвета.

## Инвентарь существующих проверочных средств

- `integration_test/`: `all_glass_test.dart`, `office_glass_test.dart`,
  `adaptive_glass_test.dart`, `fixtures/office_contrast.dart` (встроенные
  base64 DOCX/PPTX с контрастными зонами).
- `test/shared/glass/adaptive_glass_gpu_test.dart` — GPU-группа, запускается
  на устройстве через обёртку `adaptive_glass_test.dart`.
- `tools/office_renderer_tests/` — Python/Playwright-набор Office-движка
  (`requirements.txt`, локальный Chromium).
- `tools/adaptive_glass/` — проверка шейдера (`check_shader.py`).
- `tool/generate_pdf_fixtures.py` — генератор PDF-фикстур.
- `tools/check_source_integrity.py` — вспомогательная проверка исходников
  (не заменяет flutter test/GPU-набор).

## Ограничения, принятые до измерений

- Бесплатно и полностью офлайн; никаких серверных зависимостей чтения.
- Бюджет кадра: 16,67 мс (60 Гц) / 8,33 мс (120 Гц) для p99 устоявшихся
  UI/raster-кадров; стартовые задержки — отдельно.
- Контент, порядок чтения и обязательные операции не обмениваются на скорость.
- Пороги регрессии для рефакторинга без смены движка (предложены автором
  плана, проверяются Задачей 8): медиана первого открытия +10%, p95
  UI/raster +5%, peak PSS +10% — любое превышение требует разбора.
