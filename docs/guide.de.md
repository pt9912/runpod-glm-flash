# runpod-glm-flash — Anleitung

Deutsch | [English](guide.md) · [← README](../README.de.md)

Vollständige Dokumentation zu diesem Repo (Bash-Werkzeuge für das validierte
GLM-5.3-Flash-Deployment
auf einer NVIDIA B300 in RunPod Secure Cloud). Das README deckt nur den Schnellstart ab; alles
Weitere — alle `make`-Targets, Exit-Codes, Docker/Make-Interna, Scheduling, der Pool, MCP-Server,
Claude Code und vLLM-Hinweise — steht hier. Gemessene Startzeiten stehen in einer eigenen Datei:
[docs/startup-times.de.md](startup-times.de.md).

Alle Befehle unten werden aus dem Repository-Wurzelverzeichnis ausgeführt, sofern ein Block nichts
anderes sagt.

## Aktuelle Architektur

- **Pod-Anlage:** `make create` (REST v2, direkt nach dem Anlegen geprüft). Der Pool der Pods wird
  mit `make start` / `make stop` verwaltet.
- **API-Basis:** `https://api.runpod.io/v2` (von allen Skripten verwendet)
- **Pod:** Secure Cloud, 1× NVIDIA B300 SXM6 AC
- **Image:** `vllm/vllm-openai:glm53-flash`
- **Persistente Daten:** bestehendes Network Volume, eingehängt unter `/workspace`
- **Modell:** `nota-ai/GLM-5.3-Flash-Nota-NVFP4`
- **Kontext:** 1.048.576
- **KV:** FP8
- **Spec Decode:** MTP5
- **Auth:** RunPod Secret → `VLLM_API_KEY`

## Die Skripte im Überblick

| Make-Target | Was es tut | Ändert Zustand | GPU-Abrechnung |
|---|---|---|---|
| `precheck` (`pre-check.sh`) | Prüft Werkzeuge, Umgebung und `NETWORK_VOLUME_ID` (`ARGS=--online`: zusätzlich ein lesender API-Aufruf) | nein | nein |
| `smoke` (`v2-smoke.sh`) | Listet deine Pods (ID, Name, Status) | nein | nein |
| `gpu` (`gpu-availability.sh`) | Zeigt den Bestand eines GPU-Typs, insgesamt oder pro Datacenter | nein | nein |
| `wait-gpu` (`wait-for-gpu.sh`) | Fragt den Bestand ab, bis die GPU verfügbar ist; startet nie etwas | nein | nein |
| `create` (`create-pod.sh`) | Legt den Pod an (standardmäßig Trockenlauf, `ARGS=--yes` zum Anlegen) und prüft ihn | legt einen Pod an | startet |
| `verify` (`verify-pod.sh`) | Prüft, ob ein Pod der vorgesehenen Konfiguration entspricht | nein | nein |
| `check` (`check-endpoint.sh`) | Prüft die API über den Proxy: 401 ohne Key, 200 mit Key, Modell und Kontext | nein | nein |
| `wait-ready` (`wait-for-ready.sh`) | Fragt ab, bis vLLM antwortet, und misst die Startzeit (schreibt ein lokales Log) | nein | nein |
| `pod-start` (`pod-start.sh`) | Startet einen gestoppten Pod | ja | startet |
| `start-when-free` (`start-when-free.sh`) | Wiederholt `pod-start` für einen Pod, solange seine GPU belegt ist | ja | startet |
| `start` (`start-any.sh`) | Pool: bringt einen Pod zum Laufen, startet zuerst gestoppte neu und legt einen neuen an, wenn keiner startet | ja | startet |
| `pod-stop` (`pod-stop.sh`) | Stoppt einen Pod | ja | beendet |
| `stop` (`stop-any.sh`) | Stoppt jeden aktiven Pod des Pools | ja | beendet |
| `pod-terminate` (`pod-terminate.sh`) | Löscht einen Pod dauerhaft (braucht `ARGS=--yes`; das Volume bleibt) | ja | beendet |

`_api.sh` und `_pool.sh` sind Hilfsdateien, die die anderen Skripte einbinden; du führst sie nicht
aus, weder über `make` noch sonst. `docs/schedule.example.yml` ist ein deaktivierter
Beispiel-Workflow. `pod-start`, `pod-stop` und `pod-terminate` zeigen das Ziel (Name, Status,
Stundenkosten) vor der Aktion, `create` zeigt die Anfrage, und `make start ARGS=--dry-run` zeigt den
Pool und die Reihenfolge, ohne etwas zu senden. Die mit "startet" markierten Targets beginnen die
GPU-Abrechnung.

`scripts/claude-glm.sh` ist das eine Skript, das du direkt aufrufst, nie über `make` (siehe „Claude
Code“ unten): Es ersetzt sich durch die `claude`-CLI, die auf deinem Rechner laufen muss, nicht im
minimalen Container, den `make` für alles andere verwendet.

Typische Abläufe:

```bash
# beim ersten Mal
make precheck ARGS=--online
make create                    # Trockenlauf: zeigt Anfrage und Bestand
make create ARGS=--yes         # legt den Pod an und prüft ihn (rechnet die GPU ab)
make wait-ready && make check

# jeden Tag
make start ARGS=--wait         # bringt einen Pool-Pod zum Laufen und wartet, bis vLLM antwortet
make check
make stop                      # wenn fertig (beendet die GPU-Abrechnung)
```

## Secrets

Keine geheimen Werte gehören in dieses Repository.

Lokal setzen, entweder direkt:

```bash
export RUNPOD_API_KEY='...'
```

oder über eine git-ignorierte `.env`, die aus der Vorlage entsteht:

```bash
cp .env.example .env
$EDITOR .env
set -a; source .env; set +a
```

**Rechte des API-Keys:** Lesende Aufrufe (`v2-smoke.sh`, `gpu-availability.sh`, `pre-check.sh
--online`) funktionieren mit einem Read-only-Key, aber `create-pod.sh`, `pod-start.sh`,
`pod-stop.sh` und `pod-terminate.sh` brauchen Schreibzugriff auf Pods. Mit einem Read-only-Key oder
einem zu eng eingeschränkten Key scheitern sie mit `HTTP 403` („Access to the requested resource was
denied“). Das ist ein Rechteproblem, keine volle GPU. Lege in der RunPod-Console (Settings > API
Keys) einen Key mit Schreibrecht an; RunPod empfiehlt eingeschränkte Keys mit den minimal nötigen
Rechten. Beachte, dass `pre-check.sh --online` fehlendes Schreibrecht nicht erkennen kann, weil es
nur liest.

Diese beiden separat in der RunPod-Console anlegen:

- `VLLM_API_KEY`
- `HF_TOKEN` (nur für ein frisches Setup mit `create-pod.sh --online` nötig)

Secret-Namen unterscheiden Groß- und Kleinschreibung und müssen exakt zu `VLLM_SECRET_NAME` /
`HF_SECRET_NAME` passen (Standard: `VLLM_API_KEY`, `HF_TOKEN`).

Die Pod-Definition enthält nur RunPod-Secret-Referenzen (`{{ RUNPOD_SECRET_<name> }}`), nie die
Werte.

## 0. Vorab-Check

```bash
make precheck                    # Werkzeuge, Umgebung, lokale Dateien
make precheck ARGS=--online      # zusätzlich ein lesender API-Aufruf, um den Key zu prüfen
```

Prüft, ob `RUNPOD_API_KEY` exportiert ist (ein einfaches `. .env` exportiert nicht; nimm `set -a;
source .env; set +a` – oder, über `make`, reicht eine vorhandene `.env`-Datei, sie wird automatisch
gemountet und eingelesen) und ob `NETWORK_VOLUME_ID` gesetzt ist. `RUNPOD_POD_ID` und `VLLM_API_KEY`
erzeugen nur Warnungen, weil sie erst später gebraucht werden. Secret-Werte werden nie ausgegeben.
Exit-Code 1 bedeutet ein blockierendes Problem.

### Werkzeuge

Erforderlich: `docker` und `make`. `make <target>` ist die Art, wie jedes Skript in diesem Repo
ausgeführt wird (siehe „Docker / Make“ unten); `curl`/`python3` musst du dafür nicht lokal
installieren, und `scripts/*.sh` rufst du nicht direkt auf (Ausnahme: `scripts/claude-glm.sh`, siehe
„Claude Code“).

`runpodctl` wird von diesem Repo **nicht** gebraucht. Installiere es nur, wenn du es für andere
Dinge willst, nach der Anleitung unter <https://docs.runpod.io/runpodctl/overview>. Ein sinnvoller
Fall ist das Hinterlegen deines SSH-Public-Keys, den du für einen mit `--ssh` angelegten Pod
brauchst (`ssh-keygen -t ed25519`, dann entweder `~/.ssh/id_ed25519.pub` in das Feld SSH Public Keys
deiner RunPod-Kontoeinstellungen einfügen oder `runpodctl ssh add-key --key-file
~/.ssh/id_ed25519.pub` ausführen).

### Docker / Make

`make <target>` führt das jeweilige Skript in einem Container aus dem `Dockerfile` aus (nur
`bash`+`curl`+`python3`; kein Modell, kein Build-Artefakt, vLLM/GLM läuft nie in diesem Image). Das
ist **die** dokumentierte Art, dieses Repo zu benutzen, keine Abkürzung neben dem direkten Aufruf
von `scripts/*.sh`:

```bash
make smoke              # scripts/v2-smoke.sh
make start               # scripts/start-any.sh  (ARGS='...' für zusätzliche Argumente, z.B. --dry-run)
make gpu ARGS='B300 EU-NL-1'
make stop
```

Zwei Wege, wie Secrets in den Container kommen, und wie sie sich unterscheiden:

| | `.env`-Datei vorhanden | Keine `.env`-Datei (z.B. CI) |
|---|---|---|
| Mechanismus | read-only gemountet, von `docker-entrypoint.sh` eingelesen (genau wie lokal `set -a; source .env; set +a`) | bereits exportierte Variablen (`RUNPOD_API_KEY`, `NETWORK_VOLUME_ID`, …) mit `-e VARNAME` durchgereicht |
| Landet im Image? | nie | nie |
| Sichtbar in `docker inspect`? | nein | **ja** – die Werte (nicht nur die Namen) stehen in `Config.Env`, für jeden mit Zugriff auf den Docker-Socket dieses Hosts, solange der kurzlebige Container läuft |
| Vorrang | eine bereits exportierte Variable gewinnt trotzdem über denselben Namen in `.env` (eine versehentlich vorhandene `.env` im CI-Arbeitsverzeichnis kann so kein vom Job gesetztes Secret still überschreiben) | – |

Jedes Target baut das Image zuerst neu (lokal mit Cache günstig; ein gehosteter GitHub-Runner ist
bei jedem Lauf eine frische VM und baut jedes Mal neu) und braucht im Normalfall kein Argument; die
vollständige Liste der Targets steht im `Makefile`.

`create`, `start`, `pod-start` und `start-when-free` können einen Pod starten oder anlegen
(GPU-Abrechnung). Die eigene Pool-Sperre eines Containers (`_pool.sh`) kann zwei solche Läufe nicht
verhindern, weil jeder `docker run` mit einem frischen, leeren Dateisystem beginnt – die Sperre
würde einen zweiten Lauf nie sehen. Das Makefile serialisiert diese vier Targets deshalb selbst mit
einer Sperre **auf dem Host** (`flock`, außerhalb des Containers), bevor überhaupt einer startet;
ein zweiter gibt eine Meldung aus und bricht ab, statt zu laufen. Jedes der vier bekommt einen
festen Container-Namen (`runpod-glm-<target>`), damit sich ein hängender finden und stoppen lässt:
`make abort` (oder von Hand `docker ps --filter 'name=^/runpod-glm-<target>$'` / `docker kill
<name>`). Das ist dem Töten des `make`-Prozesses vorzuziehen – Make reicht Signale nicht an die
Kindprozesse eines Rezepts weiter, sodass der Container (und die Sperre) sonst weiterlaufen kann –
und lösche nie von Hand die Lock-Datei, um eine hängende Sperre zu „reparieren“: Die Sperre gehört
zur offenen Datei, nicht zum Pfad, eine frische Datei am selben Pfad lässt also ein zweites
Anlegen/Starten sofort neben einem noch laufenden ersten zu – genau die doppelte Abrechnung, die
diese Sperre verhindern soll. Die Lock-Datei selbst liegt unter `$XDG_RUNTIME_DIR` (wie die eigene
Sperre von `_pool.sh` weiter unten), nicht unter `$TMPDIR`: Anders als `XDG_RUNTIME_DIR` ist
`TMPDIR` nicht garantiert auf jedem Betriebssystem für denselben Nutzer über zwei Shells hinweg
gleich, was die Serialisierung still aushebeln würde.

GNU Make selbst endet immer mit `0` oder `2`, unabhängig vom tatsächlichen Exit-Code des
aufgerufenen Skripts; die feingranularen Codes, die diese Anleitung durchgängig dokumentiert (5, 6,
8, 9, …), sind in `$?` nach einem `make <target>`-Aufruf also nicht sichtbar. Jedes Target schreibt
seinen echten Code zusätzlich in eine **pro Target eigene** Datei, `.make-exit-code.<target>`
(git-ignoriert), für alles, was um `make` herum skriptet: `make check; rc=$(cat
.make-exit-code.check)`. Pro Target, nicht eine gemeinsame Datei, damit ein `make check` neben einem
laufenden `make start` (etwa eine Überwachungsschleife, die pollt, während ein Start läuft) nicht
versehentlich den Code des anderen Targets liest.

Das Dockerfile ist per Digest gepinnt (`python:3.13-alpine@sha256:...`) und per exakter
`apk`-Paketversion (`bash`, `curl`), nicht nur per Tag, damit ein Rebuild Wochen später nicht still
eine andere Alpine-/Python-Nebenversion zieht.

`scripts/claude-glm.sh` ist bewusst **kein** solches Target: Es ersetzt sich durch die `claude`-CLI,
die auf deinem Rechner laufen muss, nicht in einem minimalen Container, der sie gar nicht hat.

## 1. Schreibgeschützter REST-v2-Check

```bash
make smoke
```

Das führt ein GET gegen `/v2/pods` aus und legt keine GPU an. Es gibt pro Pod nur ID, Name und
Status aus, weil die Rohantwort die `env` jedes Pods enthält.

## 2. Konfigurieren

Trage die ID deines bestehenden Network Volumes in die `.env` ein (Vorlage: `.env.example`):

```bash
echo 'NETWORK_VOLUME_ID=<your Network Volume ID>' >> .env
```

Ein Network Volume ist an ein Datacenter gebunden, deshalb muss eine B300 **in diesem Datacenter**
frei sein; eine freie B300 anderswo hilft nicht. `create-pod.sh` legt den Pod automatisch im
Datacenter des Volumes an. Prüfe den Bestand vorher mit `make gpu ARGS='B300 <DATACENTER>'` (ohne
Datacenter nimmt es das Datacenter des Pods `RUNPOD_POD_ID`, falls gesetzt, sonst den Gesamtbestand;
mit `any` erzwingst du den Gesamtbestand). `B300` trifft den exakten GPU-Namen; die volle GPU-ID
lautet `NVIDIA B300 SXM6 AC`, die du ebenfalls übergeben kannst. Trifft keine ID und kein Name
exakt, listet es alle GPUs auf, die den Text enthalten, und sagt das.

| Exit-Code | Bedeutung |
|---|---|
| 0 | Bestand vorhanden |
| 2 | kein Bestand |
| 4 | unbekannter GPU-Typ oder unbekanntes Datacenter (Tippfehler) |
| 1 | API-Fehler |

Standardmäßig läuft der Pod im Offline-Modus: Der Checkpoint wird auf dem Volume erwartet,
`HF_HUB_OFFLINE=1` wird gesetzt und kein `HF_TOKEN` gesendet. Für ein frisches Setup oder einen
erneuten Download `make create ARGS=--online` verwenden; dann sind Downloads erlaubt und das Secret
`HF_TOKEN` wird eingespielt.

## 3. Trockenlauf

```bash
make create
```

Der Standard ist ein **Trockenlauf**: Es liest das Datacenter des Volumes, bricht ab, wenn schon ein
Pod mit demselben Namen existiert, zeigt die vollständige Anfrage (nur RunPod-Secret-Referenzen,
keine geheimen Werte) samt aktuellem Bestand und legt nichts an. Optionen (`ARGS='...'`): `--online`
(Downloads erlaubt), `--ssh` (zusätzlich `22/tcp` und `startSsh`; standardmäßig aus). Überschreibbar
über die Umgebung: `POD_NAME`, `GPU_ID`, `DATACENTER`, `CONTAINER_DISK_GB`, `VLLM_SECRET_NAME`,
`HF_SECRET_NAME`.

Prüfe die Anfrage: 1× B300, `mounts.network` mit deinem Volume auf `/workspace`, Port 8000, das
Image, die vLLM-Argumente (1M-Kontext, MTP, `--max-num-seqs 6`) und dass `VLLM_API_KEY` eine `{{
RUNPOD_SECRET_... }}`-Referenz ist.

## 4. Den Pod anlegen

```bash
make create ARGS=--yes
```

Das ist der Schritt, der abrechnungspflichtige B300-Rechenzeit startet (etwa 7,89 $/h). Das Skript
wiederholt nie eine Anfrage, die womöglich gesendet wurde. Danach führt es `verify-pod.sh` aus (nur
lesend): 1× B300, das Volume auf `/workspace`, Port 8000, `VLLM_API_KEY` als Secret-Referenz (nie
leer, nie ein Klartextwert), die Caches auf `/workspace` und die wichtigen vLLM-Argumente; es gibt
nur Namen von Env-Variablen aus, nie Werte. Bei Erfolg trägst du die ausgegebene Pod-ID als
`RUNPOD_POD_ID` in die `.env` ein. Die Prüfung liest den Pod bis zu dreimal, ein einzelner
Netzwerkfehler gilt also nicht als „der Pod ist falsch“. Schlägt die Prüfung **fehl**, ist der Pod
falsch und rechnet ab, deshalb räumt `create-pod.sh` auf, jeden Schritt mit Wiederholungen: Es
**stoppt** ihn (die Abrechnung endet), **benennt** ihn in `failed-<name>-<id>` um (er verlässt den
Pool und wird nie versehentlich neu gestartet, bleibt aber zum Untersuchen erhalten) und **beendet**
ihn als Rückfall, wenn Stoppen oder Umbenennen doch nicht geklappt hat. Mit
`ARGS=--terminate-on-fail` wird er sofort gelöscht. Die Abschlussmeldung sagt genau, was geklappt
hat und, falls etwas nicht geklappt hat, den Befehl zum Beenden:

```bash
RUNPOD_POD_ID=<the new ID> make pod-terminate ARGS=--yes
```

Konnte die Prüfung **gar nicht laufen** (der Pod war nicht lesbar, Exit 6), bleibt der Pod
unangetastet laufen, und die Meldung sagt, dass du `verify-pod.sh <POD_ID>` ausführen sollst; das
ist kein Hinweis darauf, dass er falsch ist.

`pod-terminate` löscht einen Pod dauerhaft (ohne `ARGS=--yes` zeigt es nur das Ziel); das Network
Volume ist eine eigene Ressource und bleibt, Modell und Caches überleben also. `create-pod.sh` legt
keinen zweiten Pod an, solange ein anderer Pod des Pools aktiv ist (`ARGS=--force` hebt das auf und
nimmt, falls der Standardname vergeben ist, den nächsten freien Namen wie `glm-5.3-flash-b300-2`)
und nimmt eine Sperre, damit zwei Läufe auf demselben Rechner nicht gleichzeitig anlegen. Jeden Pod
kannst du später mit `make verify ARGS=[POD_ID]` prüfen.

Exit-Codes von `create-pod.sh`:

| Exit-Code | Bedeutung |
|---|---|
| 0 | fertig |
| 1 | Fehler oder gescheiterte Prüfung |
| 2 | falsche Argumente (auch ein `POD_NAME`, das ohne `--force` nicht mit `POOL_PREFIX` beginnt: kein Pool-Guard würde diesen Pod je sehen) |
| 3 | ein Pod mit diesem Namen existiert oder ein Pool-Pod ist aktiv |
| 4 | ein anderer Start/Anlegen läuft |
| 5 | keine Kapazität (nichts angelegt; nur die Antwort „no instances available“ zählt als Kapazität, jedes andere HTTP 400 ist eine abgelehnte Anfrage) |
| 6 | angelegt, aber die Prüfung konnte nicht laufen (auch bei einer API-Antwort in unerwarteter Form) |

## 5. Den Endpunkt prüfen

```bash
make check
```

Sobald der Pod antwortet (`wait-for-ready.sh`), geht diese lesende Prüfung über den
RunPod-HTTPS-Proxy und braucht kein SSH. Sie gibt nur Status, Modell-ID und Kontextlänge aus, nie
einen Key. Sie prüft, dass:

- **ohne Key** die API `401` antwortet (ein `200` heißt, der Server ist für alle offen: Pod stoppen
  und das Secret `VLLM_API_KEY` prüfen),
- **mit deinem `VLLM_API_KEY`** sie `200` antwortet (ein `401` heißt, der Server läuft mit einem
  anderen Key, etwa einem unaufgelösten Secret-Platzhalter nach einem falsch geschriebenen
  Secret-Namen),
- das bediente Modell `glm-5.3-flash` mit `max_model_len` 1048576 ist (ein anderer Modell-Root warnt
  nur).

Welcher Pod: die übergebene ID (`make check ARGS=<POD_ID>`), sonst der einzige **aktive Pool-Pod**,
sonst `RUNPOD_POD_ID`, sonst `GLM_URL`; der gewählte Pod und der Grund werden ausgegeben, eine
veraltete ID in der `.env` kann die Prüfung also nicht zu einem gestoppten Pod schicken. Sind
mehrere Pool-Pods aktiv, gib die ID an (nur Kleinbuchstaben und Ziffern). Nur die `/v1`-API ist bei
vLLM geschützt; `/health` und `/metrics` sind absichtlich offen.

| Exit-Code | Bedeutung |
|---|---|
| 0 | alle Prüfungen bestanden |
| 1 | eine Prüfung ist fehlgeschlagen (auch eine unerwartete Antwort im Test ohne Key) |
| 2 | falsche Argumente oder fehlender `VLLM_API_KEY` |
| 3 | der Endpunkt antwortet nicht (fährt hoch, gestoppt oder 5xx/429/404) |

**SSH ist standardmäßig aus:** Ein neuer Pod öffnet nur `8000/http`. `make create ARGS=--ssh` (oder
`CREATE_POD_SSH=1` für `make start`) öffnet zusätzlich `22/tcp` und startet ssh. Das braucht in
deinem RunPod-Konto hinterlegte SSH-Public-Keys und einen sshd im Container, was für dieses Image
nicht verifiziert ist, und es erlaubt Root-Login: nur mit Schlüsseln nutzen.

## 14/5-Zeitplan

Der vorgesehene Zeitplan ist **05:00 bis 19:00 Ortszeit, Montag bis Freitag** (14 Stunden, 5 Tage).
Der frühe Start ist Absicht: Nach Erfahrung des Betreibers ist eine freie B300 früh am Morgen
leichter zu finden (hier nicht verifiziert; der Bestand ändert sich innerhalb von Minuten, prüfe mit
`make gpu` oder `make wait-gpu`).

| | Start 05:00 | Stopp 19:00 |
|---|---|---|
| Sommerzeit (CEST, UTC+2) | 03:00 UTC | 17:00 UTC |
| Winterzeit (CET, UTC+1) | 04:00 UTC | 18:00 UTC |

GitHub-Actions-Cron läuft nur in UTC, deshalb müssen die Cron-Zeilen zweimal im Jahr geändert werden
(letzter Sonntag im März und im Oktober), oder du nutzt einen zeitzonenfähigen externen Scheduler.

`docs/schedule.example.yml` ist bewusst **deaktiviert** und liegt außerhalb von
`.github/workflows/`, damit GitHub es nie ausführt. Es zeigt die vorgesehene GitHub-Actions-Form,
ohne versehentliche GPU-Kosten zu riskieren: Der Start-Job ruft `make start` auf (`start-any.sh`
über das Docker-Image), das die Pool-Pods nacheinander neu startet und einen neuen anlegt, wenn
keiner startet, und das alle 60 s wiederholt, höchstens `MAX_WAIT_SECONDS` lang (7200 = 2 h), und
dann aufgibt und den Job fehlschlagen lässt (der Pod bleibt an diesem Tag gestoppt; GitHub
benachrichtigt dich in der Regel, aber nicht zuverlässig); der Job hat eine harte
`timeout-minutes`-Grenze; der Stopp-Job ruft `make stop` auf; bei geplanten Läufen werden Start und
Stopp aus dem Cron-Eintrag abgeleitet. `make` baut das Image selbst, ein eigener Build-Schritt
entfällt also (lokal mit Cache günstig; ein gehosteter GitHub-Runner ist bei jedem Lauf eine frische
VM und baut jedes Mal neu). Die Secrets sind `RUNPOD_API_KEY` (Schreibzugriff auf Pods) und
`NETWORK_VOLUME_ID` (zum Anlegen neuer Pods nötig); auf dem Runner gibt es keine `.env`-Datei, das
Makefile reicht diese bereits exportierten Secrets stattdessen in den Container durch. **Jeder
erfolgreiche Start rechnet die GPU ab**, prüfe die Datei also sorgfältig, bevor du sie aktivierst.
GitHub hält pro Concurrency-Gruppe nur einen wartenden Lauf: Löse keine manuellen Läufe aus, solange
ein Start noch wiederholt, sonst kann ein eingereihter Stopp verworfen werden. Cron-Läufe können
sich verspäten oder ausfallen, und geplante Workflows inaktiver öffentlicher Repos werden nach 60
Tagen deaktiviert; beides ist für den Stopp-Job relevant. Verschiebe die Datei erst nach
`.github/workflows/` und aktiviere sie, wenn du Actions per SHA festgelegt und den Umgang mit der
europäischen Sommerzeit entschieden hast.

Alle API-Aufrufe haben Zeitlimits (10 s Verbindungsaufbau, 60 s gesamt; überschreibbar mit
`API_CONNECT_TIMEOUT` / `API_MAX_TIME`), damit eine hängende Verbindung einen geplanten Job nicht
blockieren kann. Bricht die Verbindung ab, nachdem eine Start- oder Stopp-Anfrage gesendet wurde,
sagen die Skripte, dass das Ergebnis unbekannt ist; prüfe vor einem neuen Versuch mit `make smoke`.

`pod-start.sh` und `pod-stop.sh` (`make pod-start` / `make pod-stop`) rufen den REST-v2-Endpunkt
`POST /v2/pods/{id}/action` auf (`start`/`stop`). Beide zeigen zuerst das Ziel an (Name, Status,
Stundenkosten, Datacenter), damit eine veraltete `RUNPOD_POD_ID` auffällt, und tun nichts, wenn der
Pod schon im gewünschten Zustand ist. Ein Start rechnet die GPU sofort ab. Das Stoppen ist für einen
geplanten Betrieb riskant: siehe „Wenn die GPU belegt ist“. Automatisiere keinen zerstörerischen
Redeploy, bevor das genaue Migrations-/Redeploy-Verhalten im Konto getestet ist.

## Wenn die GPU belegt ist

Ein gestoppter Pod behält seine Maschinenzuordnung und läuft auf demselben Host wieder an. Mietet in
der Zwischenzeit jemand anderes die GPU, kann `pod start` nicht gelingen:
`HTTP 400 {"detail":"There are not enough free GPUs on the host machine to start this pod."}`; in
diesem Fall wird nichts gestartet oder abgerechnet. Die RunPod-Doku beschreibt drei Wege:

1. **Warten.** Die GPU wird frei, sobald der andere Nutzer seinen Pod stoppt. `make start-when-free
   ARGS='[MAX_WAIT_SECONDS] [INTERVAL_SECONDS]'` (Standard 7200 s, 60 s) wiederholt den eigentlichen
   Start, solange die GPU belegt ist, und endet nach einem Erfolg oder an der Grenze. Das ist das
   richtige Werkzeug für einen gestoppten Pod: Er läuft auf seiner eigenen Maschine wieder an, über
   die der Katalogbestand nichts aussagt, und ein fehlgeschlagener Versuch kostet nichts. Ein
   Abbruch des Laufs stoppt den laufenden Versuch, aber eine bereits gesendete Start-Anfrage lässt
   sich nicht zurücknehmen (das Skript sagt dann, dass du `make smoke` prüfen sollst). **Ein
   erfolgreicher Start rechnet die GPU ab.**

   Die Exit-Codes von `pod-start.sh`, und was `start-when-free`/`start` damit machen:

   | Exit-Code | Bedeutung | Was passiert |
   |---|---|---|
   | 9 | ein anderer Pool-Pod ist schon aktiv | verweigert, außer mit `ARGS=--force`, damit eine veraltete `RUNPOD_POD_ID` keinen zweiten abrechnenden Pod starten kann |
   | 4 | `start-any.sh`/`create-pod.sh` hält bereits die Host-Sperre | verweigert, nichts gesendet |
   | 5 | GPU belegt | wiederholt |
   | 6 | Pod nicht lesbar, nichts gesendet | wiederholt (`start-when-free` bis zu 10-mal hintereinander; `start` überspringt den Pod nur in dieser Runde) |
   | 8 | endgültig abgelehnt (unbekannter Pod, falscher Status, oder ein abgelehntes 4xx außer „belegt“) | nichts wurde gesendet oder geändert; `start` überspringt ihn und versucht den nächsten Pod |
   | jeder andere | – | bricht sofort ab, damit ein womöglich gestarteter Pod nie doppelt gestartet wird |

   Willst du nur benachrichtigt werden und nicht starten, fragt `make wait-gpu ARGS=B300` (nimmt das
   Datacenter deines Pods aus `RUNPOD_POD_ID`; ein anderes nennst du ausdrücklich, mit `any` gilt
   der Gesamtbestand) den Bestand schreibgeschützt alle 60 s ab und läutet die Terminal-Glocke,
   sobald die GPU verfügbar ist; es startet nie etwas (ein Tippfehler bei GPU oder Datacenter bricht
   mit Exit 4 ab, statt ewig zu warten). Der Bestand ändert sich innerhalb von Minuten, handle also
   sofort und rechne damit, dass ein Start trotzdem scheitern kann.
2. **Redeploy (empfohlen mit einem Network Volume).** Einen neuen Pod anlegen, der dasselbe Volume
   anhängt; `/workspace` (Modell, HF- und vLLM-Caches) bleibt unberührt, und laut RunPod-Doku kann
   ein Network Volume an mehrere Pods angehängt werden, der gestoppte Pod muss also nicht zuerst
   beendet werden. RunPod wählt eine Maschine mit freier B300 im Datacenter des Volumes:

   ```bash
   make create              # Trockenlauf
   make create ARGS=--yes   # legt an und prüft (rechnet die GPU ab)
   ```

   Nutze vorher `make gpu`; ein Anlegen kann trotzdem wegen fehlender Kapazität scheitern (Exit-Code 5, nichts angelegt).
3. **Console-Migration (Beta).** Die RunPod-Console bietet an, einen gestoppten Pod auf eine
   Maschine mit freier GPU zu migrieren. Ihre Doku beschreibt kein Gegenstück für API oder CLI.

Redeploy und Migration erzeugen beide eine **neue Pod-ID, IP und Proxy-URL**. Aktualisiere danach
`RUNPOD_POD_ID` (lokale `.env`) und `GLM_URL` (Claude Code) und führe `make check` erneut aus.

Für den 14/5-Zeitplan heißt das: Stopp/Start ist billig, kann aber über Nacht scheitern;
Beenden/Neuanlegen ist robust gegen die Maschinenbindung, kann aber an der B300-Kapazität scheitern
und ändert die Pod-ID täglich. Entscheide das bewusst. Ist die GPU um 05:00 belegt, wird der Start
wiederholt (siehe „Warten“ oben), höchstens zwei Stunden lang; bleibt sie belegt, entfällt der Tag
(nach der Grenze beginnt kein Versuch mehr; ein bereits laufender kann etwa 2 Minuten später enden).

## Pod-Pool: mehrere Pods auf verschiedenen Maschinen

Ein gestoppter Pod läuft nur auf seiner eigenen Maschine wieder an (siehe oben). Mehrere Pods auf
verschiedenen Maschinen erhöhen die Chance, dass einer davon startet, und ein Neustart ist schneller
als ein neuer Pod (5:56 min gegenüber 10:09 min, gemessen). Ein gestoppter Pod kostet pro Stunde
nichts, und das Network Volume wird geteilt und nur einmal abgerechnet; ob RunPod die Zahl der Pods
pro Konto begrenzt, wurde nicht geprüft.

**Der Pool wird nirgends gespeichert.** Er besteht aus allen Pods deines Kontos, deren Name mit
`glm-5.3-flash-b300` **beginnt** (`POOL_PREFIX`), bei jedem Aufruf live gelesen und ohne beendete
Pods. Es werden keine Pod-IDs ins Repository oder in die `.env` geschrieben, und Pods mit anderen
Namen werden nie angefasst.

```bash
make start ARGS=--dry-run    # zeigt Pool, Reihenfolge und nächsten Namen; sendet nichts
make start ARGS=--wait       # bringt einen Pod zum Laufen und misst dann die Zeit bis zur Bereitschaft
make stop                    # stoppt den laufenden Pool-Pod (beendet die GPU-Abrechnung)
```

`start-any.sh [--no-create] [--dry-run] [--wait] [MAX_WAIT_SECONDS] [INTERVAL_SECONDS]` (`make start
ARGS='...'`; Standard 1200 s und 30 s, Intervall mindestens 30 s) arbeitet in Runden:

1. Ist schon ein Pool-Pod aktiv (jeder Status außer `EXITED`, `ERROR` und `TERMINATED`, ein
   unerwarteter Status zählt also auch als aktiv), tut es nichts: **nie zwei Pool-Pods
   gleichzeitig** (sie teilen `/workspace/vllm-cache` und würden doppelt abrechnen). Eine
   Kernel-Dateisperre (`POOL_LOCKFILE`, standardmäßig in `$XDG_RUNTIME_DIR` oder `/tmp`) verhindert
   außerdem, dass zwei Läufe auf demselben Rechner gleichzeitig starten oder anlegen (der zweite
   endet mit Code 4); die Sperre wird auch frei, wenn ein Lauf abgebrochen wird. (Über `make` ist
   das die eigene Sperre des Containers, gültig für einen `docker run`; das Makefile ergänzt eine
   eigene Sperre auf dem Host, damit auch zwei `make start`/`make create`-Aufrufe serialisiert
   werden, siehe „Docker / Make“.)
2. Es versucht, die gestoppten Pool-Pods nacheinander zu starten, den zuletzt benutzten zuerst. Ein
   Versuch auf einer belegten Maschine kostet nichts.
3. Startet keiner und hat der Pool weniger als `POOL_MAX` Pods (Standard 6), legt es wie `make
   create ARGS=--yes` einen neuen Pod an, benannt `glm-5.3-flash-b300`, `glm-5.3-flash-b300-2` usw.
   (`--no-create` schaltet das ab), und prüft ihn mit `verify-pod.sh`.
4. Sonst wartet es und wiederholt. Nach `MAX_WAIT_SECONDS` beginnt kein Versuch mehr (Exit-Code 3);
   ein bereits laufender wird nicht abgebrochen, und bei vielen Pool-Pods kann eine Runde Minuten
   dauern (jeder versuchte Pod kostet bis zu drei API-Aufrufe zu je bis zu 60 s; eine Runde macht
   etwa 5 + 3N Aufrufe bei N gestoppten Pods).

Wiederholt oder übersprungen wird nur:

| Exit-Code (von) | Bedeutung |
|---|---|
| 5 (`pod-start`) | Maschine belegt |
| 5 (`create`) | keine Kapazität |
| 6 | ein vorübergehend nicht lesbarer Pod |
| 8 | ein endgültig abgelehnter Pod (unbekannter Pod, falscher Status, oder ein abgelehntes 4xx außer „belegt“; nichts wurde gesendet oder geändert) |

Jeder andere Fehler bricht sofort ab, damit ein womöglich gestarteter oder angelegter Pod nie
wiederholt wird. Besteht ein angelegter Pod die Prüfung nicht, stoppt und benennt `create-pod.sh`
ihn um (siehe Schritt 4), und `start-any.sh` bricht ab, ohne etwas anderes zu versuchen. Ein Abbruch
stoppt den laufenden Versuch, aber eine bereits gesendete Anfrage lässt sich nicht zurücknehmen.
**Ein Erfolg rechnet die GPU ab (etwa 7,89 $/h).**

Das Skript gibt ID und URL des laufenden Pods aus (`RUNPOD_POD_ID`, `GLM_URL`). Mit einem Pool muss
die ID in der `.env` nicht mehr den laufenden Pod nennen; `--wait` misst genau diesen Pod (eine alte
`GLM_URL` aus der `.env` wird dafür ignoriert; `READY_TIMEOUT` setzt die Wartezeit in Sekunden,
Standard 3600). Später nehmen `verify`, `wait-ready` und `check` von selbst den einzigen aktiven
Pool-Pod und geben aus, welchen und warum; `pod-start`, `pod-stop` und `pod-terminate` benutzen
weiter `RUNPOD_POD_ID`. Läuft der Pod, aber `wait-for-ready.sh` kann die Bereitschaft nicht
bestätigen, ist der Exit-Code 7, und die Meldung sagt, dass der Pod läuft und abrechnet. Nicht mehr
gebrauchte Pods entfernst du mit `make pod-terminate ARGS=--yes` (das Volume bleibt); bei vollem
Pool wird kein neuer Pod angelegt.

Exit-Codes von `start-any.sh`:

| Exit-Code | Bedeutung |
|---|---|
| 0 | ein Pool-Pod läuft |
| 1 | anderer Fehler |
| 2 | falsche Argumente |
| 3 | aufgegeben (nichts läuft) |
| 4 | ein anderer Start/Anlegen läuft |
| 7 | läuft, aber Bereitschaft nicht bestätigt (`--wait`) |
| 130 | abgebrochen |

## Kosten stoppen

- `make pod-stop` (ein Pod) und `make stop` (jeder aktive Pool-Pod; es versucht das Lesen der
  Pod-Liste bis zu fünfmal, `STOP_LIST_TRIES` und `STOP_RETRY_DELAY`, bevor es aufgibt) beenden die
  GPU-Abrechnung. Laut RunPod-Preisdoku wird ein gestoppter Pod nicht für seine Container-Disk
  berechnet (nur für eine Pod-lokale Volume-Disk, zu einem höheren Satz); das Network Volume wird
  getrennt abgerechnet (etwa 0,07 $/GB/Monat), egal ob ein Pod läuft.
- `make pod-terminate ARGS=--yes` löscht einen Pod dauerhaft. Es löscht das Network Volume
  **nicht**, Modell und Caches bleiben also erhalten.

## Optional: Runpod-MCP-Server

Dieses Repo braucht kein MCP. Runpod bietet zwei
[MCP-Server](https://docs.runpod.io/get-started/mcp-servers), mit denen ein KI-Coding-Agent wie
Claude Code direkt mit Runpod arbeiten kann. Die Befehle unten stammen aus der Runpod-Dokumentation
und wurden mit diesem Repo nicht getestet; die Skripte hier funktionieren auch ohne sie.

**Docs-Server** (nur lesende Dokumentationssuche, ohne Anmeldung):

```bash
claude mcp add runpod-docs --scope user --transport http https://docs.runpod.io/mcp
```

**API-Server** (verwaltet Pods, Endpoints, Templates, Network Volumes und Registries über die
REST-API, standardmäßig v2). Er hat **Schreibzugriff auf dein Konto und kann abrechnungspflichtige
Pods starten**, behandle ihn also wie den API-Key selbst. Empfohlen ist der gehostete Server mit
„Sign in with Runpod“ (OAuth): Beim ersten Gebrauch öffnet sich ein Browser, und es wird kein Key
auf der Platte gespeichert.

```bash
claude mcp add --transport http runpod -s user https://mcp.getrunpod.io/
```

Alternativen:

- Geführter Installer, erkennt deine Clients (Claude Code, Claude Desktop, Cursor, Windsurf, VS
  Code): `npx @runpod/mcp-server@latest add`; rückgängig mit `npx @runpod/mcp-server@latest remove`.
- Gehosteter Server mit API-Key statt OAuth: `--header "Authorization: Bearer $RUNPOD_API_KEY"` an
  den obigen Befehl anhängen.
- Lokaler Server: `claude mcp add runpod --scope user -e RUNPOD_API_KEY=... -- npx -y
  @runpod/mcp-server@latest`. Der Key liegt dann in deiner Claude-Code-Konfiguration, deshalb ist
  die OAuth-Variante vorzuziehen.

Faustregeln:

- `-s user` / `--scope user` verwenden. Eine projektbezogene Konfiguration wird in eine `.mcp.json`
  im Repository geschrieben und könnte in einem Commit landen; lege dort nie einen Key ab.
- Einen API-Key mit nur den nötigen Rechten verwenden (siehe „Rechte des API-Keys“) und ihn
  deaktivieren oder löschen, wenn du ihn nicht mehr brauchst.
- Die Verbindung mit `/mcp` in Claude Code prüfen; einen Server mit `claude mcp remove runpod`
  entfernen.
- Pods über einen Agenten zu starten oder anzulegen rechnet die GPU genauso ab wie die Skripte.
  Prüfe weiter, was der Agent gleich tun will.

## Claude Code

```bash
./scripts/claude-glm.sh
```

Es löst den Pod auf (der einzige aktive Pool-Pod, sonst `RUNPOD_POD_ID`, sonst `GLM_URL`; die Wahl
und der Grund werden ausgegeben), wartet, bis `/v1/models` mit deinem Key tatsächlich `200`
antwortet (`READY_RETRIES` / `READY_DELAY`, Standard 5 / 5 s, damit ein nach einem Start noch
warmlaufender RunPod-Proxy die Sitzung nicht gleich scheitern lässt), setzt dann die Umgebung unten
und ersetzt sich durch `claude --model glm-5.3-flash`, alle Argumente werden durchgereicht. Es
startet oder legt nie einen Pod an; läuft keiner, sagt es das und verweist auf `make start`.

```bash
./scripts/claude-glm.sh --resume
./scripts/claude-glm.sh -p "Fix the failing test"
```

| Exit-Code | Bedeutung |
|---|---|
| 1 | kein Pool-Pod läuft (oder der Endpunkt wurde nie bereit, oder mehrere Pool-Pods sind aktiv) |
| 2 | `VLLM_API_KEY` nicht gesetzt |
| 127 | `claude` nicht gefunden |
| (sonst) | der Exit-Code von `claude` selbst |

Das Skript wechselt nirgendwohin das Verzeichnis und lädt selbst keine `.env`-Datei, lässt sich also
aus jedem Arbeitsverzeichnis heraus aufrufen — etwa aus einem anderen Repo — vorausgesetzt, die
nötigen Variablen sind in dieser Shell bereits exportiert:

```bash
RUNPOD_GLM=/pfad/zu/runpod-glm
set -a; source "$RUNPOD_GLM/.env"; set +a   # nur nötig, wenn die Variablen in dieser .env liegen
"$RUNPOD_GLM/scripts/claude-glm.sh"
```

`claude` selbst nimmt weiterhin das Verzeichnis, aus dem du es aufrufst, als eigenen Projektkontext
— unabhängig davon, wo das Skript liegt.

Rufst du das Skript mehrfach auf, parallel oder aus verschiedenen Shells, startet das ebenso viele
getrennte `claude`-Sitzungen; es gibt keine Isolation pro Aufruf über das hinaus, was Claude Code
selbst mitbringt. Alle lösen sich auf denselben Pod/Endpunkt (`$URL`) auf und teilen sich dessen
GPU-Kapazität (siehe „Hinweis zur vLLM-Parallelität" unten).

Von Hand gleichwertig, ohne die Bereitschaftsprüfung:

```bash
export GLM_URL='https://POD_ID-8000.proxy.runpod.net'
export ANTHROPIC_BASE_URL="${GLM_URL%/}"
export ANTHROPIC_AUTH_TOKEN="$VLLM_API_KEY"
unset ANTHROPIC_API_KEY
export CLAUDE_CODE_MAX_CONTEXT_TOKENS=1048576
claude --model glm-5.3-flash
```

`VLLM_API_KEY` ist hier die clientseitige Kopie desselben Werts wie das RunPod Secret (siehe
`.env.example`). Das vLLM-Image stellt die Anthropic-artigen Endpunkte `/v1/messages` und
`/v1/messages/count_tokens` bereit (vom Betreiber verifiziert, einschließlich eines
Tool-Use-Durchlaufs). Der RunPod-HTTP-Proxy schließt Verbindungen nach 100 Sekunden (HTTP 524),
verwende daher Streaming-Clients; ein langsames erstes Token bei sehr langem Kontext kann sonst an
dieses Limit stoßen.

## Hinweis zur vLLM-Parallelität

`--max-num-seqs 6` (gesetzt in `create-pod.sh`) begrenzt die gleichzeitigen Sequenzen und damit die
KV-Cache-Nutzung beim 1M-Kontext; erhöhe es nicht, ohne Speicher und Latenz auf dem Pod zu messen.

## Hinweis zum vLLM-Speicher

`--gpu-memory-utilization 0.96` mit MTP5 beibehalten. Keinen festen KV-Cache-Bytewert
wiederverwenden, der ohne MTP gemessen wurde.

`HF_HUB_OFFLINE=1` (der Standard; `create-pod.sh --online` schaltet es ab) nimmt an, dass der
komplette Checkpoint schon auf dem persistenten Network Volume liegt.

## Startzeiten

Gemessene Startzeiten und die Methodik dahinter: **[docs/startup-times.de.md](startup-times.de.md)**.
