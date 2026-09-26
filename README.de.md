# runpod-glm-flash

Deutsch | [English](README.md)

IaC-Grundgerüst für das validierte GLM-5.3-Flash-Deployment auf einer NVIDIA B300 in RunPod Secure Cloud.

Alle Befehle unten werden aus dem Repository-Wurzelverzeichnis ausgeführt, sofern ein Block nichts anderes sagt.

## Aktuelle Architektur

- **Terraform:** offizieller Provider `runpod/runpod`, festgelegt auf `1.0.8` (`network_volume_id` braucht >= 1.0.6; 1.0.9 hat einen Schemafehler und lässt sich mit Terraform 1.14 nicht laden)
- **API-Basis:** `https://api.runpod.io/v2` (Standard im Repo, **mit dem Provider ungetestet**, siehe „Wichtiger Hinweis zum Provider“)
- **Pod:** Secure Cloud, 1× NVIDIA B300 SXM6 AC
- **Image:** `vllm/vllm-openai:glm53-flash`
- **Persistente Daten:** bestehendes Network Volume, eingehängt unter `/workspace`
- **Modell:** `nota-ai/GLM-5.3-Flash-Nota-NVFP4`
- **Kontext:** 1.048.576
- **KV:** FP8
- **Spec Decode:** MTP5
- **Auth:** RunPod Secret → `VLLM_API_KEY`

## Wichtiger Hinweis zum Provider

Der offizielle Provider (`runpod/runpod`, in der Terraform Registry veröffentlicht) ist **an REST API v1 ausgerichtet**: Sein Schema nennt als Standard-`base_url` `https://rest.runpod.io/v1`, und seine Pod-Felder (`image_name`, `docker_args`, `machine_id`, `network_volume_id`, `start_ssh`) sind v1-Namen. Die v2-API von RunPod verwendet einen anderen Body (`image`, `args`, `gpu{id,count}`, `mounts.network[{volumeId,path}]`, `dataCenterIds`) und kennt weder `machineId` noch `startSsh` noch `dockerArgs`.

Dieses Repo setzt `runpod_base_url` trotzdem standardmäßig auf die v2-URL. **Ob Provider 1.0.8 gegen `/v2` funktioniert, ist ungetestet.** Mögliche Folgen sind eine abgelehnte Anfrage (422/400) oder stillschweigend verworfene Felder wie `machine_id`/`start_ssh`. Vor dem ersten echten Apply:

1. Den schreibgeschützten Smoke-Test und `terraform plan` ausführen (der Plan allein ruft die API nicht auf, um etwas anzulegen).
2. Die Base-URL bewusst wählen: das native `https://rest.runpod.io/v1` des Providers (`runpod_base_url` in `terraform.tfvars` setzen; RunPod hat die Abschaltung von v1 angekündigt, also das aktuelle Datum prüfen) oder v2, geprüft mit einem Wegwerf-CPU-Pod.
3. Im Plan und nach dem Apply in der Console die B300-Auswahl, das Anhängen des Network Volumes, `docker_args` (Quoting von `--speculative-config`), Ports und die Secret-Platzhalter prüfen.

`machine_id` ist optional. Lass sie ungesetzt, dann wählt RunPod irgendeine Maschine mit freier B300 (Platzierung nach GPU-Typ und Datacenter des Network Volumes; die REST-v2-API selbst hat kein Maschinenfeld, und wie der Provider es abbildet, hängt von der API-Version ab, siehe oben). Nur festlegen, wenn es sein muss, und niemals raten. Eine festgelegte, belegte Maschine lässt den Apply fehlschlagen (siehe „Wenn die GPU belegt ist“).

## Secrets

Keine geheimen Werte gehören in dieses Repository oder in `terraform.tfvars`.

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

**Rechte des API-Keys:** Lesende Aufrufe (`v2-smoke.sh`, `gpu-availability.sh`, `pre-check.sh --online`) funktionieren mit einem Read-only-Key, aber `pod-start.sh`, `pod-stop.sh` und `terraform apply` brauchen Schreibzugriff auf Pods. Mit einem Read-only-Key oder einem zu eng eingeschränkten Key scheitern sie mit `HTTP 403` („Access to the requested resource was denied“). Das ist ein Rechteproblem, keine volle GPU. Lege in der RunPod-Console (Settings > API Keys) einen Key mit Schreibrecht an; RunPod empfiehlt eingeschränkte Keys mit den minimal nötigen Rechten. Beachte, dass `pre-check.sh --online` fehlendes Schreibrecht nicht erkennen kann, weil es nur liest.

Diese beiden separat in der RunPod-Console anlegen:

- `VLLM_API_KEY`
- `HF_TOKEN` (nur für ein frisches Setup mit `offline_mode = false` nötig)

Secret-Namen unterscheiden Groß- und Kleinschreibung und müssen exakt zu `vllm_secret_name` / `hf_secret_name` passen (Standard: `VLLM_API_KEY`, `HF_TOKEN`).

Terraform sendet nur die Platzhalter-Strings der RunPod Secrets. Ersetze sie nie durch das echte Token im HCL.

## 0. Vorab-Check

```bash
./scripts/pre-check.sh            # Werkzeuge, Umgebung, lokale Dateien
./scripts/pre-check.sh --online   # zusätzlich ein lesender API-Aufruf, um den Key zu prüfen
```

Prüft, ob `curl`, `python3` und `terraform` (Version aus `terraform/versions.tf`) installiert sind, ob `RUNPOD_API_KEY` exportiert ist (ein einfaches `. .env` exportiert nicht; nimm `set -a; source .env; set +a`) und ob `terraform.tfvars` vollständig ist. `ansible-playbook`, `RUNPOD_POD_ID`, `VLLM_API_KEY` und `ansible/inventory.yml` erzeugen nur Warnungen, weil sie erst später gebraucht werden. Secret-Werte werden nie ausgegeben. Exit-Code 1 bedeutet ein blockierendes Problem.

### Werkzeuge

Erforderlich: `curl`, `python3` und `terraform` (>= die Version in `terraform/versions.tf`). Installiere sie mit deinem Paketmanager; für Terraform gilt die offizielle Anleitung unter <https://developer.hashicorp.com/terraform/install>. Optional: `ansible-playbook` für den Prüfschritt (<https://docs.ansible.com/ansible/latest/installation_guide/>).

`runpodctl` wird von diesem Repo **nicht** gebraucht. Installiere es nur, wenn du es für andere Dinge willst, nach der Anleitung unter <https://docs.runpod.io/runpodctl/overview>. Ein sinnvoller Fall ist das Hinterlegen deines SSH-Public-Keys, den die Ansible-Prüfung braucht (`ssh-keygen -t ed25519`, dann entweder `~/.ssh/id_ed25519.pub` in das Feld SSH Public Keys deiner RunPod-Kontoeinstellungen einfügen oder `runpodctl ssh add-key --key-file ~/.ssh/id_ed25519.pub` ausführen).

## 1. Schreibgeschützter REST-v2-Check

```bash
./scripts/v2-smoke.sh
```

Das führt ein GET gegen `/v2/pods` aus und legt keine GPU an. Es gibt pro Pod nur ID, Name und Status aus, weil die Rohantwort die `env` jedes Pods enthält.

## 2. Konfigurieren

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
$EDITOR terraform/terraform.tfvars
```

Trage die ID des bestehenden Network Volumes ein. `machine_id` ist optional (siehe oben).

Ein Network Volume ist an ein Datacenter gebunden, deshalb muss eine B300 **in diesem Datacenter** frei sein; eine freie B300 anderswo hilft nicht. Prüfe den Bestand vorher mit `./scripts/gpu-availability.sh B300 <DATACENTER>` (ohne Datacenter nimmt es das Datacenter des Pods `RUNPOD_POD_ID`, falls gesetzt, sonst den Gesamtbestand; mit `any` erzwingst du den Gesamtbestand). `B300` trifft den exakten GPU-Namen; `gpu_type_id` nutzt die volle ID `NVIDIA B300 SXM6 AC`, die du ebenfalls übergeben kannst. Trifft keine ID und kein Name exakt, listet das Skript alle GPUs auf, die den Text enthalten, und sagt das. Exit-Codes: 0 Bestand vorhanden, 2 kein Bestand, 4 unbekannter GPU-Typ oder unbekanntes Datacenter (Tippfehler), 1 API-Fehler. Wenn du doch eine `machine_id` festlegst, muss sie im Datacenter des Volumes liegen.

`offline_mode` (Standard `true`) nimmt an, dass der Checkpoint schon auf dem Volume liegt: `HF_HUB_OFFLINE=1` wird gesetzt und kein `HF_TOKEN` gesendet. Für ein frisches Setup oder einen erneuten Download `offline_mode = false` setzen; dann sind Downloads erlaubt und das Secret `HF_TOKEN` wird eingespielt.

## 3. Nur planen

```bash
./scripts/plan.sh
```

`plan.sh` führt zuerst `scripts/pre-check.sh` aus (Werkzeuge, Umgebung, `terraform/terraform.tfvars` ohne `REPLACE_WITH_`-Platzhalter; Kommentare werden ignoriert, und Variablen aus `TF_VAR_*` oder `*.auto.tfvars` zählen ebenfalls); die Variablen `network_volume_id` und `machine_id` lehnen die Platzhalterwerte außerdem in Terraform selbst ab.

Der Plan wird in `terraform/tfplan` gespeichert, damit genau der geprüfte Plan angewendet wird. Prüfe den gesamten Plan. Achte auf Secure Cloud, B300, eine GPU, 50 GB Container-Disk, das bestehende Network Volume auf `/workspace`, das Image, die 1M/MTP5-Argumente, Port 8000 und darauf, dass keine Klartext-Secrets vorkommen.

## 4. Bewusst anwenden

```bash
(cd terraform && terraform apply tfplan)
```

Das ist der erste Schritt, der abrechnungspflichtige B300-Rechenzeit starten kann. Es gibt absichtlich kein automatisches Apply-Skript.

## 5. Mit Ansible prüfen

```bash
cd ansible
cp inventory.example.yml inventory.yml
$EDITOR inventory.yml
ansible-playbook playbook.yml
cd ..
```

Sicherheitshinweis: Der Pod öffnet `22/tcp` mit Root-Login (`start_ssh = true`), weil sich die Ansible-Rolle als `root` verbindet, und `ansible.cfg` setzt `host_key_checking = False`, weil sich die Host-Keys der Pods bei einem Redeploy ändern. Beides sind bewusste Kompromisse; nutze ausschließlich SSH-Keys und entferne `22/tcp` aus `ports` in `terraform/main.tf`, sobald du die Prüfung oder den Shell-Zugang nicht mehr brauchst.

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

`docs/schedule.example.yml` ist bewusst **deaktiviert** und liegt außerhalb von `.github/workflows/`, damit GitHub es nie ausführt. Es zeigt die vorgesehene GitHub-Actions-Form, ohne versehentliche GPU-Kosten zu riskieren: Der Start-Job ruft `scripts/start-when-free.sh` auf, das `pod-start.sh` alle 60 s wiederholt, höchstens `MAX_WAIT_SECONDS` lang (7200 = 2 h), solange die GPU des Pods belegt ist, und dann aufgibt und den Job fehlschlagen lässt (der Pod bleibt an diesem Tag gestoppt; GitHub benachrichtigt dich in der Regel, aber nicht zuverlässig); der Job hat eine harte `timeout-minutes`-Grenze; der Stopp-Job ruft `pod-stop.sh` auf; bei geplanten Läufen werden Start und Stopp aus dem Cron-Eintrag abgeleitet. Das API-Key-Secret braucht Schreibzugriff auf Pods. **Jeder erfolgreiche Start rechnet die GPU ab**, prüfe die Datei also sorgfältig, bevor du sie aktivierst. GitHub hält pro Concurrency-Gruppe nur einen wartenden Lauf: Löse keine manuellen Läufe aus, solange ein Start noch wiederholt, sonst kann ein eingereihter Stopp verworfen werden. Cron-Läufe können sich verspäten oder ausfallen, und geplante Workflows inaktiver öffentlicher Repos werden nach 60 Tagen deaktiviert; beides ist für den Stopp-Job relevant. Verschiebe die Datei erst nach `.github/workflows/` und aktiviere sie, wenn du Actions per SHA festgelegt und den Umgang mit der europäischen Sommerzeit entschieden hast.

Alle API-Aufrufe haben Zeitlimits (10 s Verbindungsaufbau, 60 s gesamt; überschreibbar mit `API_CONNECT_TIMEOUT` / `API_MAX_TIME`), damit eine hängende Verbindung einen geplanten Job nicht blockieren kann. Bricht die Verbindung ab, nachdem eine Start- oder Stopp-Anfrage gesendet wurde, sagen die Skripte, dass das Ergebnis unbekannt ist; prüfe vor einem neuen Versuch mit `scripts/v2-smoke.sh`.

`scripts/pod-start.sh` und `scripts/pod-stop.sh` rufen den REST-v2-Endpunkt `POST /v2/pods/{id}/action` auf (`start`/`stop`); `runpodctl` wird nicht gebraucht, nur `curl` und `python3`. Beide zeigen zuerst das Ziel an (Name, Status, Stundenkosten, Datacenter), damit eine veraltete `RUNPOD_POD_ID` auffällt, und tun nichts, wenn der Pod schon im gewünschten Zustand ist. Ein Start rechnet die GPU sofort ab. Das Stoppen ist für einen geplanten Betrieb riskant: siehe „Wenn die GPU belegt ist“. Automatisiere keinen zerstörerischen Redeploy, bevor das genaue Migrations-/Redeploy-Verhalten im Konto getestet ist.

## Wenn die GPU belegt ist

Ein gestoppter Pod behält seine Maschinenzuordnung und läuft auf demselben Host wieder an. Mietet in der Zwischenzeit jemand anderes die GPU, kann `pod start` nicht gelingen. Beobachtet am 2026-09-24: `HTTP 400 {"detail":"There are not enough free GPUs on the host machine to start this pod."}`; in diesem Fall wird nichts gestartet oder abgerechnet. Die RunPod-Doku beschreibt drei Wege:

1. **Warten.** Die GPU wird frei, sobald der andere Nutzer seinen Pod stoppt. `./scripts/start-when-free.sh [MAX_WAIT_SECONDS] [INTERVAL_SECONDS]` (Standard 7200 s, 60 s) wiederholt den eigentlichen Start, solange die GPU belegt ist, und endet nach einem Erfolg oder an der Grenze. Das ist das richtige Werkzeug für einen gestoppten Pod: Er läuft auf seiner eigenen Maschine wieder an, über die der Katalogbestand nichts aussagt, und ein fehlgeschlagener Versuch kostet nichts. `pod-start.sh` liefert Exit-Code 5 für „GPU belegt“ und 6 für „Pod nicht lesbar, nichts gesendet“ (bis zu 10-mal hintereinander wiederholt); jeder andere Fehler bricht sofort ab, damit ein womöglich gestarteter Pod nie doppelt gestartet wird. Ein Abbruch des Laufs stoppt den laufenden Versuch, aber eine bereits gesendete Start-Anfrage lässt sich nicht zurücknehmen (das Skript sagt dann, dass du `scripts/v2-smoke.sh` prüfen sollst). **Ein erfolgreicher Start rechnet die GPU ab.** Willst du nur benachrichtigt werden und nicht starten, fragt `./scripts/wait-for-gpu.sh B300` (nimmt das Datacenter deines Pods aus `RUNPOD_POD_ID`; ein anderes nennst du ausdrücklich, mit `any` gilt der Gesamtbestand) den Bestand schreibgeschützt alle 60 s ab und läutet die Terminal-Glocke, sobald die GPU verfügbar ist; es startet nie etwas (ein Tippfehler bei GPU oder Datacenter bricht mit Exit 4 ab, statt ewig zu warten). Der Bestand ändert sich innerhalb von Minuten, handle also sofort und rechne damit, dass ein Start trotzdem scheitern kann.
2. **Redeploy (empfohlen mit einem Network Volume).** Den Pod beenden und einen neuen anlegen, der dasselbe Volume anhängt; `/workspace` (Modell, HF- und vLLM-Caches) bleibt unberührt. Ist `machine_id` ungesetzt, sollte RunPod irgendeine Maschine mit freier B300 im Datacenter des Volumes wählen (im ersten Plan/Apply bestätigen):

   ```bash
   (cd terraform && terraform state list)    # ist runpod_pod.glm im State?
   (cd terraform && terraform apply -replace=runpod_pod.glm)   # ja: ersetzen
   ./scripts/plan.sh && (cd terraform && terraform apply tfplan)   # nein (z. B. Pod außerhalb von Terraform angelegt): normaler Plan und Apply
   ```

   Nutze vorher `./scripts/gpu-availability.sh`; ein Anlegen kann trotzdem wegen fehlender Kapazität scheitern.
3. **Console-Migration (Beta).** Die RunPod-Console bietet an, einen gestoppten Pod auf eine Maschine mit freier GPU zu migrieren. Ihre Doku beschreibt kein Gegenstück für API, CLI oder Terraform.

Nach `pod-stop.sh` steht der Pod auf `EXITED`, während der Terraform-State noch „läuft“ sagt; führe nach einem Stopp/Start kein `terraform apply` blind aus, sondern lies zuerst den Plan (ob ein Stopp ein vorgeschlagenes Update oder Replacement auslöst, ist ungetestet).

Redeploy und Migration erzeugen beide eine **neue Pod-ID, IP und Proxy-URL**. Aktualisiere danach `RUNPOD_POD_ID` (lokale `.env`, GitHub-Secret) und `GLM_URL` (Claude Code) und führe die Ansible-Prüfung erneut aus. Der Terraform-State folgt einem Redeploy über `-replace`, aber keiner Console-Migration; nach einer Migration ist die alte Ressource veraltet.

Für den 14/5-Zeitplan heißt das: Stopp/Start ist billig, kann aber über Nacht scheitern; Beenden/Neuanlegen ist robust gegen die Maschinenbindung, kann aber an der B300-Kapazität scheitern und ändert die Pod-ID täglich. Entscheide das bewusst. Ist die GPU um 05:00 belegt, wird der Start wiederholt (siehe „Warten“ oben), höchstens zwei Stunden lang; bleibt sie belegt, entfällt der Tag (nach der Grenze beginnt kein Versuch mehr; ein bereits laufender kann etwa 2 Minuten später enden).

## Kosten stoppen

- `pod-stop.sh` beendet die GPU-Abrechnung. Laut RunPod-Preisdoku wird ein gestoppter Pod nicht für seine Container-Disk berechnet (nur für eine Pod-lokale Volume-Disk, zu einem höheren Satz); das Network Volume wird getrennt abgerechnet (etwa 0,07 $/GB/Monat), egal ob ein Pod läuft.
- `terraform destroy` (aus `terraform/`) beendet den Pod und entfernt ihn aus dem State. Es löscht das Network Volume **nicht**, das hier nicht verwaltet wird, Modell und Caches bleiben also erhalten.
- `terraform apply -replace=runpod_pod.glm` zerstört zuerst und legt dann neu an: Fehlt in diesem Moment B300-Kapazität, bleibst du ohne Pod.

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

Die Gesamtzeit vom Pod-Start bis zum ersten erfolgreichen `/v1/models` ist **noch nicht gemessen**; zur Ladezeit kommen Container-Start, Kompilierung und Warm-up hinzu. Messen mit:

```bash
set -a; source .env; set +a
./scripts/start-when-free.sh 1200 30 && ./scripts/wait-for-ready.sh
```

`start-when-free.sh` wiederholt den Start alle 30 s bis zu 1200 s (20 Minuten), solange die GPU belegt ist, und endet nach dem ersten erfolgreichen Start; das Intervall muss mindestens 30 s betragen, und `pod-start.sh` rufst du nicht extra auf. Wegen des `&&` beginnt die Messung erst nach einem erfolgreichen Start und nie, wenn der Start gescheitert ist. Für einen einzelnen Versuch ohne Wiederholung nimm stattdessen `./scripts/pod-start.sh && ./scripts/wait-for-ready.sh`. `wait-for-ready.sh` braucht `VLLM_API_KEY` und `RUNPOD_POD_ID` (oder `GLM_URL`) in deiner `.env`; ohne den Key bricht es ab, nachdem der Pod schon gestartet ist und abrechnet. **Ein erfolgreicher Start rechnet die GPU ab.**

`wait-for-ready.sh` fragt `/v1/models` mit deinem `VLLM_API_KEY` ab (über `GLM_URL` oder `https://$RUNPOD_POD_ID-8000.proxy.runpod.net`), gibt die verstrichene Zeit aus und hängt sie an `.startup-times.log` an (git-ignoriert). Es liest nur. Jede Antwort außer 200 und 401/403 zählt als „noch nicht bereit“ (der RunPod-Proxy antwortet 502/524, während der Container hochfährt; auch 404, 500 und Verbindungsfehler werden wiederholt); 401/403 bricht ab, weil sich der Key nicht von selbst korrigiert. Antwortet der Pod schon bei der ersten Abfrage, wird nichts protokolliert (er lief bereits); war er beim Start des Skripts schon `STARTING`, ist die protokollierte Zeit nur teilweise. `GLM_URL` darf auf `/v1` enden, das wird entfernt. `VLLM_ENGINE_READY_TIMEOUT_S=3600` und die Ansible-Wartezeit von 3600 s sind großzügige Grenzen, keine Messwerte.

## Lizenz

MIT, siehe [LICENSE](LICENSE). Die Lizenz gilt nur für Code und Dokumentation dieses Repositorys, nicht für RunPod, das Modell oder das vLLM-Image, für die eigene Bedingungen gelten.
