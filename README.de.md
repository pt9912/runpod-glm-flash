# runpod-glm-flash

Deutsch | [English](README.md)

Bash-Werkzeuge für das validierte GLM-5.3-Flash-Deployment (vLLM, 1M Kontext) auf einer NVIDIA B300 in RunPod Secure Cloud.

**Vollständige Dokumentation:** alle `make`-Targets, Exit-Codes, Docker/Make-Interna, Scheduling, der Pool, MCP-Server, Claude Code und vLLM-Hinweise stehen in **[docs/guide.de.md](docs/guide.de.md)**; gemessene Startzeiten stehen in **[docs/startup-times.de.md](docs/startup-times.de.md)**.

## Voraussetzungen

`docker` und `make`. Jedes Skript in diesem Repo läuft über `make <target>`, containerisiert (siehe `Dockerfile`); `curl`/`python3` musst du dafür nicht lokal installieren, und `scripts/*.sh` rufst du nicht direkt auf (Ausnahme: `scripts/claude-glm.sh`, siehe die Anleitung).

## Einrichten

```bash
cp .env.example .env
$EDITOR .env   # RUNPOD_API_KEY und NETWORK_VOLUME_ID eintragen
```

`VLLM_API_KEY` und (nur für ein frisches Setup) `HF_TOKEN` werden als RunPod Secrets angelegt, nicht in die `.env`; siehe den Abschnitt „Secrets“ der Anleitung für API-Key-Rechte und Secret-Namen.

## Schnellstart

```bash
make create ARGS=--yes   # legt den Pod an und prüft ihn (rechnet die GPU ab, etwa 7,89 $/h)
make wait-ready           # wartet, bis vLLM antwortet, misst die Startzeit
make check                # bestätigt, dass der Endpunkt geschützt ist und das richtige Modell bedient

make start ARGS=--wait    # jeden Tag danach: startet oder legt einen Pool-Pod an, wartet bis bereit
make stop                 # wenn fertig (beendet die GPU-Abrechnung)
```

Alles Weitere steht in **[docs/guide.de.md](docs/guide.de.md)**.

## Lizenz

MIT, siehe [LICENSE](LICENSE). Die Lizenz gilt nur für Code und Dokumentation dieses Repositorys, nicht für RunPod, das Modell oder das vLLM-Image, für die eigene Bedingungen gelten.
