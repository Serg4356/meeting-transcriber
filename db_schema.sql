-- Схема таблицы транскриптов для общей базы отдела (ClickHouse).
-- Имя «схема.таблица» задаётся в настройках приложения (поле «Таблица»).
-- Один ряд на встречу. В базу уходят ОЧИЩЕННАЯ версия (body) и САММАРИ (summary),
-- сырой транскрипт остаётся только на машине пользователя.
--
-- ReplacingMergeTree дедуплицирует по meeting_key; удаление (unpush) делает
-- физический ALTER TABLE ... DELETE, а не пометку — «сказал лишнее и убрал»
-- должно стирать текст на самом деле.

-- === Новая таблица ===
CREATE TABLE IF NOT EXISTS <схема>.<таблица>
(
    meeting_key   String,
    title         String,
    started_at    DateTime,
    body          String,                        -- очищенный транскрипт (не сырой)
    summary       String,                        -- саммари + action items
    attendees     Array(String),
    speakers      Array(String),
    content_hash  String,
    deleted       UInt8 DEFAULT 0,
    uploaded_by   String DEFAULT currentUser(),  -- кто залил (для «моих» встреч)
    _ver          UInt64 DEFAULT toUInt64(now())
)
ENGINE = ReplacingMergeTree(_ver)
ORDER BY meeting_key;

-- === Существующая таблица (была без summary) — добавить колонку ===
-- Порядок важен: сначала ALTER, потом приложение начнёт слать summary.
ALTER TABLE <схема>.<таблица>
    ADD COLUMN IF NOT EXISTS summary String AFTER body;
