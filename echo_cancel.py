"""Эхоподавление: убирает из микрофона звук собеседников, попавший туда из динамиков.

Зачем. Без наушников микрофон пишет не только владельца, но и всех остальных —
из колонок. Из-за этого чужие реплики подписываются «Я» (реальный случай: 413
чужих фраз в одной встрече), а голосовой отпечаток владельца получается грязным.

Почему это вообще возможно. Мы пишем ДВЕ дорожки раздельно: системный звук —
это в точности то, что играло в колонках, то есть готовый опорный сигнал. Микрофон
записал его же, но искажённым комнатой и с задержкой. Зная опорный сигнал, эхо
можно вычислить и вычесть.

Метод — частотный адаптивный фильтр (FDAF, overlap-save) с ограничением градиента.
Посэмповый NLMS на часовой записи считался бы часами: 16 кГц × 3600 с × сотни
отводов. FDAF делает то же через БПФ поблочно.

Замерено на реальной записи: задержка между дорожками ≈100 мс и стабильна
(дрейф ~1.5 мс за 4 минуты), поэтому одного выравнивания на запись достаточно.
"""
from __future__ import annotations

import numpy as np

SR = 16000


def estimate_delay(mic: np.ndarray, ref: np.ndarray, sr: int = SR,
                   max_lag: float = 0.5) -> tuple[int, float]:
    """Задержка эха в отсчётах и качество совпадения (0..1).

    Ищем сдвиг, на котором микрофон максимально похож на опорный сигнал.
    Низкая корреляция означает, что эха нет вовсе (человек в наушниках).
    """
    a = mic.astype(np.float64) - mic.mean()
    b = ref.astype(np.float64) - ref.mean()
    if len(a) < 1000 or b.std() < 1e-6:
        return 0, 0.0
    L = int(max_lag * sr)
    n = 1 << int(np.ceil(np.log2(len(a) + L)))
    cc = np.fft.irfft(np.fft.rfft(a, n) * np.conj(np.fft.rfft(b, n)), n)
    cc = np.concatenate([cc[-L:], cc[:L + 1]])
    k = int(np.argmax(np.abs(cc)))
    norm = np.sqrt((a ** 2).sum() * (b ** 2).sum()) + 1e-12
    return k - L, float(abs(cc[k]) / norm)


def cancel(mic: np.ndarray, ref: np.ndarray, block: int = 2048,
           mu: float = 0.5, sr: int = SR) -> tuple[np.ndarray, float]:
    """Вычитает эхо опорного сигнала из микрофона.

    Возвращает (очищенный микрофон, ERLE в дБ). ERLE — насколько подавлено эхо
    на участках, где говорил только динамик; это честная метрика качества,
    а не «на слух стало лучше».

    block=2048 при 16 кГц — фильтр длиной 128 мс, этого хватает на отражения
    обычной комнаты. Больше — точнее, но медленнее сходится.
    """
    lag, corr = estimate_delay(mic, ref, sr)
    # выравниваем опорный сигнал по найденной задержке
    if lag > 0:
        ref = np.concatenate([np.zeros(lag, dtype=ref.dtype), ref])[:len(mic)]
    elif lag < 0:
        ref = ref[-lag:]
    n = min(len(mic), len(ref))
    mic, ref = mic[:n].astype(np.float64), ref[:n].astype(np.float64)

    B, N = block, block * 2
    W = np.zeros(N // 2 + 1, dtype=complex)
    out = np.zeros(n)
    x_prev = np.zeros(B)

    # Регуляризатор привязан к реальной мощности сигнала. Если взять его
    # «на глаз» (1e-6), то на первых блоках, пока накопитель мощности почти
    # нулевой, градиент умножается на миллион и фильтр разлетается —
    # проверено: энергия выросла с -30 дБ до +68 дБ.
    scale = float((ref ** 2).mean()) * N + 1e-12
    p = np.full(N // 2 + 1, scale)
    eps = 1e-2 * scale

    for i in range(0, n - B, B):
        x = ref[i:i + B]
        X = np.fft.rfft(np.concatenate([x_prev, x]), N)
        x_prev = x
        echo = np.fft.irfft(W * X, N)[B:]          # overlap-save: валидна вторая половина
        d = mic[i:i + B]
        e = d - echo                                # остаток = голос владельца

        # Защита от расхождения: если «очистка» усилила блок, откатываем её
        # и не обновляем фильтр на этом блоке.
        if (e ** 2).mean() > 4.0 * ((d ** 2).mean() + 1e-12):
            out[i:i + B] = d
            continue
        out[i:i + B] = e

        E = np.fft.rfft(np.concatenate([np.zeros(B), e]), N)
        p = 0.9 * p + 0.1 * np.abs(X) ** 2
        grad = np.fft.irfft(np.conj(X) * E / (p + eps), N)
        grad[B:] = 0                                # ограничение градиента (иначе расходится)
        W += mu * np.fft.rfft(grad, N)

    # ERLE считаем там, где играл динамик, а владелец молчал
    ref_loud = np.abs(ref) > np.percentile(np.abs(ref), 90)
    if ref_loud.sum() > sr:
        before = (mic[ref_loud] ** 2).mean()
        after = (out[ref_loud] ** 2).mean()
        erle = 10 * np.log10(before / (after + 1e-12))
    else:
        erle = 0.0
    return out.astype(np.float32), float(erle)
