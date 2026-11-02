# Folio

Офлайн-читалка документов для Android (PDF, DOCX, PPTX, TXT, Markdown):
бесплатная, без сети, со стеклянным интерфейсом.

## Документация

**Главный документ: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)** —
структура проекта, контракты, правила стекла, запуск тестов (включая
тесты на реальном телефоне) и список известных граблей.

Мелкие документы (карта — в конце главного): стандарт качества
`docs/READER_QUALITY_STANDARD.md`, решение по движкам Office
`docs/adr/0001-office-rendering-strategy.md`, ограничения движка
`docs/OFFICE_ENGINE_UPDATE.md` / `docs/OFFICE_COMPATIBILITY.md`,
протокол и результаты замеров в `docs/benchmarks/`.

## Быстрая проверка

```bash
flutter analyze
flutter test
```

GPU-тесты на реальном телефоне и бенчмарки — см. разделы 5–6
`docs/ARCHITECTURE.md`.
