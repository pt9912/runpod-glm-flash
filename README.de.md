# runpod-glm-flash

Deutsch | [English](README.md)

IaC-Grundgerüst für das validierte GLM-5.3-Flash-Deployment auf einer NVIDIA B300 in RunPod Secure Cloud.

Alle Befehle unten werden aus dem Repository-Wurzelverzeichnis ausgeführt, sofern ein Block nichts anderes sagt.

## Aktuelle Architektur

- **Pod-Anlage:** `scripts/create-pod.sh` (REST v2, direkt nach dem Anlegen geprüft). Der Pool der Pods wird mit `start-any.sh` / `stop-any.sh` verwaltet. Es gibt kein Terraform (siehe „Warum es kein Terraform gibt“)
- **API-Basis:** `https://api.runpod.io/v2` (von allen Skripten verwendet)
- **Pod:** Secure Cloud, 1× NVIDIA B300 SXM6 AC
- **Image:** `vllm/vllm-openai:glm53-flash`
- **Persistente Daten:** bestehendes Network Volume, eingehängt unter `/workspace`
- **Modell:** `nota-ai/GLM-5.3-Flash-Nota-NVFP4`
- **Kontext:** 1.048.576
- **KV:** FP8
- **Spec Decode:** MTP5
- **Auth:** RunPod Secret → `VLLM_API_KEY`

## Warum es kein Terraform gibt

Frühere Fassungen dieses Repositorys beschrieben den Pod mit Terraform (Provider `runpod/runpod` 1.0.8). Es wurde entfernt: **Am 2026-09-26 hat `terraform apply` einen falschen Pod angelegt** (eine H100 zu 3,49 $/h statt der B300, Port `8888/http` statt `8000/http`, keine vLLM-Argumente). Der Mitschnitt der Provider-Anfrage gegen einen lokalen Mock zeigte den Grund: Er sendete nur `name`, `cloudType`, `imageName`, `containerDiskInGb`, `gpuCount`, `env`, `networkVolumeId` und `volumeMountPath` und **verwarf stillschweigend `gpuTypeId`, `ports`, `dockerArgs` und `startSsh`**, mit der v1- wie mit der v2-Base-URL. `terraform plan` kann das nicht aufdecken, weil er zeigt, was Terraform vorhat, nicht was der Provider sendet.

Der Pod wird mit `scripts/create-pod.sh` angelegt: Es ruft den dokumentierten REST-v2-Endpunkt mit ausdrücklich gesetzten Feldern auf und prüft das Ergebnis gleich danach mit `scripts/verify-pod.sh`. Die Terraform-Dateien liegen weiter in der Git-Historie (vor dem Commit, der sie entfernt hat), falls der Provider repariert wird und du es erneut versuchen willst; prüfe dann mit einem Anfrage-Mitschnitt, nicht mit `plan`.

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

**Rechte des API-Keys:** Lesende Aufrufe (`v2-smoke.sh`, `gpu-availability.sh`, `pre-check.sh --online`) funktionieren mit einem Read-only-Key, aber `create-pod.sh`, `pod-start.sh`, `pod-stop.sh` und `pod-terminate.sh` brauchen Schreibzugriff auf Pods. Mit einem Read-only-Key oder einem zu eng eingeschränkten Key scheitern sie mit `HTTP 403` („Access to the requested resource was denied“). Das ist ein Rechteproblem, keine volle GPU. Lege in der RunPod-Console (Settings > API Keys) einen Key mit Schreibrecht an; RunPod empfiehlt eingeschränkte Keys mit den minimal nötigen Rechten. Beachte, dass `pre-check.sh --online` fehlendes Schreibrecht nicht erkennen kann, weil es nur liest.

Diese beiden separat in der RunPod-Console anlegen:

- `VLLM_API_KEY`
- `HF_TOKEN` (nur für ein frisches Setup mit `offline_mode = false` nötig)

Secret-Namen unterscheiden Groß- und Kleinschreibung und müssen exakt zu `vllm_secret_name` / `hf_secret_name` passen (Standard: `VLLM_API_KEY`, `HF_TOKEN`).

Die Pod-Definition enthält nur RunPod-Secret-Referenzen (`{{ RUNPOD_SECRET_<name> }}`), nie die Werte.

## 0. Vorab-Check

```bash
./scripts/pre-check.sh            # Werkzeuge, Umgebung, lokale Dateien
./scripts/pre-check.sh --online   # zusätzlich ein lesender API-Aufruf, um den Key zu prüfen
```

Prüft, ob `curl` und `python3` installiert sind, ob `RUNPOD_API_KEY` exportiert ist (ein einfaches `. .env` exportiert nicht; nimm `set -a; source .env; set +a`) und ob `NETWORK_VOLUME_ID` gesetzt ist. `ansible-playbook`, `RUNPOD_POD_ID`, `VLLM_API_KEY` und `ansible/inventory.yml` erzeugen nur Warnungen, weil sie erst später gebraucht werden. Secret-Werte werden nie ausgegeben. Exit-Code 1 bedeutet ein blockierendes Problem.

### Werkzeuge

Erforderlich: `curl` und `python3`. Installiere sie mit deinem Paketmanager. Optional: `ansible-playbook` für den Prüfschritt (<https://docs.ansible.com/ansible/latest/installation_guide/>).

`runpodctl` wird von diesem Repo **nicht** gebraucht. Installiere es nur, wenn du es für andere Dinge willst, nach der Anleitung unter <https://docs.runpod.io/runpodctl/overview>. Ein sinnvoller Fall ist das Hinterlegen deines SSH-Public-Keys, den die Ansible-Prüfung braucht (`ssh-keygen -t ed25519`, dann entweder `~/.ssh/id_ed25519.pub` in das Feld SSH Public Keys deiner RunPod-Kontoeinstellungen einfügen oder `runpodctl ssh add-key --key-file ~/.ssh/id_ed25519.pub` ausführen).

## 1. Schreibgeschützter REST-v2-Check

```bash
./scripts/v2-smoke.sh
```

Das führt ein GET gegen `/v2/pods` aus und legt keine GPU an. Es gibt pro Pod nur ID, Name und Status aus, weil die Rohantwort die `env` jedes Pods enthält.

## 2. Konfigurieren

Trage die ID deines bestehenden Network Volumes in die `.env` ein (Vorlage: `.env.example`):

```bash
echo 'NETWORK_VOLUME_ID=<your Network Volume ID>' >> .env
```

Ein Network Volume ist an ein Datacenter gebunden, deshalb muss eine B300 **in diesem Datacenter** frei sein; eine freie B300 anderswo hilft nicht. `create-pod.sh` legt den Pod automatisch im Datacenter des Volumes an. Prüfe den Bestand vorher mit `./scripts/gpu-availability.sh B300 <DATACENTER>` (ohne Datacenter nimmt es das Datacenter des Pods `RUNPOD_POD_ID`, falls gesetzt, sonst den Gesamtbestand; mit `any` erzwingst du den Gesamtbestand). `B300` trifft den exakten GPU-Namen; die volle GPU-ID lautet `NVIDIA B300 SXM6 AC`, die du ebenfalls übergeben kannst. Trifft keine ID und kein Name exakt, listet das Skript alle GPUs auf, die den Text enthalten, und sagt das. Exit-Codes: 0 Bestand vorhanden, 2 kein Bestand, 4 unbekannter GPU-Typ oder unbekanntes Datacenter (Tippfehler), 1 API-Fehler.

Standardmäßig läuft der Pod im Offline-Modus: Der Checkpoint wird auf dem Volume erwartet, `HF_HUB_OFFLINE=1` wird gesetzt und kein `HF_TOKEN` gesendet. Für ein frisches Setup oder einen erneuten Download `create-pod.sh --online` verwenden; dann sind Downloads erlaubt und das Secret `HF_TOKEN` wird eingespielt.

## 3. Trockenlauf

```bash
./scripts/create-pod.sh
```

Der Standard ist ein **Trockenlauf**: Es liest das Datacenter des Volumes, bricht ab, wenn schon ein Pod mit demselben Namen existiert, zeigt die vollständige Anfrage (nur RunPod-Secret-Referenzen, keine geheimen Werte) samt aktuellem Bestand und legt nichts an. Optionen: `--online` (Downloads erlaubt), `--no-ssh` (kein `22/tcp` und kein `startSsh`). Überschreibbar über die Umgebung: `POD_NAME`, `GPU_ID`, `DATACENTER`, `CONTAINER_DISK_GB`, `VLLM_SECRET_NAME`, `HF_SECRET_NAME`.

Prüfe die Anfrage: 1× B300, `mounts.network` mit deinem Volume auf `/workspace`, Port 8000, das Image, die vLLM-Argumente (1M-Kontext, MTP, `--max-num-seqs 6`) und dass `VLLM_API_KEY` eine `{{ RUNPOD_SECRET_... }}`-Referenz ist.

## 4. Den Pod anlegen

```bash
./scripts/create-pod.sh --yes
```

Das ist der Schritt, der abrechnungspflichtige B300-Rechenzeit startet (etwa 7,89 $/h). Das Skript wiederholt nie eine Anfrage, die womöglich gesendet wurde. Danach führt es `scripts/verify-pod.sh` aus (nur lesend): 1× B300, das Volume auf `/workspace`, Port 8000, `VLLM_API_KEY` als Secret-Referenz (nie leer, nie ein Klartextwert), die Caches auf `/workspace` und die wichtigen vLLM-Argumente; es gibt nur Namen von Env-Variablen aus, nie Werte. Bei Erfolg trägst du die ausgegebene Pod-ID als `RUNPOD_POD_ID` in die `.env` ein. Schlägt die Prüfung fehl, ist der Pod falsch und rechnet ab, deshalb **stoppt das Skript ihn sofort und benennt ihn in `failed-<name>-<id>` um**: Die Abrechnung endet, der Pod verlässt den Pool (siehe unten) und wird nie versehentlich neu gestartet, bleibt aber zum Untersuchen erhalten. Mit `--terminate-on-fail` wird er stattdessen gelöscht. Scheitert das Stoppen, sagt die Meldung, dass der Pod weiter abrechnet, und nennt den Befehl zum Beenden:

```bash
RUNPOD_POD_ID=<the new ID> ./scripts/pod-terminate.sh --yes
```

`pod-terminate.sh` löscht einen Pod dauerhaft (ohne `--yes` zeigt es nur das Ziel); das Network Volume ist eine eigene Ressource und bleibt, Modell und Caches überleben also. `create-pod.sh` legt keinen zweiten Pod an, solange ein anderer Pod des Pools aktiv ist (`--force` hebt das auf) und nimmt eine Sperre, damit zwei Läufe auf demselben Rechner nicht gleichzeitig anlegen. Exit-Codes von `create-pod.sh`: 0 fertig, 1 Fehler oder gescheiterte Prüfung, 2 falsche Argumente, 3 ein Pod mit diesem Namen existiert oder ein Pool-Pod ist aktiv, 4 ein anderer Start/Anlegen läuft, 5 keine Kapazität (nichts angelegt; nur die Antwort „no instances available“ zählt als Kapazität, jedes andere HTTP 400 ist eine abgelehnte Anfrage). Jeden Pod kannst du später mit `./scripts/verify-pod.sh [POD_ID]` prüfen.

## 5. Mit Ansible prüfen

```bash
cd ansible
cp inventory.example.yml inventory.yml
$EDITOR inventory.yml
ansible-playbook playbook.yml
cd ..
```

Sicherheitshinweis: Der Pod öffnet `22/tcp` mit Root-Login (`startSsh`), weil sich die Ansible-Rolle als `root` verbindet, und `ansible.cfg` setzt `host_key_checking = False`, weil sich die Host-Keys der Pods bei einem Redeploy ändern. Beides sind bewusste Kompromisse; nutze ausschließlich SSH-Keys und lege den Pod mit `create-pod.sh --no-ssh` an (kein `22/tcp`, kein `startSsh`), sobald du die Prüfung oder den Shell-Zugang nicht mehr brauchst.

**Voraussetzungen für SSH (für dieses Setup ungeprüft):** Dein RunPod-Konto braucht hinterlegte SSH-Public-Keys (sie werden als `PUBLIC_KEY` eingespielt), und im Container muss tatsächlich ein sshd laufen. `docker_args` ersetzt den Startbefehl des Images durch `vllm serve`, und es ist nicht bekannt, ob das vLLM-Image openssh-server mitbringt oder startet. Antwortet Port 22 nicht, kann die Ansible-Rolle nicht laufen. Ausweg: von außen über den HTTP-Proxy prüfen, `curl -i https://POD_ID-8000.proxy.runpod.net/v1/models` (erwartet 401 ohne Key, 200 mit `Authorization: Bearer $VLLM_API_KEY`).

Die Rolle liest `VLLM_API_KEY` aus der Shell-Umgebung und greift auf `/proc/1/environ` zurück, weil RunPod Container-Umgebungsvariablen in PID 1 einspielt und SSH-Login-Shells sie oft nicht sehen.

Die Rolle prüft die GPU, die persistenten Caches, das authentifizierte `/v1/models`, die Modell-ID und den maximalen 1M-Kontext. Sie schlägt außerdem fehl, wenn `VLLM_API_KEY` leer oder noch ein nicht aufgelöster `RUNPOD_SECRET_...`-Platzhalter ist (z. B. nach einem falsch geschriebenen Secret-Namen), weil die API sonst mit einem erratbaren Key liefe.

## 14/5-Zeitplan

Der vorgesehene Zeitplan ist **05:00 bis 19:00 Ortszeit, Montag bis Freitag** (14 Stunden, 5 Tage). Der frühe Start ist Absicht: Nach Erfahrung des Betreibers ist eine freie B300 früh am Morgen leichter zu finden (hier nicht verifiziert; der Bestand ändert sich innerhalb von Minuten, prüfe mit `scripts/gpu-availability.sh` oder `scripts/wait-for-gpu.sh`).

| | Start 05:00 | Stopp 19:00 |
|---|---|---|
| Sommerzeit (CEST, UTC+2) | 03:00 UTC | 17:00 UTC |
| Winterzeit (CET, UTC+1) | 04:00 UTC | 18:00 UTC |

GitHub-Actions-Cron läuft nur in UTC, deshalb müssen die Cron-Zeilen zweimal im Jahr geändert werden (letzter Sonntag im März und im Oktober), oder du nutzt einen zeitzonenfähigen externen Scheduler.

`docs/schedule.example.yml` ist bewusst **deaktiviert** und liegt außerhalb von `.github/workflows/`, damit GitHub es nie ausführt. Es zeigt die vorgesehene GitHub-Actions-Form, ohne versehentliche GPU-Kosten zu riskieren: Der Start-Job ruft `scripts/start-any.sh` auf, das die Pool-Pods nacheinander neu startet und einen neuen anlegt, wenn keiner startet, und das alle 60 s wiederholt, höchstens `MAX_WAIT_SECONDS` lang (7200 = 2 h), und dann aufgibt und den Job fehlschlagen lässt (der Pod bleibt an diesem Tag gestoppt; GitHub benachrichtigt dich in der Regel, aber nicht zuverlässig); der Job hat eine harte `timeout-minutes`-Grenze; der Stopp-Job ruft `scripts/stop-any.sh` auf; bei geplanten Läufen werden Start und Stopp aus dem Cron-Eintrag abgeleitet. Die Secrets sind `RUNPOD_API_KEY` (Schreibzugriff auf Pods) und `NETWORK_VOLUME_ID` (zum Anlegen neuer Pods nötig). **Jeder erfolgreiche Start rechnet die GPU ab**, prüfe die Datei also sorgfältig, bevor du sie aktivierst. GitHub hält pro Concurrency-Gruppe nur einen wartenden Lauf: Löse keine manuellen Läufe aus, solange ein Start noch wiederholt, sonst kann ein eingereihter Stopp verworfen werden. Cron-Läufe können sich verspäten oder ausfallen, und geplante Workflows inaktiver öffentlicher Repos werden nach 60 Tagen deaktiviert; beides ist für den Stopp-Job relevant. Verschiebe die Datei erst nach `.github/workflows/` und aktiviere sie, wenn du Actions per SHA festgelegt und den Umgang mit der europäischen Sommerzeit entschieden hast.

Alle API-Aufrufe haben Zeitlimits (10 s Verbindungsaufbau, 60 s gesamt; überschreibbar mit `API_CONNECT_TIMEOUT` / `API_MAX_TIME`), damit eine hängende Verbindung einen geplanten Job nicht blockieren kann. Bricht die Verbindung ab, nachdem eine Start- oder Stopp-Anfrage gesendet wurde, sagen die Skripte, dass das Ergebnis unbekannt ist; prüfe vor einem neuen Versuch mit `scripts/v2-smoke.sh`.

`scripts/pod-start.sh` und `scripts/pod-stop.sh` rufen den REST-v2-Endpunkt `POST /v2/pods/{id}/action` auf (`start`/`stop`); `runpodctl` wird nicht gebraucht, nur `curl` und `python3`. Beide zeigen zuerst das Ziel an (Name, Status, Stundenkosten, Datacenter), damit eine veraltete `RUNPOD_POD_ID` auffällt, und tun nichts, wenn der Pod schon im gewünschten Zustand ist. Ein Start rechnet die GPU sofort ab. Das Stoppen ist für einen geplanten Betrieb riskant: siehe „Wenn die GPU belegt ist“. Automatisiere keinen zerstörerischen Redeploy, bevor das genaue Migrations-/Redeploy-Verhalten im Konto getestet ist.

## Wenn die GPU belegt ist

Ein gestoppter Pod behält seine Maschinenzuordnung und läuft auf demselben Host wieder an. Mietet in der Zwischenzeit jemand anderes die GPU, kann `pod start` nicht gelingen. Beobachtet am 2026-09-24: `HTTP 400 {"detail":"There are not enough free GPUs on the host machine to start this pod."}`; in diesem Fall wird nichts gestartet oder abgerechnet. Die RunPod-Doku beschreibt drei Wege:

1. **Warten.** Die GPU wird frei, sobald der andere Nutzer seinen Pod stoppt. `./scripts/start-when-free.sh [MAX_WAIT_SECONDS] [INTERVAL_SECONDS]` (Standard 7200 s, 60 s) wiederholt den eigentlichen Start, solange die GPU belegt ist, und endet nach einem Erfolg oder an der Grenze. Das ist das richtige Werkzeug für einen gestoppten Pod: Er läuft auf seiner eigenen Maschine wieder an, über die der Katalogbestand nichts aussagt, und ein fehlgeschlagener Versuch kostet nichts. `pod-start.sh` liefert Exit-Code 5 für „GPU belegt“ und 6 für „Pod nicht lesbar, nichts gesendet“ (`start-when-free.sh` wiederholt 6 bis zu 10-mal hintereinander; `start-any.sh` überspringt einen solchen Pod in dieser Runde); jeder andere Fehler bricht sofort ab, damit ein womöglich gestarteter Pod nie doppelt gestartet wird. Ein Abbruch des Laufs stoppt den laufenden Versuch, aber eine bereits gesendete Start-Anfrage lässt sich nicht zurücknehmen (das Skript sagt dann, dass du `scripts/v2-smoke.sh` prüfen sollst). **Ein erfolgreicher Start rechnet die GPU ab.** Willst du nur benachrichtigt werden und nicht starten, fragt `./scripts/wait-for-gpu.sh B300` (nimmt das Datacenter deines Pods aus `RUNPOD_POD_ID`; ein anderes nennst du ausdrücklich, mit `any` gilt der Gesamtbestand) den Bestand schreibgeschützt alle 60 s ab und läutet die Terminal-Glocke, sobald die GPU verfügbar ist; es startet nie etwas (ein Tippfehler bei GPU oder Datacenter bricht mit Exit 4 ab, statt ewig zu warten). Der Bestand ändert sich innerhalb von Minuten, handle also sofort und rechne damit, dass ein Start trotzdem scheitern kann.
2. **Redeploy (empfohlen mit einem Network Volume).** Einen neuen Pod anlegen, der dasselbe Volume anhängt; `/workspace` (Modell, HF- und vLLM-Caches) bleibt unberührt, und laut RunPod-Doku kann ein Network Volume an mehrere Pods angehängt werden, der gestoppte Pod muss also nicht zuerst beendet werden. RunPod wählt eine Maschine mit freier B300 im Datacenter des Volumes:

   ```bash
   ./scripts/create-pod.sh          # Trockenlauf
   ./scripts/create-pod.sh --yes    # legt an und prüft (rechnet die GPU ab)
   ```

   Nutze vorher `./scripts/gpu-availability.sh`; ein Anlegen kann trotzdem wegen fehlender Kapazität scheitern (Exit-Code 5, nichts angelegt).
3. **Console-Migration (Beta).** Die RunPod-Console bietet an, einen gestoppten Pod auf eine Maschine mit freier GPU zu migrieren. Ihre Doku beschreibt kein Gegenstück für API oder CLI.

Redeploy und Migration erzeugen beide eine **neue Pod-ID, IP und Proxy-URL**. Aktualisiere danach `RUNPOD_POD_ID` (lokale `.env`, GitHub-Secret) und `GLM_URL` (Claude Code) und führe die Ansible-Prüfung erneut aus.

Für den 14/5-Zeitplan heißt das: Stopp/Start ist billig, kann aber über Nacht scheitern; Beenden/Neuanlegen ist robust gegen die Maschinenbindung, kann aber an der B300-Kapazität scheitern und ändert die Pod-ID täglich. Entscheide das bewusst. Ist die GPU um 05:00 belegt, wird der Start wiederholt (siehe „Warten“ oben), höchstens zwei Stunden lang; bleibt sie belegt, entfällt der Tag (nach der Grenze beginnt kein Versuch mehr; ein bereits laufender kann etwa 2 Minuten später enden).

## Pod-Pool: mehrere Pods auf verschiedenen Maschinen

Ein gestoppter Pod läuft nur auf seiner eigenen Maschine wieder an (siehe oben). Mehrere Pods auf verschiedenen Maschinen erhöhen die Chance, dass einer davon startet, und ein Neustart ist schneller als ein neuer Pod (5:56 min gegenüber 10:09 min, gemessen). Ein gestoppter Pod kostet pro Stunde nichts, und das Network Volume wird geteilt und nur einmal abgerechnet; ob RunPod die Zahl der Pods pro Konto begrenzt, wurde nicht geprüft.

**Der Pool wird nirgends gespeichert.** Er besteht aus allen Pods deines Kontos, deren Name mit `glm-5.3-flash-b300` **beginnt** (`POOL_PREFIX`), bei jedem Aufruf live gelesen und ohne beendete Pods. Es werden keine Pod-IDs ins Repository oder in die `.env` geschrieben, und Pods mit anderen Namen werden nie angefasst.

```bash
./scripts/start-any.sh --dry-run    # show the pool, the order and the next name; sends nothing
./scripts/start-any.sh --wait       # get one Pod running, then measure the time to ready
./scripts/stop-any.sh               # stop the running pool Pod (ends the GPU billing)
```

`start-any.sh [--no-create] [--dry-run] [--wait] [MAX_WAIT_SECONDS] [INTERVAL_SECONDS]` (Standard 1200 s und 30 s, Intervall mindestens 30 s) arbeitet in Runden:

1. Ist schon ein Pool-Pod aktiv (jeder Status außer `EXITED`, `ERROR` und `TERMINATED`, ein unerwarteter Status zählt also auch als aktiv), tut es nichts: **nie zwei Pool-Pods gleichzeitig** (sie teilen `/workspace/vllm-cache` und würden doppelt abrechnen). Eine Sperre in `$TMPDIR` verhindert außerdem, dass zwei Läufe auf demselben Rechner gleichzeitig starten oder anlegen (der zweite endet mit Code 4).
2. Es versucht, die gestoppten Pool-Pods nacheinander zu starten, den zuletzt benutzten zuerst. Ein Versuch auf einer belegten Maschine kostet nichts.
3. Startet keiner und hat der Pool weniger als `POOL_MAX` Pods (Standard 6), legt es wie `create-pod.sh --yes` einen neuen Pod an, benannt `glm-5.3-flash-b300`, `glm-5.3-flash-b300-2` usw. (`--no-create` schaltet das ab), und prüft ihn mit `verify-pod.sh`.
4. Sonst wartet es und wiederholt. Nach `MAX_WAIT_SECONDS` beginnt kein Versuch mehr (Exit-Code 3); ein bereits laufender wird nicht abgebrochen, und bei vielen Pool-Pods kann eine Runde Minuten dauern (jeder versuchte Pod kostet bis zu zwei API-Aufrufe zu je bis zu 60 s; eine Runde macht etwa 5 + 2N Aufrufe bei N gestoppten Pods).

Wiederholt werden nur „Maschine belegt“ (`pod-start.sh` Exit 5), „keine Kapazität“ (`create-pod.sh` Exit 5) und ein vorübergehend nicht lesbarer Pod. Jeder andere Fehler bricht sofort ab, damit ein womöglich gestarteter oder angelegter Pod nie wiederholt wird. Besteht ein angelegter Pod die Prüfung nicht, stoppt und benennt `create-pod.sh` ihn um (siehe Schritt 4), und `start-any.sh` bricht ab, ohne etwas anderes zu versuchen. Ein Abbruch stoppt den laufenden Versuch, aber eine bereits gesendete Anfrage lässt sich nicht zurücknehmen. **Ein Erfolg rechnet die GPU ab (etwa 7,89 $/h).**

Das Skript gibt ID und URL des laufenden Pods aus (`RUNPOD_POD_ID`, `GLM_URL`). Mit einem Pool muss die ID in der `.env` nicht mehr den laufenden Pod nennen; `--wait` misst genau diesen Pod (eine alte `GLM_URL` aus der `.env` wird dafür ignoriert; `READY_TIMEOUT` setzt die Wartezeit in Sekunden, Standard 3600). Läuft der Pod, aber `wait-for-ready.sh` kann die Bereitschaft nicht bestätigen, ist der Exit-Code 7, und die Meldung sagt, dass der Pod läuft und abrechnet. Nicht mehr gebrauchte Pods entfernst du mit `pod-terminate.sh` (das Volume bleibt); bei vollem Pool wird kein neuer Pod angelegt. Exit-Codes: 0 ein Pool-Pod läuft, 3 aufgegeben (nichts läuft), 4 ein anderer Start/Anlegen läuft, 7 läuft, aber Bereitschaft nicht bestätigt (`--wait`), 130 abgebrochen, 2 falsche Argumente, 1 anderer Fehler.

## Kosten stoppen

- `pod-stop.sh` (ein Pod) und `stop-any.sh` (jeder aktive Pool-Pod; es versucht das Lesen der Pod-Liste bis zu fünfmal, bevor es aufgibt) beenden die GPU-Abrechnung. Laut RunPod-Preisdoku wird ein gestoppter Pod nicht für seine Container-Disk berechnet (nur für eine Pod-lokale Volume-Disk, zu einem höheren Satz); das Network Volume wird getrennt abgerechnet (etwa 0,07 $/GB/Monat), egal ob ein Pod läuft.
- `pod-terminate.sh --yes` löscht einen Pod dauerhaft. Es löscht das Network Volume **nicht**, Modell und Caches bleiben also erhalten.

## Optional: Runpod-MCP-Server

Dieses Repo braucht kein MCP. Runpod bietet zwei [MCP-Server](https://docs.runpod.io/get-started/mcp-servers), mit denen ein KI-Coding-Agent wie Claude Code direkt mit Runpod arbeiten kann. Die Befehle unten stammen aus der Runpod-Dokumentation und wurden mit diesem Repo nicht getestet; die Skripte hier funktionieren auch ohne sie.

**Docs-Server** (nur lesende Dokumentationssuche, ohne Anmeldung):

```bash
claude mcp add runpod-docs --scope user --transport http https://docs.runpod.io/mcp
```

**API-Server** (verwaltet Pods, Endpoints, Templates, Network Volumes und Registries über die REST-API, standardmäßig v2). Er hat **Schreibzugriff auf dein Konto und kann abrechnungspflichtige Pods starten**, behandle ihn also wie den API-Key selbst. Empfohlen ist der gehostete Server mit „Sign in with Runpod“ (OAuth): Beim ersten Gebrauch öffnet sich ein Browser, und es wird kein Key auf der Platte gespeichert.

```bash
claude mcp add --transport http runpod -s user https://mcp.getrunpod.io/
```

Alternativen:

- Geführter Installer, erkennt deine Clients (Claude Code, Claude Desktop, Cursor, Windsurf, VS Code): `npx @runpod/mcp-server@latest add`; rückgängig mit `npx @runpod/mcp-server@latest remove`.
- Gehosteter Server mit API-Key statt OAuth: `--header "Authorization: Bearer $RUNPOD_API_KEY"` an den obigen Befehl anhängen.
- Lokaler Server: `claude mcp add runpod --scope user -e RUNPOD_API_KEY=... -- npx -y @runpod/mcp-server@latest`. Der Key liegt dann in deiner Claude-Code-Konfiguration, deshalb ist die OAuth-Variante vorzuziehen.

Faustregeln:

- `-s user` / `--scope user` verwenden. Eine projektbezogene Konfiguration wird in eine `.mcp.json` im Repository geschrieben und könnte in einem Commit landen; lege dort nie einen Key ab.
- Einen API-Key mit nur den nötigen Rechten verwenden (siehe „Rechte des API-Keys“) und ihn deaktivieren oder löschen, wenn du ihn nicht mehr brauchst.
- Die Verbindung mit `/mcp` in Claude Code prüfen; einen Server mit `claude mcp remove runpod` entfernen.
- Pods über einen Agenten zu starten oder anzulegen rechnet die GPU genauso ab wie die Skripte. Prüfe weiter, was der Agent gleich tun will.

## Claude Code

```bash
export GLM_URL='https://POD_ID-8000.proxy.runpod.net'
export ANTHROPIC_BASE_URL="${GLM_URL%/}"
export ANTHROPIC_AUTH_TOKEN="$VLLM_API_KEY"
unset ANTHROPIC_API_KEY
export CLAUDE_CODE_MAX_CONTEXT_TOKENS=1048576
claude --model glm-5.3-flash
```

`VLLM_API_KEY` ist hier die clientseitige Kopie desselben Werts wie das RunPod Secret (siehe `.env.example`). Das vLLM-Image stellt die Anthropic-artigen Endpunkte `/v1/messages` und `/v1/messages/count_tokens` bereit (vom Betreiber verifiziert, einschließlich eines Tool-Use-Durchlaufs). Der RunPod-HTTP-Proxy schließt Verbindungen nach 100 Sekunden (HTTP 524), verwende daher Streaming-Clients; ein langsames erstes Token bei sehr langem Kontext kann sonst an dieses Limit stoßen.

## Hinweis zur vLLM-Parallelität

`--max-num-seqs 6` entspricht dem zuvor validierten Pod (seine Konfiguration wurde am 2026-09-24 über die API gelesen). Es begrenzt die gleichzeitigen Sequenzen und damit die KV-Cache-Nutzung beim 1M-Kontext; erhöhe es nicht, ohne Speicher und Latenz auf dem Pod zu messen.

## Hinweis zum vLLM-Speicher

`--gpu-memory-utilization 0.96` mit MTP5 beibehalten. Keinen festen KV-Cache-Bytewert wiederverwenden, der ohne MTP gemessen wurde.

`HF_HUB_OFFLINE=1` (Standard, `offline_mode = true`) nimmt an, dass der komplette Checkpoint schon auf dem persistenten Network Volume liegt.

## Startzeiten

Werte, die der Betreiber am validierten Deployment gemessen hat (B300, `--safetensors-load-strategy prefetch`, Checkpoint bereits auf dem Network Volume). Sie stammen nicht von den Skripten dieses Repos:

| Phase | Zeit |
|---|---|
| Modell laden ohne `prefetch` | etwa 1128 s (18:48 min) |
| Modell laden mit `prefetch` | etwa 216 s (3:36 min); der vollständige Prefetch dauerte etwa 233 s |
| FlashInfer-Autotune | etwa 3 min, nur beim ersten Lauf; das Ergebnis wird unter `/workspace/vllm-cache` zwischengespeichert |
| **Gesamt, neuer Pod auf neuer Maschine** (Pod-Start bis zur ersten 200 von `/v1/models`) | **609 s (10:09 min), ±15 s**; am 2026-09-26 gemessen, Abfrage alle 15 s ab `startedAt` des Pods (Modell und `vllm-cache` schon auf dem Volume) |
| **Gesamt, Neustart eines gestoppten Pods auf seiner alten Maschine** | **356 s (5:56 min), ±10 s**; am 2026-09-26 mit `start-when-free.sh` und `wait-for-ready.sh` ab `startedAt` aus der API gemessen |

Jede Gesamtzeit wurde **einmal** gemessen. Der neue Pod lief auf einer Maschine, auf der er zuvor nicht lief, Image und Container-Aufbau sind also enthalten; ein Download der Gewichte steckt in keiner der beiden Zeiten. Der Neustart eines gestoppten Pods auf seiner alten Maschine war etwa vier Minuten schneller (plausibel, weil das Image dort schon liegt, was nicht gemessen ist). Miss es selbst mit:

```bash
set -a; source .env; set +a
./scripts/start-when-free.sh 1200 30 && ./scripts/wait-for-ready.sh
```

`start-when-free.sh` wiederholt den Start alle 30 s bis zu 1200 s (20 Minuten), solange die GPU belegt ist, und endet nach dem ersten erfolgreichen Start; das Intervall muss mindestens 30 s betragen, und `pod-start.sh` rufst du nicht extra auf. Wegen des `&&` beginnt die Messung erst nach einem erfolgreichen Start und nie, wenn der Start gescheitert ist. Für einen einzelnen Versuch ohne Wiederholung nimm stattdessen `./scripts/pod-start.sh && ./scripts/wait-for-ready.sh`. `wait-for-ready.sh` braucht `VLLM_API_KEY` und `RUNPOD_POD_ID` (oder `GLM_URL`) in deiner `.env`; ohne den Key bricht es ab, nachdem der Pod schon gestartet ist und abrechnet. **Ein erfolgreicher Start rechnet die GPU ab.**

`wait-for-ready.sh` fragt `/v1/models` mit deinem `VLLM_API_KEY` ab (über `GLM_URL` oder `https://$RUNPOD_POD_ID-8000.proxy.runpod.net`), gibt die verstrichene Zeit aus und hängt sie an `.startup-times.log` an (git-ignoriert, mit `source=startedAt` oder `source=script`). Die Uhr startet bei `startedAt` des Pods aus der API (braucht `RUNPOD_API_KEY` und die Pod-ID aus der Proxy-URL oder `RUNPOD_POD_ID`), das Ergebnis hängt also nicht davon ab, wann du das Skript startest; die API hat `startedAt` bei einem Neustart in der Messung vom 2026-09-26 aktualisiert, und deine lokale Uhr muss stimmen. Andernfalls sagt das Skript das und zählt ab seinem eigenen Start. Die Auflösung ist das Abfrageintervall (standardmäßig 15 s). Es liest nur. Jede Antwort außer 200 und 401/403 zählt als „noch nicht bereit“ (der RunPod-Proxy antwortet 502/524, während der Container hochfährt; auch 404, 500 und Verbindungsfehler werden wiederholt); 401/403 bricht ab, weil sich der Key nicht von selbst korrigiert. Antwortet der Pod schon bei der ersten Abfrage, wird nichts protokolliert (er lief bereits); war er beim Start des Skripts schon `STARTING`, ist die protokollierte Zeit nur teilweise. `GLM_URL` darf auf `/v1` enden, das wird entfernt. `VLLM_ENGINE_READY_TIMEOUT_S=3600` und die Ansible-Wartezeit von 3600 s sind großzügige Grenzen, keine Messwerte.

## Lizenz

MIT, siehe [LICENSE](LICENSE). Die Lizenz gilt nur für Code und Dokumentation dieses Repositorys, nicht für RunPod, das Modell oder das vLLM-Image, für die eigene Bedingungen gelten.
