"""Кто есть кто: вероятностная привязка имён к безымянным «Собеседникам».

Голосовая библиотека узнаёт только тех, чей отпечаток уже снят. Остальные так
и остаются «Собеседник 3», хотя имя человека обычно **звучит прямо в разговоре** —
к нему обращаются по имени. Этот модуль вытаскивает разметку из текста.

Признаки (проверены на реальном дейли, 61 минута, 4 человека):

1. ОТВЕТ НА ОБРАЩЕНИЕ — главный. Прозвучало «Фёдор, ты с нами?» → отвечает
   следующий говорящий. Замер: имя «Фёдор» упомянуто 10 раз, в 5 случаях следом
   отвечал один и тот же кластер — он и оказался Фёдором.
2. СВОЁ ИМЯ ВСЛУХ НЕ НАЗЫВАЮТ — если кластер сам постоянно произносит имя,
   это довод ПРОТИВ того, что он этот человек. Признак слабый, поэтому вес
   отрицательный, но небольшой.
3. ИСКЛЮЧЕНИЕ — когда остаётся один неопознанный кластер и одно неиспользованное
   имя, связка однозначна.

Осторожность важнее охвата: если перевес одного имени над другим невелик,
привязка НЕ делается — «Собеседник 3» честнее, чем неверное имя.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

LINE = re.compile(r"^\*\*\[([^\]]+)\]\s*([^:]+):\*\*\s*(.+)", re.M)

# Насколько ответ на обращение сильнее прочих признаков.
W_ANSWER = 2.0
W_SELF_MENTION = -0.7
# Во сколько раз лучший кандидат должен опережать второго, чтобы применить имя.
MIN_RATIO = 1.6
MIN_SCORE = 2.0

ALIASES = "name_aliases.json"


def parse(path: Path) -> list[tuple[str, str]]:
    """Транскрипт → [(говорящий, текст)] по порядку."""
    return [(m.group(2).strip(), m.group(3))
            for m in LINE.finditer(path.read_text(encoding="utf-8"))]


def load_aliases(project: Path) -> dict:
    """Соответствие «имя вслух» → «имя в календаре»: Фёдор → A. Ivanov.

    Автоматически это не выводится: в приглашении двое на «A.», и различить их
    может только человек. Зато заполняется один раз и работает дальше всегда.
    """
    p = project / ALIASES
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except ValueError:
        return {}


def score(segments: list[tuple[str, str]], names: list[str],
          anonymous_prefix: str = "Собеседник") -> dict[str, dict[str, float]]:
    """Веса «этот кластер — этот человек» по обращениям в тексте."""
    scores: dict[str, dict[str, float]] = {}
    lowered = [(sp, txt.lower()) for sp, txt in segments]

    for i, (speaker, text) in enumerate(lowered):
        for name in names:
            if name.lower() not in text:
                continue
            # (1) кто ответил следом — вероятно, его и звали
            for j in range(i + 1, min(i + 3, len(lowered))):
                nxt = lowered[j][0]
                if nxt != speaker:
                    if nxt.startswith(anonymous_prefix):
                        scores.setdefault(nxt, {}).setdefault(name, 0.0)
                        scores[nxt][name] += W_ANSWER
                    break
            # (2) кто произнёс имя — скорее всего, не он сам
            if speaker.startswith(anonymous_prefix):
                scores.setdefault(speaker, {}).setdefault(name, 0.0)
                scores[speaker][name] += W_SELF_MENTION
    return scores


def decide(scores: dict[str, dict[str, float]]) -> dict[str, tuple[str, float]]:
    """Оставляет только уверенные привязки: лучший кандидат должен заметно
    опережать второго, иначе метка остаётся безымянной."""
    out: dict[str, tuple[str, float]] = {}
    used: set[str] = set()
    ranked = []
    for cluster, per_name in scores.items():
        top = sorted(per_name.items(), key=lambda kv: -kv[1])
        if not top or top[0][1] < MIN_SCORE:
            continue
        second = top[1][1] if len(top) > 1 and top[1][1] > 0 else 0.0
        ratio = top[0][1] / second if second > 0 else float("inf")
        if ratio < MIN_RATIO:
            continue
        ranked.append((top[0][1], cluster, top[0][0], ratio))
    # сначала самые уверенные — чтобы одно имя не ушло двум кластерам
    for _sc, cluster, name, ratio in sorted(ranked, reverse=True):
        if name in used:
            continue
        used.add(name)
        out[cluster] = (name, ratio)
    return out


def apply(text: str, mapping: dict[str, str]) -> tuple[str, int]:
    """Меняет метки в транскрипте. Возвращает (новый текст, сколько заменено)."""
    n = 0
    for cluster, name in mapping.items():
        pat = f"] {cluster}:**"
        n += text.count(pat)
        text = text.replace(pat, f"] {name}:**")
    return text, n


def main() -> None:
    import argparse

    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("transcript", type=Path)
    ap.add_argument("--names", nargs="*", default=None,
                    help="имена, звучащие вслух (по умолчанию — из meeting.json рядом)")
    ap.add_argument("--apply", action="store_true", help="переписать файл с именами")
    args = ap.parse_args()

    segs = parse(args.transcript)
    names = args.names
    if not names:
        meta = args.transcript.parent / "meeting.json"
        raw = json.loads(meta.read_text(encoding="utf-8")).get("attendees", []) if meta.exists() else []
        # из «A. Ivanov» имя вслух не выводится — берём алиасы, если заполнены
        al = load_aliases(Path(__file__).parent)
        names = list(al) or raw
    print(f"  ищу имена: {', '.join(names) or '(нет)'}")

    sc = score(segs, names)
    print(f"\n  {'кластер':<16}{'кандидаты (вес)'}")
    for cluster, per in sorted(sc.items()):
        top = ", ".join(f"{n} {v:+.1f}" for n, v in sorted(per.items(), key=lambda kv: -kv[1]))
        print(f"  {cluster:<16}{top}")

    decided = decide(sc)
    al = load_aliases(Path(__file__).parent)
    print("\n  уверенные привязки:")
    if not decided:
        print("   нет — перевес недостаточен, метки остаются безымянными")
    for cluster, (name, ratio) in decided.items():
        full = al.get(name, name)
        r = "∞" if ratio == float("inf") else f"{ratio:.1f}x"
        print(f"   {cluster} → {full}  (перевес {r})")

    if args.apply and decided:
        mapping = {c: al.get(n, n) for c, (n, _) in decided.items()}
        text, cnt = apply(args.transcript.read_text(encoding="utf-8"), mapping)
        args.transcript.write_text(text, encoding="utf-8")
        print(f"\n  переписано реплик: {cnt}")


if __name__ == "__main__":
    main()
