# Startzeiten

Deutsch | [English](startup-times.md) · [← Anleitung](guide.de.md)

Werte, die der Betreiber am validierten Deployment gemessen hat (B300, `--safetensors-load-strategy
prefetch`, Checkpoint bereits auf dem Network Volume). Sie stammen nicht von den Skripten dieses
Repos:

| Phase | Zeit |
|---|---|
| Modell laden ohne `prefetch` | etwa 1128 s (18:48 min) |
| Modell laden mit `prefetch` | etwa 216 s (3:36 min); der vollständige Prefetch dauerte etwa 233 s |
| FlashInfer-Autotune | etwa 3 min, nur beim ersten Lauf; das Ergebnis wird unter `/workspace/vllm-cache` zwischengespeichert |
| **Gesamt, neuer Pod auf neuer Maschine** (Pod-Start bis zur ersten 200 von `/v1/models`) | **609 s (10:09 min), ±15 s**; am 2026-09-26 gemessen, Abfrage alle 15 s ab `startedAt` des Pods (Modell und `vllm-cache` schon auf dem Volume) |
| **Gesamt, Neustart eines gestoppten Pods auf seiner alten Maschine** | **356 s (5:56 min), ±10 s**; am 2026-09-26 mit `start-when-free.sh` und `wait-for-ready.sh` ab `startedAt` aus der API gemessen |

Jede Gesamtzeit wurde **einmal** gemessen. Der neue Pod lief auf einer Maschine, auf der er zuvor
nicht lief, Image und Container-Aufbau sind also enthalten; ein Download der Gewichte steckt in
keiner der beiden Zeiten. Der Neustart eines gestoppten Pods auf seiner alten Maschine war etwa vier
Minuten schneller (plausibel, weil das Image dort schon liegt, was nicht gemessen ist). Miss es
selbst mit:

```bash
make start-when-free ARGS='1200 30' && make wait-ready
```

`start-when-free.sh` wiederholt den Start alle 30 s bis zu 1200 s (20 Minuten), solange die GPU
belegt ist, und endet nach dem ersten erfolgreichen Start; das Intervall muss mindestens 30 s
betragen, und `pod-start` rufst du nicht extra auf. Wegen des `&&` beginnt die Messung erst nach
einem erfolgreichen Start und nie, wenn der Start gescheitert ist. Für einen einzelnen Versuch ohne
Wiederholung nimm stattdessen `make pod-start && make wait-ready`. `wait-for-ready.sh` braucht
`VLLM_API_KEY` und `RUNPOD_POD_ID` (oder `GLM_URL`) in deiner `.env`; ohne den Key bricht es ab,
nachdem der Pod schon gestartet ist und abrechnet. **Ein erfolgreicher Start rechnet die GPU ab.**

`wait-for-ready.sh` fragt `/v1/models` mit deinem `VLLM_API_KEY` ab (für den einzigen aktiven
Pool-Pod, sonst `RUNPOD_POD_ID`, sonst `GLM_URL`; die Wahl wird ausgegeben), gibt die verstrichene
Zeit aus und hängt sie an `.startup-times.log` an (git-ignoriert, mit `source=startedAt` oder
`source=script`; `make wait-ready` mountet genau diese Datei read-write, damit sie den Container
überlebt, der sie geschrieben hat). Die Uhr startet bei `startedAt` des Pods aus der API (braucht
`RUNPOD_API_KEY` und die Pod-ID aus der Proxy-URL oder `RUNPOD_POD_ID`), das Ergebnis hängt also
nicht davon ab, wann du das Skript startest; die API hat `startedAt` bei einem Neustart in der
Messung vom 2026-09-26 aktualisiert, und deine lokale Uhr muss stimmen. Andernfalls sagt das Skript
das und zählt ab seinem eigenen Start. Die Auflösung ist das Abfrageintervall (standardmäßig 15 s).
Es liest nur. Jede Antwort außer 200 und 401/403 zählt als „noch nicht bereit“ (der RunPod-Proxy
antwortet 502/524, während der Container hochfährt; auch 404, 500 und Verbindungsfehler werden
wiederholt); 401/403 bricht ab, weil sich der Key nicht von selbst korrigiert. Antwortet der Pod
schon bei der ersten Abfrage, wird nichts protokolliert (er lief bereits); war er beim Start des
Skripts schon `STARTING`, ist die protokollierte Zeit nur teilweise. `GLM_URL` darf auf `/v1` enden,
das wird entfernt. `VLLM_ENGINE_READY_TIMEOUT_S=3600` ist eine großzügige Grenze, kein Messwert.
